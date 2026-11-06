#include "DashDerbyGameMode.h"

#include "DashDerbyHUD.h"

#include "Camera/CameraActor.h"
#include "Camera/CameraComponent.h"
#include "Components/DirectionalLightComponent.h"
#include "Components/SkyAtmosphereComponent.h"
#include "Components/SkyLightComponent.h"
#include "Components/StaticMeshComponent.h"
#include "Engine/DirectionalLight.h"
#include "Engine/SkyLight.h"
#include "Engine/StaticMesh.h"
#include "Engine/StaticMeshActor.h"
#include "Engine/World.h"
#include "GameFramework/PlayerController.h"
#include "GameNightSubsystem.h"
#include "InputCoreTypes.h"
#include "Materials/MaterialInstanceDynamic.h"
#include "Misc/CommandLine.h"
#include "Misc/Parse.h"

using gamenight::Json;

const FBox2D ADashDerbyGameMode::Arena(FVector2D(-1200.0, -650.0), FVector2D(1200.0, 650.0));

namespace
{
constexpr float Speed = 700.0f;
constexpr float DashSpeed = 2100.0f;
constexpr float DashTime = 0.18f;
constexpr float DashCooldown = 0.9f;
constexpr float BoostTime = 2.0f;
constexpr float BoostCooldownTime = 6.0f;

// Colours and names for bots and standalone players.
const FLinearColor BotColors[] = {
	FLinearColor::FromSRGBColor(FColor(0xe8, 0x55, 0x3d)), FLinearColor::FromSRGBColor(FColor(0x3d, 0x8f, 0xe0)),
	FLinearColor::FromSRGBColor(FColor(0x5c, 0xc4, 0x5a)), FLinearColor::FromSRGBColor(FColor(0xe6, 0xc1, 0x3a)),
	FLinearColor::FromSRGBColor(FColor(0xb0, 0x5c, 0xe0)), FLinearColor::FromSRGBColor(FColor(0x3a, 0xc9, 0xc4)),
	FLinearColor::FromSRGBColor(FColor(0xe0, 0x7a, 0xb8)), FLinearColor::FromSRGBColor(FColor(0x9a, 0xa3, 0xad)),
};
const TCHAR* BotNames[] = {TEXT("Red"), TEXT("Blue"), TEXT("Green"), TEXT("Yellow"),
                           TEXT("Purple"), TEXT("Teal"), TEXT("Pink"), TEXT("Grey")};

uint32 Bit(EGameNightButton Button) { return 1u << static_cast<uint32>(Button); }

FString Hex(const FLinearColor& Color)
{
	const FColor C = Color.ToFColor(true);
	return FString::Printf(TEXT("#%02x%02x%02x"), C.R, C.G, C.B);
}

Json ToJson(const FString& Text) { return Json(UGameNightSubsystem::ToUtf8(Text)); }

// Declared to GameNight: the phones, an LLM and the Start menu change them.
Json SettingsSpec()
{
	Json Settings = Json::MakeArray();
	Settings.push(Json::MakeObject().set("key", "round_seconds").set("label", "Round length (seconds)").set("kind", "number")
	                  .set("default", 60).set("min", 20).set("max", 180));
	Settings.push(Json::MakeObject().set("key", "orbs").set("label", "Orbs on the field").set("kind", "number")
	                  .set("default", 6).set("min", 2).set("max", 16));
	Settings.push(Json::MakeObject().set("key", "bumps").set("label", "Dashes knock players away").set("kind", "toggle")
	                  .set("default", true));
	// "scope": "player": every player picks their own, on their phone.
	Settings.push(Json::MakeObject().set("key", "shape").set("label", "Your shape").set("kind", "choice")
	                  .set("default", "ball").set("options", Json::MakeArray().push("ball").push("cube").push("cone"))
	                  .set("scope", "player"));
	return Settings;
}

Json ActionsSpec()
{
	return Json::MakeArray().push(Json::MakeObject()
	                                  .set("key", "new_round")
	                                  .set("label", "New round")
	                                  .set("description", "Ends this round for everyone.")
	                                  .set("confirm", true));
}
}  // namespace

ADashDerbyGameMode::ADashDerbyGameMode()
{
	PrimaryActorTick.bCanEverTick = true;
	// Paused by GameNight means paused: no simulation, no timers.
	PrimaryActorTick.bTickEvenWhenPaused = false;
	DefaultPawnClass = nullptr;
	HUDClass = ADashDerbyHUD::StaticClass();
}

UGameNightSubsystem* ADashDerbyGameMode::GameNight() const { return UGameNightSubsystem::Get(this); }

void ADashDerbyGameMode::Trace(const FString& Line) const
{
	// GAME_TRACE=1 prints what happens, for tests and agents reading the log.
	if (bTrace) UE_LOG(LogTemp, Display, TEXT("trace: %s"), *Line);
}

const TArray<FString>& ADashDerbyGameMode::MenuRows()
{
	static const TArray<FString> Rows = {TEXT("Resume"), TEXT("New round"), TEXT("Round length"), TEXT("Orbs"),
	                                     TEXT("Dash bumps")};
	return Rows;
}

FString ADashDerbyGameMode::MenuValue(int32 Row) const
{
	switch (Row)
	{
	case 2: return FString::Printf(TEXT("%d s"), RoundSeconds);
	case 3: return FString::FromInt(OrbCount);
	case 4: return bBumps ? TEXT("On") : TEXT("Off");
	default: return FString();
	}
}

