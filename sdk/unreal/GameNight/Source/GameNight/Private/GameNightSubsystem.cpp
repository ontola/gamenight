// The Unreal side of the GameNight plugin: a plain TCP socket (one JSON
// message per line, same port as the WebSocket transport), the game window,
// audio, the world pause and face textures. The protocol itself lives in
// GameNightCore.cpp. Mirrors sdk/godot/addons/gamenight/gamenight.gd and
// screen.gd: when one changes, check the other.
#include "GameNightSubsystem.h"

#include "GameNightProtocol.h"

#include "AudioDevice.h"
#include "CanvasItem.h"
#include "Engine/Canvas.h"
#include "Engine/Engine.h"
#include "Engine/GameInstance.h"
#include "Engine/GameViewportClient.h"
#include "Engine/Texture2D.h"
#include "Engine/World.h"
#include "Framework/Application/IInputProcessor.h"
#include "Framework/Application/SlateApplication.h"
#include "GameFramework/GameUserSettings.h"
#include "HAL/FileManager.h"
#include "HAL/PlatformMisc.h"
#include "HAL/PlatformProcess.h"
#include "HAL/PlatformProperties.h"
#include "IPAddress.h"
#include "Kismet/GameplayStatics.h"
#include "Misc/App.h"
#include "Misc/Paths.h"
#include "Runtime/Launch/Resources/Version.h"
#include "SocketSubsystem.h"
#include "Sockets.h"
#include "Widgets/SWindow.h"

DEFINE_LOG_CATEGORY(LogGameNight);

namespace
{
constexpr double ReconnectDelay = 2.0;
// How long to let a window change land before asking again (screen.gd).
constexpr double WindowRetrySeconds = 0.25;
// Keep asking to leave the screen this long, then park the window.
constexpr double OffScreenDeadlineSeconds = 8.0;
constexpr double OnScreenDeadlineSeconds = 4.0;
const FVector2D ParkedPosition(-30000.0, -30000.0);

// Hosted rooms limit phone screens (docs/site/phone-screens.md).
constexpr int64 PhoneFileLimit = 512 * 1024;
constexpr int64 PhoneBundleLimit = 2 * 1024 * 1024;
constexpr int32 PhoneFileCount = 128;

FLinearColor ColorFromHex(const std::string& Hex, const FLinearColor& Fallback)
{
	uint8_t Rgb[3];
	if (!gamenight::ParseHexColor(Hex, Rgb)) return Fallback;
	return FLinearColor::FromSRGBColor(FColor(Rgb[0], Rgb[1], Rgb[2]));
}

EGameNightOccupant OccupantFromJson(const gamenight::Json& Seat)
{
	const std::string Kind = Seat["occupant"]["kind"].str();
	if (Kind == gamenight::protocol::SEAT_OCCUPANT_LOCAL) return EGameNightOccupant::Local;
	if (Kind == gamenight::protocol::SEAT_OCCUPANT_REMOTE) return EGameNightOccupant::Remote;
	if (Kind == gamenight::protocol::SEAT_OCCUPANT_AI) return EGameNightOccupant::AI;
	return EGameNightOccupant::Empty;
}

FGameNightSeat SeatFromJson(const gamenight::Json& Seat)
{
	FGameNightSeat Out;
	Out.Index = static_cast<int32>(Seat["index"].integer());
	Out.Occupant = OccupantFromJson(Seat);
	Out.PlayerId = UGameNightSubsystem::FromUtf8(Seat["occupant"]["player_id"].str());
	return Out;
}

gamenight::Json ParseOrNull(const FString& Text)
{
	bool bOk = false;
	gamenight::Json Value = gamenight::Json::parse(UGameNightSubsystem::ToUtf8(Text), &bOk);
	if (!bOk) UE_LOG(LogGameNight, Warning, TEXT("GameNight: not valid JSON: %s"), *Text.Left(200));
	return Value;
}

TSharedPtr<SWindow> GameWindow()
{
	if (!GEngine || !GEngine->GameViewport) return nullptr;
	return GEngine->GameViewport->GetWindow();
}
}  // namespace

// F1 (and F12) returns to the party from anywhere in the game, like the
// Godot addon. Physical Back/Select is handled by GameNight itself.
class FGameNightInputProcessor : public IInputProcessor
{
public:
	explicit FGameNightInputProcessor(UGameNightSubsystem* InOwner) : Owner(InOwner) {}

	virtual void Tick(const float DeltaTime, FSlateApplication& SlateApp, TSharedRef<ICursor> Cursor) override {}

	virtual bool HandleKeyDownEvent(FSlateApplication& SlateApp, const FKeyEvent& InKeyEvent) override
	{
		if (InKeyEvent.IsRepeat()) return false;
		const FKey Key = InKeyEvent.GetKey();
		if ((Key == EKeys::F1 || Key == EKeys::F12) && Owner.IsValid())
		{
			Owner->RequestOverlay();
			return true;
		}
		return false;
	}

	virtual const TCHAR* GetDebugName() const override { return TEXT("GameNight"); }

private:
	TWeakObjectPtr<UGameNightSubsystem> Owner;
};

// ---- helpers ---------------------------------------------------------------