// ---- setup -----------------------------------------------------------------

void ADashDerbyGameMode::BeginPlay()
{
	Super::BeginPlay();
	bTrace = FPlatformMisc::GetEnvironmentVariable(TEXT("GAME_TRACE")) == TEXT("1");
	int32 Seed = 0;
	FParse::Value(FCommandLine::Get(), TEXT("seed="), Seed);
	FParse::Value(FCommandLine::Get(), TEXT("players="), StandalonePlayers);
	// All randomness comes from one stream: the same seed gives the same game.
	if (Seed != 0) Random.Initialize(Seed);
	else Random.GenerateNewSeed();
	BuildLevel();

	UGameNightSubsystem* GN = GameNight();
	if (GN && GN->IsLaunchedByGameNight())
	{
		GN->OnConnected.AddDynamic(this, &ADashDerbyGameMode::HandleConnected);
		GN->OnPrepared.AddDynamic(this, &ADashDerbyGameMode::HandlePrepared);
		GN->OnStarted.AddDynamic(this, &ADashDerbyGameMode::HandleStarted);
		GN->OnPaused.AddDynamic(this, &ADashDerbyGameMode::HandlePaused);
		GN->OnResumed.AddDynamic(this, &ADashDerbyGameMode::HandleResumed);
		GN->OnDisposed.AddDynamic(this, &ADashDerbyGameMode::HandleDisposed);
		GN->OnRosterChanged.AddDynamic(this, &ADashDerbyGameMode::HandleRosterChanged);
		GN->OnPlayersUpdated.AddDynamic(this, &ADashDerbyGameMode::HandlePlayersUpdated);
		GN->OnSettingChanged.AddDynamic(this, &ADashDerbyGameMode::HandleSettingChanged);
		GN->OnPlayerSettingsChanged.AddDynamic(this, &ADashDerbyGameMode::HandlePlayerSettings);
		GN->OnActionTriggered.AddDynamic(this, &ADashDerbyGameMode::HandleAction);
		GN->OnCompanionMessage.AddDynamic(this, &ADashDerbyGameMode::HandlePhone);
		GN->OnCompanionPresence.AddDynamic(this, &ADashDerbyGameMode::HandlePhonePresence);
		// Declared once; the plugin declares them again after a reconnect.
		GN->DeclareSettings(SettingsSpec());
		GN->DeclareActions(ActionsSpec());
		GN->DeclareCompanionFolder(TEXT("Phone"), TEXT("index.html"));
		bHostPaused = true;
		Trace(TEXT("waiting for prepare"));
		// GameNight may have prepared us while the map was still loading.
		if (GN->GetPhase() != EGameNightPhase::Idle) HandlePrepared(GN->GetSessionId());
		if (GN->GetPhase() == EGameNightPhase::Running) HandleStarted(GN->GetSessionId());
		return;
	}

	// Standalone: the keyboard (and first pad) plays, bots fill up to four.
	const int32 Count = FMath::Max(2, FMath::Max(StandalonePlayers, 4));
	for (int32 I = 0; I < Count; ++I)
	{
		FOrbRunner Runner;
		Runner.bKeyboard = I == 0;
		Runner.bBot = I >= StandalonePlayers;
		AddRunner(MoveTemp(Runner));
	}
	NewRound();
}

void ADashDerbyGameMode::BuildLevel()
{
	if (bLevelBuilt) return;
	bLevelBuilt = true;
	UWorld* World = GetWorld();
	SphereMesh = LoadObject<UStaticMesh>(nullptr, TEXT("/Engine/BasicShapes/Sphere.Sphere"));
	CubeMesh = LoadObject<UStaticMesh>(nullptr, TEXT("/Engine/BasicShapes/Cube.Cube"));
	ConeMesh = LoadObject<UStaticMesh>(nullptr, TEXT("/Engine/BasicShapes/Cone.Cone"));
	ShapeMaterial = LoadObject<UMaterialInterface>(nullptr, TEXT("/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"));

	const auto Block = [&](const FVector& At, const FVector& Scale, const FLinearColor& Color) {
		AStaticMeshActor* Actor = World->SpawnActor<AStaticMeshActor>(At, FRotator::ZeroRotator);
		Actor->SetMobility(EComponentMobility::Movable);
		UStaticMeshComponent* Mesh = Actor->GetStaticMeshComponent();
		Mesh->SetStaticMesh(CubeMesh);
		Mesh->SetCollisionEnabled(ECollisionEnabled::NoCollision);
		UMaterialInstanceDynamic* Material = UMaterialInstanceDynamic::Create(ShapeMaterial, Actor);
		Material->SetVectorParameterValue(TEXT("Color"), Color);
		Mesh->SetMaterial(0, Material);
		Actor->SetActorScale3D(Scale);
	};
	// The cube is 100 units; the field lies on z = 0. Field x is world Y
	// (right on screen), field y is world -X (down on screen).
	const FVector2D Size = Arena.GetSize();
	Block(FVector(0, 0, -10), FVector(Size.Y / 100.0 + 0.4, Size.X / 100.0 + 0.4, 0.2), FLinearColor(0.07f, 0.06f, 0.1f));
	const FLinearColor Wall(0.22f, 0.2f, 0.32f);
	Block(FVector(Size.Y / 2 + 30, 0, 30), FVector(0.4, Size.X / 100.0 + 0.8, 0.8), Wall);
	Block(FVector(-Size.Y / 2 - 30, 0, 30), FVector(0.4, Size.X / 100.0 + 0.8, 0.8), Wall);
	Block(FVector(0, Size.X / 2 + 30, 30), FVector(Size.Y / 100.0, 0.4, 0.8), Wall);
	Block(FVector(0, -Size.X / 2 - 30, 30), FVector(Size.Y / 100.0, 0.4, 0.8), Wall);

	// Sun, sky and a sky light that captures it: lit without baked lighting.
	if (ADirectionalLight* Sun = World->SpawnActor<ADirectionalLight>(FVector(0, 0, 1000), FRotator(-55.0, 35.0, 0.0)))
	{
		Sun->SetMobility(EComponentMobility::Movable);
		if (UDirectionalLightComponent* Light = Cast<UDirectionalLightComponent>(Sun->GetLightComponent()))
		{
			Light->SetIntensity(6.0f);
			Light->SetAtmosphereSunLight(true);
		}
	}
	World->SpawnActor<ASkyAtmosphere>(FVector::ZeroVector, FRotator::ZeroRotator);
	if (ASkyLight* Sky = World->SpawnActor<ASkyLight>(FVector(0, 0, 500), FRotator::ZeroRotator))
	{
		USkyLightComponent* Light = Sky->GetLightComponent();
		Light->SetMobility(EComponentMobility::Movable);
		Light->bRealTimeCapture = true;
		Light->SetIntensity(1.5f);
		Light->RecaptureSky();
	}

	if (ACameraActor* Camera = World->SpawnActor<ACameraActor>(FVector(-1750.0, 0.0, 2050.0), FRotator(-52.0, 0.0, 0.0)))
	{
		Camera->GetCameraComponent()->SetFieldOfView(62.0f);
		Camera->GetCameraComponent()->bConstrainAspectRatio = false;
		FixedCamera = Camera;
		for (FConstPlayerControllerIterator It = World->GetPlayerControllerIterator(); It; ++It) UseFixedCamera(It->Get());
	}
}

void ADashDerbyGameMode::PostLogin(APlayerController* NewPlayer)
{
	Super::PostLogin(NewPlayer);
	UseFixedCamera(NewPlayer);
}

void ADashDerbyGameMode::UseFixedCamera(APlayerController* Controller)
{
	// One fixed camera over the whole field; there is no pawn to follow.
	if (!Controller || !FixedCamera) return;
	Controller->bAutoManageActiveCameraTarget = false;
	Controller->SetViewTarget(FixedCamera);
}

// ---- GameNight lifecycle ---------------------------------------------------

void ADashDerbyGameMode::HandleConnected()
{
	// Nothing to do: settings, actions and the phone screen are declared
	// again by the plugin on every (re)connect.
	Trace(TEXT("connected"));
}

void ADashDerbyGameMode::HandlePrepared(const FString& SessionId)
{
	UGameNightSubsystem* GN = GameNight();
	GN->NotifyProgress(20, TEXT("seating players"));
	SeatFromSession();
	NewRound();
	bHostPaused = true;
	// Live roster: players who join mid-round get a runner at once.
	GN->NotifyParticipation(true);
	GN->NotifyProgress(100, TEXT("ready"));
	// The level exists and the first frame can be drawn: ready, still hidden.
	GN->NotifyReady();
}

void ADashDerbyGameMode::HandleStarted(const FString& SessionId)
{
	bHostPaused = false;
	Trace(TEXT("running"));
	SendPhoneViews();
}

void ADashDerbyGameMode::HandlePaused(const FString& SessionId)
{
	bHostPaused = true;
	// Nothing else to do: the plugin pauses the world, mutes the game and
	// hands the screen back to the lobby.
	Trace(TEXT("paused"));
}

void ADashDerbyGameMode::HandleResumed(const FString& SessionId)
{
	bHostPaused = false;
	Trace(TEXT("running"));
}

void ADashDerbyGameMode::HandleDisposed(const FString& SessionId)
{
	bHostPaused = true;
	MenuOwner = -1;
	ClearRunners();
	Trace(TEXT("disposed"));
}

void ADashDerbyGameMode::SeatFromSession()
{
	UGameNightSubsystem* GN = GameNight();
	ClearRunners();
	for (const FGameNightSeat& Seat : GN->GetCouchOrder())
	{
		FOrbRunner Runner;
		Runner.Seat = Seat.Index;
		if (Seat.Occupant == EGameNightOccupant::AI)
		{
			Runner.bBot = true;
		}
		else if (Seat.Occupant == EGameNightOccupant::Local || Seat.Occupant == EGameNightOccupant::Remote)
		{
			GN->GetPlayer(Seat.PlayerId, Runner.Player);
		}
		else
		{
			continue;
		}
		AddRunner(MoveTemp(Runner));
	}
	if (Runners.Num() == 0)
	{
		FOrbRunner Bot;
		Bot.bBot = true;
		AddRunner(MoveTemp(Bot));
	}
	TArray<FString> Seated;
	for (const FOrbRunner& Runner : Runners)
		Seated.Add(Runner.bBot ? TEXT("bot") : FString::Printf(TEXT("%s (seat %d)"), *Runner.Player.Name, Runner.Seat));
	Trace(TEXT("seated ") + FString::Join(Seated, TEXT(", ")));
}