UGameNightSubsystem* UGameNightSubsystem::Get(const UObject* WorldContext)
{
	UWorld* World = GEngine ? GEngine->GetWorldFromContextObject(WorldContext, EGetWorldErrorMode::ReturnNull) : nullptr;
	UGameInstance* Instance = World ? World->GetGameInstance() : nullptr;
	return Instance ? Instance->GetSubsystem<UGameNightSubsystem>() : nullptr;
}

FString UGameNightSubsystem::FromUtf8(const std::string& Text)
{
	return FString(UTF8_TO_TCHAR(Text.c_str()));
}

std::string UGameNightSubsystem::ToUtf8(const FString& Text)
{
	const FTCHARToUTF8 Converted(*Text);
	return std::string((const char*)Converted.Get(), static_cast<size_t>(Converted.Length()));
}

FGameNightPlayer UGameNightSubsystem::PlayerFromJson(const gamenight::Json& Player)
{
	FGameNightPlayer Out;
	Out.Id = FromUtf8(Player["id"].str());
	Out.Name = FromUtf8(Player["name"].str());
	Out.bHasColor = Player["color"].is_string();
	Out.Color = ColorFromHex(Player["color"].str(), FLinearColor::White);
	Out.SkinColor = ColorFromHex(Player["skin_color"].str("#f5e9be"), FLinearColor::FromSRGBColor(FColor(0xf5, 0xe9, 0xbe)));
	Out.Avatar = FromUtf8(Player["avatar"].str());
	Out.Couch = Player["couch"].is_number() ? static_cast<int32>(Player["couch"].integer()) : -1;
	Out.ProfileKey = FromUtf8(Player["profile_key"].str());
	return Out;
}

// ---- lifetime --------------------------------------------------------------

void UGameNightSubsystem::Initialize(FSubsystemCollectionBase& Collection)
{
	Super::Initialize(Collection);
	const UGameNightSettings* Settings = GetDefault<UGameNightSettings>();

	// GameNight passes the handshake in the environment: the same build boots
	// into party mode when launched, and runs standalone otherwise.
	bLaunched = FPlatformMisc::GetEnvironmentVariable(ANSI_TO_TCHAR(gamenight::protocol::ENV_GAMENIGHT)) == TEXT("1");
	GameId = FPlatformMisc::GetEnvironmentVariable(ANSI_TO_TCHAR(gamenight::protocol::ENV_GAME_ID));
	if (GameId.IsEmpty()) GameId = Settings->GameId;
	if (GameId.IsEmpty()) GameId = FString(FApp::GetProjectName()).ToLower();
	const FString EnvAddress = FPlatformMisc::GetEnvironmentVariable(ANSI_TO_TCHAR(gamenight::protocol::ENV_ADDR));
	HostAddress = EnvAddress.IsEmpty() ? Settings->HostAddress : EnvAddress;

	gamenight::Config Config;
	Config.game_id = ToUtf8(GameId);
	Config.token = ToUtf8(FPlatformMisc::GetEnvironmentVariable(ANSI_TO_TCHAR(gamenight::protocol::ENV_TOKEN)));
	Config.launched = bLaunched;
	Client = MakeUnique<gamenight::Client>(Config);

	gamenight::DeviceInfo Device;
	Device.cpu = ToUtf8(FPlatformMisc::GetCPUBrand().TrimStartAndEnd());
	Device.gpu = ToUtf8(FPlatformMisc::GetPrimaryGPUBrand().TrimStartAndEnd());
	Device.os = ToUtf8(FString(FPlatformProperties::IniPlatformName()));
	Device.memory_mib = FPlatformMemory::GetConstants().TotalPhysical / (1024ull * 1024ull);
	Client->SetDeviceInfo(Device);

	if (FSlateApplication::IsInitialized())
	{
		InputProcessor = MakeShared<FGameNightInputProcessor>(this);
		FSlateApplication::Get().RegisterInputPreProcessor(InputProcessor);
	}

	if (!bLaunched && EnvAddress.IsEmpty() && !Settings->bConnectStandalone)
	{
		UE_LOG(LogGameNight, Log, TEXT("[gamenight][%s] started by hand: staying offline"), *GameId);
		return;
	}
	bAutoReconnect = !bLaunched;
	if (bLaunched && Settings->bAutomaticScreen) GoQuiet(TEXT("warm"));
	Open();
}

void UGameNightSubsystem::Deinitialize()
{
	if (InputProcessor.IsValid() && FSlateApplication::IsInitialized())
	{
		FSlateApplication::Get().UnregisterInputPreProcessor(InputProcessor);
	}
	InputProcessor.Reset();
	bAutoReconnect = false;
	CloseSocket();
	Unthrottle();
	Client.Reset();
	Super::Deinitialize();
}

TStatId UGameNightSubsystem::GetStatId() const
{
	RETURN_QUICK_DECLARE_CYCLE_STAT(UGameNightSubsystem, STATGROUP_Tickables);
}

ETickableTickType UGameNightSubsystem::GetTickableTickType() const
{
	return HasAnyFlags(RF_ClassDefaultObject) ? ETickableTickType::Never : ETickableTickType::Conditional;
}

// ---- transport -------------------------------------------------------------