void ADashDerbyGameMode::HandleRosterChanged()
{
	// Someone joined or left mid-round. Keep everyone who is still seated
	// (with their score), add the newcomers, drop who left.
	UGameNightSubsystem* GN = GameNight();
	const TArray<FGameNightSeat> Seats = GN->GetCouchOrder();
	TArray<FOrbRunner> Kept;
	for (const FGameNightSeat& Seat : Seats)
	{
		if (Seat.Occupant == EGameNightOccupant::Empty) continue;
		const bool bBot = Seat.Occupant == EGameNightOccupant::AI;
		const int32 Known = Runners.IndexOfByPredicate([&](const FOrbRunner& R) {
			return R.Seat == Seat.Index && R.bBot == bBot && R.Player.Id == Seat.PlayerId;
		});
		if (Known != INDEX_NONE)
		{
			Kept.Add(Runners[Known]);
			Runners.RemoveAt(Known);
			continue;
		}
		FOrbRunner Runner;
		Runner.Seat = Seat.Index;
		Runner.bBot = bBot;
		if (!bBot) GN->GetPlayer(Seat.PlayerId, Runner.Player);
		Runner.Position = FreeSpot();
		Trace(TEXT("joined ") + (bBot ? FString(TEXT("bot")) : Runner.Player.Name));
		Kept.Add(MoveTemp(Runner));
	}
	for (FOrbRunner& Gone : Runners)
	{
		if (Gone.Body.IsValid()) Gone.Body->Destroy();
		if (Gone.Crown.IsValid()) Gone.Crown->Destroy();
		Trace(TEXT("left ") + Gone.Player.Name);
	}
	Runners.Reset();
	for (FOrbRunner& Runner : Kept) AddRunner(MoveTemp(Runner));
	MenuOwner = -1;
}

void ADashDerbyGameMode::HandlePlayersUpdated()
{
	// A name, colour or face changed. Update in place; never restart.
	UGameNightSubsystem* GN = GameNight();
	for (FOrbRunner& Runner : Runners)
	{
		if (Runner.Player.Id.IsEmpty()) continue;
		GN->GetPlayer(Runner.Player.Id, Runner.Player);
		ApplyShape(Runner);
		SendPhoneView(Runner);
	}
	Trace(TEXT("players updated"));
}

// ---- settings, actions, phones ---------------------------------------------

void ADashDerbyGameMode::ApplySetting(const FString& Key, const FString& ValueJson)
{
	const Json Value = Json::parse(UGameNightSubsystem::ToUtf8(ValueJson));
	if (Key == TEXT("round_seconds")) RoundSeconds = FMath::Clamp(static_cast<int32>(Value.integer(RoundSeconds)), 20, 180);
	else if (Key == TEXT("orbs")) OrbCount = FMath::Clamp(static_cast<int32>(Value.integer(OrbCount)), 2, 16);
	else if (Key == TEXT("bumps")) bBumps = Value.boolean(bBumps);
	else return;
	Trace(FString::Printf(TEXT("setting %s = %s"), *Key, *ValueJson));
}

void ADashDerbyGameMode::HandleSettingChanged(const FString& Key, const FString& ValueJson)
{
	// Values from the party apply from the next round (orbs fill up at once).
	ApplySetting(Key, ValueJson);
	while (Orbs.Num() < OrbCount && Runners.Num() > 0) Orbs.Add(FreeSpot());
}

void ADashDerbyGameMode::HandlePlayerSettings(const FString& PlayerId)
{
	for (FOrbRunner& Runner : Runners)
		if (Runner.Player.Id == PlayerId) ApplyShape(Runner);
}

void ADashDerbyGameMode::HandleAction(const FString& Key, const FString& PlayerId)
{
	// The room log already says who pressed it.
	if (Key == TEXT("new_round"))
	{
		Trace(TEXT("action new_round"));
		NewRound();
	}
}

void ADashDerbyGameMode::HandlePhone(const FString& PlayerId, const FString& DataJson)
{
	// Phone messages are untrusted input: check them against the rules.
	const Json Data = Json::parse(UGameNightSubsystem::ToUtf8(DataJson));
	if (Data["tap"].str() != "boost") return;
	for (FOrbRunner& Runner : Runners)
	{
		if (Runner.Player.Id != PlayerId || Runner.BoostCooldown > 0.0f || bHostPaused) continue;
		Runner.Boost = BoostTime;
		Runner.BoostCooldown = BoostCooldownTime;
		Trace(TEXT("boost ") + Runner.Player.Name);
		SendPhoneView(Runner);
	}
}

void ADashDerbyGameMode::HandlePhonePresence(const FString& PlayerId, bool bConnected)
{
	// Phones reload and sleep: send the whole view again on connect.
	for (FOrbRunner& Runner : Runners)
	{
		if (Runner.Player.Id != PlayerId) continue;
		Runner.bPhone = bConnected;
		if (bConnected) SendPhoneView(Runner);
	}
}

void ADashDerbyGameMode::SendPhoneView(const FOrbRunner& Runner)
{
	UGameNightSubsystem* GN = GameNight();
	if (!GN || Runner.Player.Id.IsEmpty()) return;
	// The game decides, the phone draws: send the view, not the history.
	Json View = Json::MakeObject();
	View.set("name", ToJson(Runner.Player.Name))
	    .set("color", ToJson(Hex(Runner.Player.Color)))
	    .set("score", Runner.Score)
	    .set("round", Round)
	    .set("clock", FMath::CeilToInt(FMath::Max(Clock, 0.0f)))
	    .set("results", Results > 0.0f)
	    .set("boost", Runner.BoostCooldown <= 0.0f);
	GN->SendCompanionMessage(View, Runner.Player.Id);
}

void ADashDerbyGameMode::SendPhoneViews()
{
	for (const FOrbRunner& Runner : Runners)
		if (Runner.bPhone || !Runner.Player.Id.IsEmpty()) SendPhoneView(Runner);
}

// ---- runners -----------------------------------------------------------------

void ADashDerbyGameMode::AddRunner(FOrbRunner Runner)
{
	const int32 Index = Runners.Num();
	if (Runner.Player.Id.IsEmpty() && Runner.Player.Name.IsEmpty())
	{
		Runner.Player.Name = BotNames[Index % UE_ARRAY_COUNT(BotNames)];
		Runner.Player.Color = BotColors[Index % UE_ARRAY_COUNT(BotColors)];
		Runner.Player.bHasColor = true;
	}
	if (!Runner.Player.bHasColor) Runner.Player.Color = BotColors[Index % UE_ARRAY_COUNT(BotColors)];
	if (!Runner.Body.IsValid())
	{
		AStaticMeshActor* Body = GetWorld()->SpawnActor<AStaticMeshActor>(FVector::ZeroVector, FRotator::ZeroRotator);
		Body->SetMobility(EComponentMobility::Movable);
		Body->GetStaticMeshComponent()->SetCollisionEnabled(ECollisionEnabled::NoCollision);
		Body->GetStaticMeshComponent()->SetMaterial(0, UMaterialInstanceDynamic::Create(ShapeMaterial, Body));
		Runner.Body = Body;
		AStaticMeshActor* Crown = GetWorld()->SpawnActor<AStaticMeshActor>(FVector::ZeroVector, FRotator::ZeroRotator);
		Crown->SetMobility(EComponentMobility::Movable);
		UStaticMeshComponent* CrownMesh = Crown->GetStaticMeshComponent();
		CrownMesh->SetStaticMesh(ConeMesh);
		CrownMesh->SetCollisionEnabled(ECollisionEnabled::NoCollision);
		UMaterialInstanceDynamic* Gold = UMaterialInstanceDynamic::Create(ShapeMaterial, Crown);
		Gold->SetVectorParameterValue(TEXT("Color"), FLinearColor(1.0f, 0.75f, 0.15f));
		CrownMesh->SetMaterial(0, Gold);
		Crown->SetActorScale3D(FVector(0.45, 0.45, 0.35));
		Crown->SetActorHiddenInGame(true);
		Runner.Crown = Crown;
	}
	ApplyShape(Runner);
	Runners.Add(MoveTemp(Runner));
}

void ADashDerbyGameMode::ApplyShape(FOrbRunner& Runner)
{
	if (UGameNightSubsystem* GN = GameNight(); GN && !Runner.Player.Id.IsEmpty())
	{
		const std::string Shape = GN->Core().player_setting(UGameNightSubsystem::ToUtf8(Runner.Player.Id), "shape").str("ball");
		Runner.Shape = UGameNightSubsystem::FromUtf8(Shape);
	}
	if (!Runner.Body.IsValid()) return;
	UStaticMeshComponent* Mesh = Runner.Body->GetStaticMeshComponent();
	Mesh->SetStaticMesh(Runner.Shape == TEXT("cube") ? CubeMesh : (Runner.Shape == TEXT("cone") ? ConeMesh : SphereMesh));
	if (UMaterialInstanceDynamic* Material = Cast<UMaterialInstanceDynamic>(Mesh->GetMaterial(0)))
	{
		// The player's colour is the body; their face rides above it (HUD).
		Material->SetVectorParameterValue(TEXT("Color"), Runner.Player.Color);
	}
}

void ADashDerbyGameMode::ClearRunners()
{
	for (FOrbRunner& Runner : Runners)
	{
		if (Runner.Body.IsValid()) Runner.Body->Destroy();
		if (Runner.Crown.IsValid()) Runner.Crown->Destroy();
	}
	Runners.Reset();
}

FVector2D ADashDerbyGameMode::FreeSpot()
{
	return FVector2D(Random.FRandRange(static_cast<float>(Arena.Min.X) + 60.0f, static_cast<float>(Arena.Max.X) - 60.0f),
	                 Random.FRandRange(static_cast<float>(Arena.Min.Y) + 60.0f, static_cast<float>(Arena.Max.Y) - 60.0f));
}

FVector ADashDerbyGameMode::BodyLocation(const FOrbRunner& Runner) const
{
	return FVector(-Runner.Position.Y, Runner.Position.X, RunnerRadius);
}

int32 ADashDerbyGameMode::BestScore(const FOrbRunner& Runner) const
{
	const UGameNightSubsystem* GN = GameNight();
	if (!GN || Runner.Player.Id.IsEmpty()) return 0;
	return static_cast<int32>(GN->Core().player_data(UGameNightSubsystem::ToUtf8(Runner.Player.Id))["best"].integer());
}

bool ADashDerbyGameMode::HasCrown(const FOrbRunner& Runner) const
{
	// Tonight's crown: unlocked by anyone present, worn by the leader.
	const UGameNightSubsystem* GN = GameNight();
	if (!GN || !GN->PartyUnion().Contains(TEXT("crown")) || Runners.Num() < 2) return false;
	for (const FOrbRunner& Other : Runners)
		if (Other.Score >= Runner.Score && &Other != &Runner) return false;
	return Runner.Score > 0;
}