void UGameNightSubsystem::Open()
{
	ReconnectAt = FPlatformTime::Seconds() + ReconnectDelay;
	ISocketSubsystem* Sockets = ISocketSubsystem::Get(PLATFORM_SOCKETSUBSYSTEM);
	if (!Sockets) return;
	FString Host = TEXT("127.0.0.1");
	FString PortText = TEXT("7912");
	if (!HostAddress.Split(TEXT(":"), &Host, &PortText, ESearchCase::IgnoreCase, ESearchDir::FromEnd))
	{
		Host = HostAddress;
	}
	TSharedRef<FInternetAddr> Address = Sockets->CreateInternetAddr();
	bool bValid = false;
	Address->SetIp(*Host, bValid);
	Address->SetPort(FCString::Atoi(*PortText));
	if (!bValid)
	{
		UE_LOG(LogGameNight, Warning, TEXT("GameNight: bad host address %s"), *HostAddress);
		return;
	}
	Socket = Sockets->CreateSocket(NAME_Stream, TEXT("GameNight"), Address->GetProtocolType());
	if (!Socket) return;
	Socket->SetNoDelay(true);
	// Blocking connect: the host is on this machine, so it answers or refuses
	// at once. Everything after is non-blocking.
	if (!Socket->Connect(*Address))
	{
		UE_LOG(LogGameNight, Log, TEXT("GameNight: cannot reach the host at %s"), *HostAddress);
		Sockets->DestroySocket(Socket);
		Socket = nullptr;
		if (bLaunched) FPlatformMisc::RequestExit(false, TEXT("GameNight"));
		return;
	}
	Socket->SetNonBlocking(true);
	SendBuffer.Reset();
	Client->OnConnected();
	Flush();
}

void UGameNightSubsystem::CloseSocket()
{
	if (!Socket) return;
	Socket->Close();
	if (ISocketSubsystem* Sockets = ISocketSubsystem::Get(PLATFORM_SOCKETSUBSYSTEM)) Sockets->DestroySocket(Socket);
	Socket = nullptr;
	SendBuffer.Reset();
	if (Client) Client->OnDisconnected();
}

void UGameNightSubsystem::Pump()
{
	if (!Socket) return;
	uint8 Buffer[64 * 1024];
	for (int32 Reads = 0; Reads < 256; ++Reads)
	{
		int32 Read = 0;
		if (!Socket->Recv(Buffer, static_cast<int32>(sizeof(Buffer)), Read))
		{
			// The host closed the connection or went away.
			CloseSocket();
			return;
		}
		if (Read <= 0) break;  // nothing more for now
		Client->Receive(reinterpret_cast<const char*>(Buffer), static_cast<size_t>(Read));
	}
}

void UGameNightSubsystem::Flush()
{
	if (!Socket || !Client) return;
	for (const std::string& Message : Client->TakeOutgoing())
	{
		SendBuffer.Append(reinterpret_cast<const uint8*>(Message.data()), static_cast<int32>(Message.size()));
		SendBuffer.Add('\n');
	}
	while (SendBuffer.Num() > 0)
	{
		int32 Sent = 0;
		if (!Socket->Send(SendBuffer.GetData(), SendBuffer.Num(), Sent))
		{
			const ESocketErrors Error = ISocketSubsystem::Get(PLATFORM_SOCKETSUBSYSTEM)->GetLastErrorCode();
			if (Error == SE_EWOULDBLOCK) return;  // try again next frame
			CloseSocket();
			return;
		}
		if (Sent <= 0) return;
#if ENGINE_MAJOR_VERSION > 5 || ENGINE_MINOR_VERSION >= 4
		SendBuffer.RemoveAt(0, Sent, EAllowShrinking::No);
#else
		SendBuffer.RemoveAt(0, Sent, false);
#endif
	}
}

void UGameNightSubsystem::Tick(float DeltaTime)
{
	if (!Client) return;
	const double Now = FPlatformTime::Seconds();
	if (GEngine && GEngine->GameViewport)
	{
		FVector2D Size;
		GEngine->GameViewport->GetViewportSize(Size);
		Client->SetWindowSize(static_cast<int>(Size.X), static_cast<int>(Size.Y));
	}
	Client->Tick(Now);
	if (!Socket && bAutoReconnect && Now >= ReconnectAt) Open();
	Pump();
	gamenight::Event Event;
	while (Client && Client->PollEvent(Event)) Dispatch(Event);
	Flush();
	ApplyWorldPause();
	PumpScreen();
}

// ---- events ----------------------------------------------------------------