// ---- rounds ------------------------------------------------------------------

void ADashDerbyGameMode::NewRound()
{
	++Round;
	Clock = static_cast<float>(RoundSeconds);
	Results = 0.0f;
	for (int32 I = 0; I < Runners.Num(); ++I)
	{
		const double Angle = 2.0 * UE_PI * I / FMath::Max(1, Runners.Num());
		Runners[I].Position = Arena.GetCenter() + FVector2D(FMath::Cos(Angle), FMath::Sin(Angle)) * 420.0;
		Runners[I].Velocity = FVector2D::ZeroVector;
		Runners[I].Score = 0;
		Runners[I].Dash = Runners[I].Cooldown = Runners[I].Boost = Runners[I].BoostCooldown = 0.0f;
	}
	Orbs.Reset();
	for (int32 I = 0; I < OrbCount; ++I) Orbs.Add(FreeSpot());
	MenuOwner = -1;
	SyncActors();
	SendPhoneViews();
	Trace(FString::Printf(TEXT("round %d"), Round));
}

void ADashDerbyGameMode::EndRound()
{
	Results = ResultsSeconds;
	TArray<const FOrbRunner*> Ranking;
	for (const FOrbRunner& Runner : Runners) Ranking.Add(&Runner);
	Ranking.StableSort([](const FOrbRunner& A, const FOrbRunner& B) { return A.Score > B.Score; });
	const FOrbRunner& Winner = *Ranking[0];
	Trace(FString::Printf(TEXT("round %d won by %s"), Round, *Winner.Player.Name));
	UGameNightSubsystem* GN = GameNight();
	if (GN && GN->IsLaunchedByGameNight())
	{
		// The session goes on: results now, then the next round, until the
		// party picks another game.
		GN->NotifyFinished();
		GN->AddRoomLog(FString::Printf(TEXT("%s won round %d with %d orbs"), *Winner.Player.Name, Round, Winner.Score));
		SaveProgress();
		// What the group earns counts for everyone who was there.
		if (Winner.Score >= 10) GN->UnlockForPresent(TEXT("crown"));
	}
	SendPhoneViews();
}

void ADashDerbyGameMode::SaveProgress()
{
	// Each player's own progress, kept with their profile between nights.
	UGameNightSubsystem* GN = GameNight();
	for (const FOrbRunner& Runner : Runners)
	{
		if (Runner.Player.Id.IsEmpty() || Runner.bBot) continue;
		const std::string Id = UGameNightSubsystem::ToUtf8(Runner.Player.Id);
		Json Data = GN->Core().player_data(Id);
		if (!Data.is_object()) Data = Json::MakeObject();
		Data.set("best", FMath::Max(static_cast<int64>(Data["best"].integer()), static_cast<int64>(Runner.Score)));
		Data.set("orbs", Data["orbs"].integer() + Runner.Score);
		Data.set("rounds", Data["rounds"].integer() + 1);
		GN->Core().SavePlayerData(Id, Data);
	}
}

// ---- the frame -----------------------------------------------------------------

FVector2D ADashDerbyGameMode::ReadMove(FOrbRunner& Runner, uint32& OutPressed)
{
	OutPressed = 0;
	FVector2D Move = FVector2D::ZeroVector;
	uint32 Held = 0;
	if (Runner.bBot)
	{
		FVector2D Target = Arena.GetCenter();
		double Best = TNumericLimits<double>::Max();
		for (const FVector2D& Orb : Orbs)
		{
			const double D = FVector2D::DistSquared(Runner.Position, Orb);
			if (D < Best)
			{
				Best = D;
				Target = Orb;
			}
		}
		Move = (Target - Runner.Position).GetClampedToMaxSize(1.0);
		if (FMath::Sqrt(Best) < 380.0 && Random.FRand() < 0.03f) OutPressed |= Bit(EGameNightButton::A);
		return Move;
	}
	if (Runner.Seat >= 0)
	{
		// GameNight input: this seat's controller, whichever device it is.
		UGameNightSubsystem* GN = GameNight();
		const FGameNightPad Pad = GN->GetPad(Runner.Seat, true);
		Move = Pad.LeftStick;
		for (const EGameNightButton Button : {EGameNightButton::A, EGameNightButton::B, EGameNightButton::Start,
		                                      EGameNightButton::Up, EGameNightButton::Down, EGameNightButton::Left,
		                                      EGameNightButton::Right})
		{
			if (GN->JustPressed(Runner.Seat, Button)) OutPressed |= Bit(Button);
		}
		if (Pad.Buttons != 0 || !Move.IsNearlyZero(0.3)) GN->ReportActivity(Runner.Seat);
	}
	else if (Runner.bKeyboard)
	{
		APlayerController* Controller = GetWorld()->GetFirstPlayerController();
		if (!Controller) return Move;
		const auto Down = [Controller](const FKey& Key) { return Controller->IsInputKeyDown(Key); };
		Move.X = Controller->GetInputAnalogKeyState(EKeys::Gamepad_LeftX) + (Down(EKeys::D) || Down(EKeys::Right) ? 1.0 : 0.0) -
		         (Down(EKeys::A) || Down(EKeys::Left) ? 1.0 : 0.0);
		// Unreal's stick Y points up; the field's y points down, like the wire.
		Move.Y = -Controller->GetInputAnalogKeyState(EKeys::Gamepad_LeftY) + (Down(EKeys::S) || Down(EKeys::Down) ? 1.0 : 0.0) -
		         (Down(EKeys::W) || Down(EKeys::Up) ? 1.0 : 0.0);
		if (Down(EKeys::SpaceBar) || Down(EKeys::Gamepad_FaceButton_Bottom)) Held |= Bit(EGameNightButton::A);
		if (Down(EKeys::BackSpace) || Down(EKeys::Gamepad_FaceButton_Right)) Held |= Bit(EGameNightButton::B);
		if (Down(EKeys::Escape) || Down(EKeys::Enter) || Down(EKeys::Gamepad_Special_Right)) Held |= Bit(EGameNightButton::Start);
		if (Move.Size() < 0.2) Move = FVector2D::ZeroVector;
	}
	// The stick works like a d-pad in the menu: one step per push.
	if (Move.X < -0.6) Held |= Bit(EGameNightButton::Left);
	if (Move.X > 0.6) Held |= Bit(EGameNightButton::Right);
	if (Move.Y < -0.6) Held |= Bit(EGameNightButton::Up);
	if (Move.Y > 0.6) Held |= Bit(EGameNightButton::Down);
	OutPressed |= Held & ~Runner.HeldBefore;
	Runner.HeldBefore = Held;
	return Move.GetClampedToMaxSize(1.0);
}

bool ADashDerbyGameMode::StepMenu(const TArray<uint32>& Pressed)
{
	const uint32 Start = Bit(EGameNightButton::Start);
	if (MenuOwner < 0)
	{
		for (int32 I = 0; I < Runners.Num(); ++I)
		{
			if (!Runners[I].bBot && (Pressed[I] & Start))
			{
				MenuOwner = I;
				MenuRow = 0;
				Trace(TEXT("menu open"));
				return true;
			}
		}
		return false;
	}
	const uint32 P = Pressed.IsValidIndex(MenuOwner) ? Pressed[MenuOwner] : Start;
	if (P & (Start | Bit(EGameNightButton::B)))
	{
		MenuOwner = -1;
		Trace(TEXT("menu closed"));
		return true;
	}
	const int32 Rows = MenuRows().Num();
	if (P & Bit(EGameNightButton::Down)) MenuRow = (MenuRow + 1) % Rows;
	if (P & Bit(EGameNightButton::Up)) MenuRow = (MenuRow + Rows - 1) % Rows;
	if ((P & Bit(EGameNightButton::A)) && MenuRow < 2)
	{
		MenuOwner = -1;
		Trace(TEXT("menu closed"));
		if (MenuRow == 1) NewRound();
		return true;
	}
	const int32 Step = ((P & Bit(EGameNightButton::Right)) ? 1 : 0) - ((P & Bit(EGameNightButton::Left)) ? 1 : 0);
	const bool bToggle = MenuRow == 4 && (P & Bit(EGameNightButton::A));
	if ((Step != 0 || bToggle) && MenuRow >= 2)
	{
		FString Key;
		FString Value;
		if (MenuRow == 2)
		{
			Key = TEXT("round_seconds");
			Value = FString::FromInt(FMath::Clamp(RoundSeconds + Step * 10, 20, 180));
		}
		else if (MenuRow == 3)
		{
			Key = TEXT("orbs");
			Value = FString::FromInt(FMath::Clamp(OrbCount + Step, 2, 16));
		}
		else
		{
			Key = TEXT("bumps");
			Value = bBumps ? TEXT("false") : TEXT("true");
		}
		ApplySetting(Key, Value);
		// Tell GameNight, so the phones and an LLM show the same value.
		UGameNightSubsystem* GN = GameNight();
		if (GN && GN->IsLaunchedByGameNight()) GN->SetSettingJson(Key, Value);
	}
	return true;
}

void ADashDerbyGameMode::Tick(float DeltaSeconds)
{
	Super::Tick(DeltaSeconds);
	if (bHostPaused || Runners.Num() == 0) return;
	DeltaSeconds = FMath::Min(DeltaSeconds, 1.0f / 20.0f);
	TArray<FVector2D> Moves;
	TArray<uint32> Pressed;
	for (FOrbRunner& Runner : Runners)
	{
		uint32 P = 0;
		Moves.Add(ReadMove(Runner, P));
		Pressed.Add(P);
	}
	// Start opens the menu for whoever pressed it; play waits meanwhile.
	if (StepMenu(Pressed)) return;
	Simulate(DeltaSeconds, Moves, Pressed);
	SyncActors();
	PhoneViewTimer -= DeltaSeconds;
	if (PhoneViewTimer <= 0.0f)
	{
		PhoneViewTimer = 0.5f;
		SendPhoneViews();
	}
}