void UGameNightSubsystem::Dispatch(const gamenight::Event& Event)
{
	using Kind = gamenight::Event::Kind;
	const FString Session = FromUtf8(Event.session);
	const bool bScreen = bLaunched && GetDefault<UGameNightSettings>()->bAutomaticScreen;
	switch (Event.kind)
	{
	case Kind::Connected:
		UE_LOG(LogGameNight, Log, TEXT("[gamenight][%s] connected"), *GameId);
		OnConnected.Broadcast();
		break;
	case Kind::Disconnected:
		UE_LOG(LogGameNight, Log, TEXT("[gamenight][%s] host disconnected"), *GameId);
		OnDisconnected.Broadcast();
		ReconnectAt = FPlatformTime::Seconds() + ReconnectDelay;
		// A launched game belongs to its host: no host, no game.
		if (bLaunched && !bQuitting)
		{
			bQuitting = true;
			FPlatformMisc::RequestExit(false, TEXT("GameNight"));
		}
		break;
	case Kind::PartyUpdated:
		break;
	case Kind::Prepared:
		UE_LOG(LogGameNight, Log, TEXT("[gamenight][%s] prepare %s"), *GameId, *Session);
		ApplyWorldPause();
		OnPrepared.Broadcast(Session);
		break;
	case Kind::Started:
		UE_LOG(LogGameNight, Log, TEXT("[gamenight][%s] start %s"), *GameId, *Session);
		if (bScreen) TakeTheScreen(TEXT("start"));
		ApplyWorldPause();
		OnStarted.Broadcast(Session);
		break;
	case Kind::Paused:
		UE_LOG(LogGameNight, Log, TEXT("[gamenight][%s] pause %s"), *GameId, *Session);
		if (bScreen) GoQuiet(TEXT("pause"));
		ApplyWorldPause();
		OnPaused.Broadcast(Session);
		break;
	case Kind::Resumed:
		UE_LOG(LogGameNight, Log, TEXT("[gamenight][%s] resume %s"), *GameId, *Session);
		if (bScreen) TakeTheScreen(TEXT("resume"));
		ApplyWorldPause();
		OnResumed.Broadcast(Session);
		break;
	case Kind::Disposed:
		UE_LOG(LogGameNight, Log, TEXT("[gamenight][%s] dispose %s"), *GameId, *Session);
		if (bScreen) GoQuiet(TEXT("dispose"));
		ApplyWorldPause();
		OnDisposed.Broadcast(Session);
		break;
	case Kind::RosterChanged:
		OnRosterChanged.Broadcast();
		break;
	case Kind::PlayersUpdated:
		OnPlayersUpdated.Broadcast();
		break;
	case Kind::SettingChanged:
		OnSettingChanged.Broadcast(FromUtf8(Event.key), FromUtf8(Event.value.dump()));
		break;
	case Kind::PlayerSettingsChanged:
		OnPlayerSettingsChanged.Broadcast(FromUtf8(Event.player_id));
		break;
	case Kind::PlayerDataChanged:
		OnPlayerDataChanged.Broadcast(FromUtf8(Event.player_id));
		break;
	case Kind::ActionTriggered:
		OnActionTriggered.Broadcast(FromUtf8(Event.key), FromUtf8(Event.player_id));
		break;
	case Kind::CompanionMessage:
		OnCompanionMessage.Broadcast(FromUtf8(Event.player_id), FromUtf8(Event.value.dump()));
		break;
	case Kind::CompanionPresence:
		OnCompanionPresence.Broadcast(FromUtf8(Event.player_id), Event.connected);
		break;
	case Kind::Warning:
		UE_LOG(LogGameNight, Warning, TEXT("%s"), *FromUtf8(Event.text));
		break;
	}
}

void UGameNightSubsystem::ApplyWorldPause()
{
	if (!bLaunched || !Client || !GetDefault<UGameNightSettings>()->bPauseWorldWhenNotRunning) return;
	UGameInstance* Instance = GetGameInstance();
	UWorld* World = Instance ? Instance->GetWorld() : nullptr;
	if (!World) return;
	// Checked every frame: a level change makes a new, unpaused world.
	const bool bWantPaused = Client->phase() != gamenight::Phase::Running;
	if (World->IsPaused() != bWantPaused) UGameplayStatics::SetGamePaused(World, bWantPaused);
}

// ---- state -----------------------------------------------------------------

bool UGameNightSubsystem::IsConnected() const { return Client && Client->connected(); }

EGameNightPhase UGameNightSubsystem::GetPhase() const
{
	if (!Client) return EGameNightPhase::Idle;
	switch (Client->phase())
	{
	case gamenight::Phase::Preparing: return EGameNightPhase::Preparing;
	case gamenight::Phase::Ready: return EGameNightPhase::Ready;
	case gamenight::Phase::Running: return EGameNightPhase::Running;
	case gamenight::Phase::Paused: return EGameNightPhase::Paused;
	default: return EGameNightPhase::Idle;
	}
}

FString UGameNightSubsystem::GetSessionId() const { return Client ? FromUtf8(Client->session()) : FString(); }

TArray<FGameNightSeat> UGameNightSubsystem::GetSeats() const
{
	TArray<FGameNightSeat> Out;
	if (!Client) return Out;
	for (const gamenight::Json& Seat : Client->seats().items()) Out.Add(SeatFromJson(Seat));
	return Out;
}

TArray<FGameNightPlayer> UGameNightSubsystem::GetPlayers() const
{
	TArray<FGameNightPlayer> Out;
	if (!Client) return Out;
	for (const gamenight::Json& Player : Client->players().items()) Out.Add(PlayerFromJson(Player));
	return Out;
}

bool UGameNightSubsystem::GetPlayer(const FString& PlayerId, FGameNightPlayer& OutPlayer) const
{
	if (!Client) return false;
	const gamenight::Json& Player = Client->player(ToUtf8(PlayerId));
	if (Player.is_null()) return false;
	OutPlayer = PlayerFromJson(Player);
	return true;
}

bool UGameNightSubsystem::GetPlayerForSeat(int32 SeatIndex, FGameNightPlayer& OutPlayer) const
{
	if (!Client) return false;
	const gamenight::Json& Player = Client->player_for_seat(SeatIndex);
	if (Player.is_null()) return false;
	OutPlayer = PlayerFromJson(Player);
	return true;
}

TArray<FGameNightSeat> UGameNightSubsystem::GetCouchOrder() const
{
	TArray<FGameNightSeat> Out;
	if (!Client) return Out;
	for (const gamenight::Json& Seat : Client->CouchOrder()) Out.Add(SeatFromJson(Seat));
	return Out;
}

int32 UGameNightSubsystem::LocalSeatCount() const { return Client ? Client->LocalSeatCount() : 0; }

int32 UGameNightSubsystem::AiSeatCount() const { return Client ? Client->AiSeatCount() : 0; }

// ---- lifecycle -------------------------------------------------------------

void UGameNightSubsystem::NotifyReady()
{
	if (!Client || Client->phase() != gamenight::Phase::Preparing) return;
	Client->Ready();
	Flush();
	// Loading is over, and not one frame before: stop spending a core on a
	// match nobody is watching yet.
	if (bLaunched && GetDefault<UGameNightSettings>()->bAutomaticScreen) Settle();
}

void UGameNightSubsystem::NotifyFinished()
{
	if (Client) Client->Finished();
}

void UGameNightSubsystem::AddRoomLog(const FString& Text)
{
	if (Client) Client->RoomLog(ToUtf8(Text));
}

void UGameNightSubsystem::NotifyParticipation(bool bInstantJoin)
{
	if (Client) Client->Participation(bInstantJoin);
}

void UGameNightSubsystem::NotifyProgress(int32 Percent, const FString& Label)
{
	if (Client) Client->Progress(Percent, ToUtf8(Label));
	Flush();
}

void UGameNightSubsystem::RequestOverlay()
{
	if (Client && Socket)
	{
		Client->RequestOverlay();
		Flush();
		return;
	}
	// Standalone: open the overlay page, when this machine has one.
	const FString Overlay = FPlatformMisc::GetEnvironmentVariable(ANSI_TO_TCHAR(gamenight::protocol::ENV_OVERLAY_URL));
	if (!Overlay.IsEmpty()) FPlatformProcess::LaunchURL(*Overlay, nullptr, nullptr);
}

// ---- input -----------------------------------------------------------------

FGameNightPad UGameNightSubsystem::GetPad(int32 SeatIndex, bool bAnyPhase) const
{
	FGameNightPad Out;
	if (!Client) return Out;
	const gamenight::Pad Pad = Client->PadForSeat(SeatIndex, bAnyPhase);
	Out.bPresent = Pad.present;
	Out.Buttons = static_cast<int32>(Pad.buttons);
	const gamenight::Vec2 Left = gamenight::Stick(Pad, 0);
	const gamenight::Vec2 Right = gamenight::Stick(Pad, 1);
	Out.LeftStick = FVector2D(Left.x, Left.y);
	Out.RightStick = FVector2D(Right.x, Right.y);
	Out.LeftTrigger = gamenight::Trigger(Pad, 0);
	Out.RightTrigger = gamenight::Trigger(Pad, 1);
	return Out;
}

bool UGameNightSubsystem::JustPressed(int32 SeatIndex, EGameNightButton Button) const
{
	return Client && Client->JustPressed(SeatIndex, static_cast<int>(Button));
}

void UGameNightSubsystem::ReportActivity(int32 SeatIndex)
{
	if (Client) Client->ReportActivity(SeatIndex);
}

void UGameNightSubsystem::Rumble(int32 SeatIndex, float Weak, float Strong, float Seconds)
{
	if (Client) Client->Rumble(SeatIndex, Weak, Strong, Seconds);
}

// ---- settings and saves ----------------------------------------------------

void UGameNightSubsystem::DeclareSettingsJson(const FString& SettingsJson) { DeclareSettings(ParseOrNull(SettingsJson)); }

void UGameNightSubsystem::DeclareSettings(const gamenight::Json& Settings)
{
	if (!Client) return;
	Client->DeclareSettings(Settings);
	Flush();
}

void UGameNightSubsystem::DeclareActionsJson(const FString& ActionsJson) { DeclareActions(ParseOrNull(ActionsJson)); }

void UGameNightSubsystem::DeclareActions(const gamenight::Json& Actions)
{
	if (!Client) return;
	Client->DeclareActions(Actions);
	Flush();
}

void UGameNightSubsystem::SetSettingJson(const FString& Key, const FString& ValueJson) { SetSetting(Key, ParseOrNull(ValueJson)); }

void UGameNightSubsystem::SetSetting(const FString& Key, const gamenight::Json& Value)
{
	if (Client) Client->SetSetting(ToUtf8(Key), Value);
}

int32 UGameNightSubsystem::GetSettingInt(const FString& Key, int32 Fallback) const
{
	return Client ? static_cast<int32>(Client->setting(ToUtf8(Key)).integer(Fallback)) : Fallback;
}

bool UGameNightSubsystem::GetSettingBool(const FString& Key, bool Fallback) const
{
	return Client ? Client->setting(ToUtf8(Key)).boolean(Fallback) : Fallback;
}