void ADashDerbyGameMode::Simulate(float DeltaSeconds, const TArray<FVector2D>& Moves, const TArray<uint32>& Pressed)
{
	// Players keep moving while the results show; nothing scores.
	const bool bScoring = Results <= 0.0f;
	if (!bScoring)
	{
		Results -= DeltaSeconds;
		if (Results <= 0.0f)
		{
			NewRound();
			return;
		}
	}
	else
	{
		Clock -= DeltaSeconds;
	}
	UGameNightSubsystem* GN = GameNight();
	for (int32 I = 0; I < Runners.Num(); ++I)
	{
		FOrbRunner& R = Runners[I];
		const FVector2D Move = Moves[I];
		R.Cooldown = FMath::Max(0.0f, R.Cooldown - DeltaSeconds);
		R.Dash = FMath::Max(0.0f, R.Dash - DeltaSeconds);
		R.Boost = FMath::Max(0.0f, R.Boost - DeltaSeconds);
		R.BoostCooldown = FMath::Max(0.0f, R.BoostCooldown - DeltaSeconds);
		if ((Pressed[I] & Bit(EGameNightButton::A)) && R.Cooldown == 0.0f)
		{
			R.Dash = DashTime;
			R.Cooldown = DashCooldown;
			R.Velocity = (Move.IsNearlyZero() ? FVector2D(1.0, 0.0) : Move.GetSafeNormal()) * DashSpeed;
			Trace(TEXT("dash ") + R.Player.Name);
		}
		if (R.Dash == 0.0f)
		{
			const float Top = Speed * (R.Boost > 0.0f ? 1.6f : 1.0f);
			R.Velocity = FMath::Lerp(R.Velocity, Move * Top, 1.0f - FMath::Exp(-12.0f * DeltaSeconds));
		}
		R.Position += R.Velocity * DeltaSeconds;
		R.Position.X = FMath::Clamp(R.Position.X, Arena.Min.X + RunnerRadius, Arena.Max.X - RunnerRadius);
		R.Position.Y = FMath::Clamp(R.Position.Y, Arena.Min.Y + RunnerRadius, Arena.Max.Y - RunnerRadius);
	}
	Collide();
	if (!bScoring) return;
	for (FOrbRunner& R : Runners)
	{
		for (FVector2D& Orb : Orbs)
		{
			if (FVector2D::Distance(R.Position, Orb) >= RunnerRadius + OrbRadius) continue;
			++R.Score;
			Orb = FreeSpot();
			if (R.Seat >= 0 && GN) GN->Rumble(R.Seat, 0.3f, 0.0f, 0.08f);
		}
	}
	if (Clock <= 0.0f) EndRound();
}

void ADashDerbyGameMode::Collide()
{
	UGameNightSubsystem* GN = GameNight();
	for (int32 I = 0; I < Runners.Num(); ++I)
	{
		for (int32 J = I + 1; J < Runners.Num(); ++J)
		{
			FOrbRunner& A = Runners[I];
			FOrbRunner& B = Runners[J];
			const FVector2D Gap = B.Position - A.Position;
			const double Overlap = RunnerRadius * 2.0 - Gap.Size();
			if (Overlap <= 0.0 || Gap.IsNearlyZero()) continue;
			const FVector2D N = Gap.GetSafeNormal();
			A.Position -= N * Overlap * 0.5;
			B.Position += N * Overlap * 0.5;
			// A dashing player shoves the other one away.
			if (!bBumps || (A.Dash <= 0.0f && B.Dash <= 0.0f)) continue;
			FOrbRunner& Hitter = A.Dash > B.Dash ? A : B;
			FOrbRunner& Hit = A.Dash > B.Dash ? B : A;
			Hit.Velocity = (Hit.Position - Hitter.Position).GetSafeNormal() * DashSpeed * 0.8;
			Hit.Dash = DashTime;
			if (Hit.Seat >= 0 && GN) GN->Rumble(Hit.Seat, 0.2f, 0.8f, 0.25f);
			Trace(TEXT("bump ") + Hit.Player.Name);
		}
	}
}

void ADashDerbyGameMode::SyncActors()
{
	for (FOrbRunner& Runner : Runners)
	{
		const FVector At = BodyLocation(Runner);
		if (Runner.Body.IsValid())
		{
			const double Squash = Runner.Dash > 0.0f ? 0.8 : 1.0;
			Runner.Body->SetActorLocation(At);
			Runner.Body->SetActorScale3D(FVector(1.0 / Squash, 1.0 / Squash, Squash));
		}
		if (Runner.Crown.IsValid())
		{
			const bool bCrown = HasCrown(Runner);
			Runner.Crown->SetActorHiddenInGame(!bCrown);
			if (bCrown) Runner.Crown->SetActorLocation(At + FVector(0, 0, RunnerRadius + 30.0));
		}
	}
	while (OrbActors.Num() < Orbs.Num())
	{
		AStaticMeshActor* Orb = GetWorld()->SpawnActor<AStaticMeshActor>(FVector::ZeroVector, FRotator::ZeroRotator);
		Orb->SetMobility(EComponentMobility::Movable);
		UStaticMeshComponent* Mesh = Orb->GetStaticMeshComponent();
		Mesh->SetStaticMesh(SphereMesh);
		Mesh->SetCollisionEnabled(ECollisionEnabled::NoCollision);
		UMaterialInstanceDynamic* Glow = UMaterialInstanceDynamic::Create(ShapeMaterial, Orb);
		Glow->SetVectorParameterValue(TEXT("Color"), FLinearColor(1.0f, 0.85f, 0.35f));
		Mesh->SetMaterial(0, Glow);
		Orb->SetActorScale3D(FVector(OrbRadius * 2.0 / 100.0));
		OrbActors.Add(Orb);
	}
	for (int32 I = 0; I < OrbActors.Num(); ++I)
	{
		const bool bUsed = Orbs.IsValidIndex(I);
		OrbActors[I]->SetActorHiddenInGame(!bUsed);
		if (bUsed) OrbActors[I]->SetActorLocation(FVector(-Orbs[I].Y, Orbs[I].X, OrbRadius + 10.0));
	}
}