FString UGameNightSubsystem::GetSettingString(const FString& Key, const FString& Fallback) const
{
	return Client ? FromUtf8(Client->setting(ToUtf8(Key)).str(ToUtf8(Fallback))) : Fallback;
}

FString UGameNightSubsystem::GetPlayerSettingJson(const FString& PlayerId, const FString& Key) const
{
	return Client ? FromUtf8(Client->player_setting(ToUtf8(PlayerId), ToUtf8(Key)).dump()) : TEXT("null");
}

void UGameNightSubsystem::SetPlayerSettingJson(const FString& PlayerId, const FString& Key, const FString& ValueJson)
{
	if (Client) Client->SetPlayerSetting(ToUtf8(PlayerId), ToUtf8(Key), ParseOrNull(ValueJson));
}

FString UGameNightSubsystem::GetPlayerDataJson(const FString& PlayerId) const
{
	return Client ? FromUtf8(Client->player_data(ToUtf8(PlayerId)).dump()) : TEXT("null");
}

void UGameNightSubsystem::SavePlayerDataJson(const FString& PlayerId, const FString& DataJson)
{
	if (Client) Client->SavePlayerData(ToUtf8(PlayerId), ParseOrNull(DataJson));
}

void UGameNightSubsystem::UnlockForPresent(const FString& Item, const FString& Key)
{
	if (Client) Client->UnlockForPresent(gamenight::Json(ToUtf8(Item)), ToUtf8(Key));
}

TArray<FString> UGameNightSubsystem::PartyUnion(const FString& Key) const
{
	TArray<FString> Out;
	if (!Client) return Out;
	for (const gamenight::Json& Item : Client->PartyUnion(ToUtf8(Key)).items())
	{
		Out.Add(Item.is_string() ? FromUtf8(Item.str()) : FromUtf8(Item.dump()));
	}
	return Out;
}

// ---- phone screens ---------------------------------------------------------

FString UGameNightSubsystem::DeclareCompanionFolder(const FString& ContentFolder, const FString& Entry)
{
	if (!Client) return FString();
	// A packaged game keeps this folder as loose files only when it is listed
	// in DirectoriesToAlwaysStageAsNonUFS (see the docs); then it is a real
	// directory the host can serve, in the editor and in the build alike.
	const FString Root = FPaths::ConvertRelativePathToFull(FPaths::ProjectContentDir() / ContentFolder);
	if (!IFileManager::Get().FileExists(*(Root / Entry)))
	{
		UE_LOG(LogGameNight, Warning, TEXT("GameNight: no phone screen at %s; stage Content/%s as non-UFS files"), *(Root / Entry), *ContentFolder);
		return FString();
	}
	TArray<FString> Files;
	IFileManager::Get().FindFilesRecursive(Files, *Root, TEXT("*"), true, false);
	static const TArray<FString> Served = {TEXT("html"), TEXT("htm"), TEXT("js"), TEXT("mjs"), TEXT("css"), TEXT("json"),
	                                       TEXT("svg"), TEXT("png"), TEXT("jpg"), TEXT("jpeg"), TEXT("webp"), TEXT("woff2"), TEXT("apk")};
	int64 Total = 0;
	for (const FString& File : Files)
	{
		const int64 Encoded = (IFileManager::Get().FileSize(*File) + 2) / 3 * 4;
		Total += Encoded;
		if (Encoded > PhoneFileLimit)
			UE_LOG(LogGameNight, Warning, TEXT("GameNight: phone file %s is %lld KiB in a hosted room; the limit is 512 KiB"), *File, Encoded >> 10);
		if (!Served.Contains(FPaths::GetExtension(File).ToLower()))
			UE_LOG(LogGameNight, Warning, TEXT("GameNight: hosted rooms do not serve phone file %s"), *File);
	}
	if (Files.Num() > PhoneFileCount || Total > PhoneBundleLimit)
		UE_LOG(LogGameNight, Warning, TEXT("GameNight: the phone screen is %d files, %lld KiB in a hosted room; the limit is 128 files, 2048 KiB"), Files.Num(), Total >> 10);
	Client->DeclareCompanion(ToUtf8(Root), ToUtf8(Entry));
	Flush();
	return Root;
}

void UGameNightSubsystem::SendCompanionMessageJson(const FString& DataJson, const FString& PlayerId)
{
	SendCompanionMessage(ParseOrNull(DataJson), PlayerId);
}

void UGameNightSubsystem::SendCompanionMessage(const gamenight::Json& Data, const FString& PlayerId)
{
	if (Client) Client->SendCompanionMessage(Data, ToUtf8(PlayerId));
}

// ---- faces -----------------------------------------------------------------

UTexture2D* UGameNightSubsystem::GetFaceTexture(const FGameNightPlayer& Player)
{
	if (Player.Avatar.IsEmpty()) return nullptr;
	if (TObjectPtr<UTexture2D>* Known = FaceTextures.Find(Player.Avatar)) return *Known;
	const gamenight::FaceImage Face = gamenight::DecodeAvatar(ToUtf8(Player.Avatar));
	UTexture2D* Texture = nullptr;
	if (Face.valid())
	{
		Texture = UTexture2D::CreateTransient(Face.width, Face.height, PF_R8G8B8A8);
		if (Texture)
		{
			Texture->Filter = TF_Nearest;
			Texture->SRGB = true;
			Texture->LODGroup = TEXTUREGROUP_Pixels2D;
			FTexture2DMipMap& Mip = Texture->GetPlatformData()->Mips[0];
			void* Pixels = Mip.BulkData.Lock(LOCK_READ_WRITE);
			FMemory::Memcpy(Pixels, Face.rgba.data(), Face.rgba.size());
			Mip.BulkData.Unlock();
			Texture->UpdateResource();
		}
	}
	// Profile changes bring new payloads; bound the cache for long nights.
	if (FaceTextures.Num() >= 32) FaceTextures.Reset();
	FaceTextures.Add(Player.Avatar, Texture);
	return Texture;
}

void UGameNightSubsystem::DrawFace(UCanvas* Canvas, const FGameNightPlayer& Player, FVector2D Center, float Radius, float Facing)
{
	if (!Canvas || Radius <= 0.0f) return;
	if (!DiscTexture)
	{
		// A soft-edged white disc, tinted per draw: the skin circle.
		constexpr int32 Side = 64;
		DiscTexture = UTexture2D::CreateTransient(Side, Side, PF_B8G8R8A8);
		DiscTexture->Filter = TF_Bilinear;
		FTexture2DMipMap& Mip = DiscTexture->GetPlatformData()->Mips[0];
		FColor* Pixels = static_cast<FColor*>(Mip.BulkData.Lock(LOCK_READ_WRITE));
		for (int32 Y = 0; Y < Side; ++Y)
		{
			for (int32 X = 0; X < Side; ++X)
			{
				const float Dx = X + 0.5f - Side / 2.0f;
				const float Dy = Y + 0.5f - Side / 2.0f;
				const float Edge = FMath::Clamp(Side / 2.0f - FMath::Sqrt(Dx * Dx + Dy * Dy), 0.0f, 1.0f);
				Pixels[Y * Side + X] = FColor(255, 255, 255, static_cast<uint8>(Edge * 255.0f));
			}
		}
		Mip.BulkData.Unlock();
		DiscTexture->UpdateResource();
	}
	const auto Disc = [&](FVector2D At, float R, const FLinearColor& Color) {
		FCanvasTileItem Item(At - FVector2D(R, R), DiscTexture->GetResource(), FVector2D(R * 2.0f, R * 2.0f), Color);
		Item.BlendMode = SE_BLEND_Translucent;
		Canvas->DrawItem(Item);
	};
	Disc(Center, Radius, Player.SkinColor);
	const float Scale = Radius / static_cast<float>(gamenight::protocol::AVATAR_HEAD_RADIUS);
	if (UTexture2D* Face = GetFaceTexture(Player))
	{
		const gamenight::FaceImage Layout = gamenight::DecodeAvatar(ToUtf8(Player.Avatar));
		// Place the head centre of the artwork on Center; mirror around it.
		const float Left = Facing < 0.0f ? (Layout.center_x - Layout.width) : -Layout.center_x;
		FCanvasTileItem Item(Center + FVector2D(Left, -Layout.center_y) * Scale, Face->GetResource(),
		                     FVector2D(Layout.width, Layout.height) * Scale, FLinearColor::White);
		if (Facing < 0.0f)
		{
			Item.UV0 = FVector2D(1.0f, 0.0f);
			Item.UV1 = FVector2D(0.0f, 1.0f);
		}
		Item.BlendMode = SE_BLEND_Translucent;
		Canvas->DrawItem(Item);
		return;
	}
	// The same three-quarter default face as the other SDKs.
	const FLinearColor Ink(0.08f, 0.09f, 0.12f);
	const float Dir = Facing < 0.0f ? -1.0f : 1.0f;
	Disc(Center + FVector2D(0.0f, -2.0f) * Scale, 1.2f * Scale, Ink);
	Disc(Center + FVector2D(6.0f * Dir, -2.0f) * Scale, 1.2f * Scale, Ink);
	FCanvasLineItem Mouth(Center + FVector2D(2.0f * Dir, 5.0f) * Scale, Center + FVector2D(6.0f * Dir, 5.0f) * Scale);
	Mouth.LineThickness = Scale;
	Mouth.SetColor(Ink);
	Canvas->DrawItem(Mouth);
}

// ---- screen manners --------------------------------------------------------
//
// The rules are the window server's, not GameNight's (see screen.gd):
// launching a process activates it, so a warming game must hide itself; a
// background app cannot take focus, so on Pause the game must really leave;
// and window changes animate, so each one is asked again until it lands.

void UGameNightSubsystem::SetMuted(bool bMuted)
{
	if (!GEngine) return;
	FAudioDeviceHandle Audio = GEngine->GetMainAudioDevice();
	if (Audio.IsValid()) Audio->SetTransientPrimaryVolume(bMuted ? 0.0f : 1.0f);
}

void UGameNightSubsystem::GoQuiet(const TCHAR* Why)
{
	UE_LOG(LogGameNight, Log, TEXT("[gamenight][%s] %s: muted and off-screen until start"), *GameId, Why);
#if PLATFORM_WINDOWS
	// Hand the foreground to the lobby while we still own it: afterwards
	// this process can no longer give it away.
	const TSharedPtr<SWindow> Window = GameWindow();
	if (FCString::Strcmp(Why, TEXT("pause")) == 0 && Window.IsValid() && Window->IsActive())
	{
		const FString Helper = FPlatformMisc::GetEnvironmentVariable(TEXT("GAMENIGHT_FOREGROUND_HELPER"));
		if (!Helper.IsEmpty() && FPaths::FileExists(Helper))
		{
			int32 Code = 0;
			FPlatformProcess::ExecProcess(*Helper, TEXT("--allow-foreground"), &Code, nullptr, nullptr);
		}
	}
#endif
	SetMuted(true);
	Unthrottle();
	ScreenGoal = EScreenGoal::Away;
	ScreenAskedAt = -1000.0;
	ScreenDeadline = FPlatformTime::Seconds() + OffScreenDeadlineSeconds;
#if PLATFORM_WINDOWS
	// Park a warming window first, so even the minimise animation cannot
	// flash it over the lobby.
	if (FCString::Strcmp(Why, TEXT("warm")) == 0 && Window.IsValid()) Window->MoveWindowTo(ParkedPosition);
#endif
	PumpScreen();
}

void UGameNightSubsystem::Settle()
{
	if (bThrottled || !GEngine) return;
	FpsBeforeWarm = GEngine->GetMaxFPS();
	GEngine->SetMaxFPS(static_cast<float>(GetDefault<UGameNightSettings>()->WarmMaxFPS));
	bThrottled = true;
}

void UGameNightSubsystem::Unthrottle()
{
	if (!bThrottled || !GEngine) return;
	GEngine->SetMaxFPS(FpsBeforeWarm);
	bThrottled = false;
}

void UGameNightSubsystem::TakeTheScreen(const TCHAR* Why)
{
	UE_LOG(LogGameNight, Log, TEXT("[gamenight][%s] %s: taking the screen"), *GameId, Why);
	SetMuted(false);
	Unthrottle();
	ScreenGoal = EScreenGoal::Front;
	ScreenAskedAt = -1000.0;
	ScreenDeadline = FPlatformTime::Seconds() + OnScreenDeadlineSeconds;
	PumpScreen();
}

void UGameNightSubsystem::PumpScreen()
{
	if (ScreenGoal == EScreenGoal::None) return;
	const TSharedPtr<SWindow> Window = GameWindow();
	if (!Window.IsValid()) return;  // not realised yet, or no window at all
	const double Now = FPlatformTime::Seconds();
	const EWindowMode::Type Mode = Window->GetWindowMode();
	if (ScreenGoal == EScreenGoal::Away)
	{
		if (Window->IsWindowMinimized())
		{
			ScreenGoal = EScreenGoal::None;
			return;
		}
		if (Now >= ScreenDeadline)
		{
			// The window server refused. A dismissed game must never stay on
			// the party's TV: park it where nobody can see it.
			UE_LOG(LogGameNight, Log, TEXT("[gamenight][%s] could not minimise; parking the window off-screen"), *GameId);
			Window->MoveWindowTo(ParkedPosition);
			ScreenGoal = EScreenGoal::None;
			return;
		}
#if PLATFORM_MAC
		// One transition at a time, and fullscreen first. Leaving fullscreen
		// is the slowest change; asked again too soon, the window flaps.
		constexpr double ExitFullscreenRetrySeconds = 1.2;
		if (Mode != EWindowMode::Windowed)
		{
			if (Now - ScreenAskedAt >= ExitFullscreenRetrySeconds)
			{
				Window->SetWindowMode(EWindowMode::Windowed);
				ScreenAskedAt = Now;
			}
			return;
		}
#endif
		if (Now - ScreenAskedAt >= WindowRetrySeconds)
		{
			Window->Minimize();
			ScreenAskedAt = Now;
		}
		return;
	}
	// Front: borderless fullscreen (never exclusive: on macOS that is its own
	// Space, which hides the lobby where the party cannot get back to it).
	const bool bLanded = !Window->IsWindowMinimized() && Mode == EWindowMode::WindowedFullscreen && Window->IsActive();
	if (bLanded || Now >= ScreenDeadline)
	{
		ScreenGoal = EScreenGoal::None;
		if (FSlateApplication::IsInitialized()) FSlateApplication::Get().SetAllUserFocusToGameViewport();
		return;
	}
	if (Now - ScreenAskedAt < WindowRetrySeconds) return;
	ScreenAskedAt = Now;
	if (Window->IsWindowMinimized()) Window->Restore();
	if (Window->GetPositionInScreen().X < -10000.0) Window->MoveWindowTo(FVector2D::ZeroVector);
	if (Mode != EWindowMode::WindowedFullscreen)
	{
		if (UGameUserSettings* Settings = GEngine ? GEngine->GetGameUserSettings() : nullptr)
		{
			Settings->SetFullscreenMode(EWindowMode::WindowedFullscreen);
			Settings->SetScreenResolution(Settings->GetDesktopResolution());
			Settings->ApplyResolutionSettings(false);
		}
	}
	Window->BringToFront(true);
	Window->HACK_ForceToFront();
}
