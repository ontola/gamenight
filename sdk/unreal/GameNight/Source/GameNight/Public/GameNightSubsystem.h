// UGameNightSubsystem: GameNight in an Unreal game.
//
// One per game instance, alive from boot to quit, ticking also while the game
// is paused. The integration contract, as in every GameNight SDK:
//
// 1. Set the game id in Project Settings > Plugins > GameNight.
// 2. OnPrepared: build the level for GetSeats()/GetPlayers() while hidden,
//    then call NotifyReady(). Don't show anything yet.
// 3. OnStarted: you are on screen. Start the match instantly.
// 4. OnPaused/OnResumed: the party went to the lobby and back.
// 5. A round ends: NotifyFinished(), show results, play the next round.
//    Rounds repeat until the party picks another game.
// 6. OnDisposed: tear the session down. A new OnPrepared may follow.
//
// Read input per seat with GetPad() and JustPressed(), never from local
// device order: GameNight routes every controller and phone to a seat.
// The window, audio and world pause follow the session automatically
// (UGameNightSettings), and F1 returns to the party.
#pragma once

#include "CoreMinimal.h"
#include "Subsystems/GameInstanceSubsystem.h"
#include "Tickable.h"

#include "GameNightCore.h"
#include "GameNightTypes.h"

#include "GameNightSubsystem.generated.h"

class FSocket;
class UCanvas;
class UTexture2D;

DECLARE_LOG_CATEGORY_EXTERN(LogGameNight, Log, All);

DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FGameNightSessionEvent, const FString&, SessionId);
DECLARE_DYNAMIC_MULTICAST_DELEGATE(FGameNightEvent);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(FGameNightSettingEvent, const FString&, Key, const FString&, ValueJson);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FGameNightPlayerEvent, const FString&, PlayerId);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(FGameNightActionEvent, const FString&, Key, const FString&, PlayerId);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(FGameNightCompanionEvent, const FString&, PlayerId, const FString&, DataJson);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(FGameNightPresenceEvent, const FString&, PlayerId, bool, bConnected);

UCLASS()
class GAMENIGHT_API UGameNightSubsystem : public UGameInstanceSubsystem, public FTickableGameObject
{
	GENERATED_BODY()

public:
	// The subsystem of the game instance this object lives in.
	static UGameNightSubsystem* Get(const UObject* WorldContext);

	// -- session lifecycle ---------------------------------------------------

	// Warm up: load everything for these seats, then call NotifyReady().
	UPROPERTY(BlueprintAssignable, Category = "GameNight")
	FGameNightSessionEvent OnPrepared;

	// The transition landed on you. Start the match NOW.
	UPROPERTY(BlueprintAssignable, Category = "GameNight")
	FGameNightSessionEvent OnStarted;

	UPROPERTY(BlueprintAssignable, Category = "GameNight")
	FGameNightSessionEvent OnPaused;

	UPROPERTY(BlueprintAssignable, Category = "GameNight")
	FGameNightSessionEvent OnResumed;

	// Tear the session down; the id is never used again.
	UPROPERTY(BlueprintAssignable, Category = "GameNight")
	FGameNightSessionEvent OnDisposed;

	// -- party ---------------------------------------------------------------

	UPROPERTY(BlueprintAssignable, Category = "GameNight")
	FGameNightEvent OnConnected;

	// A launched game quits on its own right after this.
	UPROPERTY(BlueprintAssignable, Category = "GameNight")
	FGameNightEvent OnDisconnected;

	// Seats and players changed mid-session (after NotifyParticipation).
	UPROPERTY(BlueprintAssignable, Category = "GameNight")
	FGameNightEvent OnRosterChanged;

	// The same players changed name, colour or face. Update in place; the
	// match keeps going, so never restart over it.
	UPROPERTY(BlueprintAssignable, Category = "GameNight")
	FGameNightEvent OnPlayersUpdated;

	// A declared setting changed (from a phone, an LLM or your own menu).
	UPROPERTY(BlueprintAssignable, Category = "GameNight")
	FGameNightSettingEvent OnSettingChanged;

	UPROPERTY(BlueprintAssignable, Category = "GameNight")
	FGameNightPlayerEvent OnPlayerSettingsChanged;

	// A player's saved progress arrived. Read it with GetPlayerDataJson.
	UPROPERTY(BlueprintAssignable, Category = "GameNight")
	FGameNightPlayerEvent OnPlayerDataChanged;

	// A phone button you declared with DeclareActions was pressed.
	UPROPERTY(BlueprintAssignable, Category = "GameNight")
	FGameNightActionEvent OnActionTriggered;

	// A phone page sent JSON. Treat it as untrusted input.
	UPROPERTY(BlueprintAssignable, Category = "GameNight")
	FGameNightCompanionEvent OnCompanionMessage;

	// A phone page opened or closed: send that player their view on connect.
	UPROPERTY(BlueprintAssignable, Category = "GameNight")
	FGameNightPresenceEvent OnCompanionPresence;

	// -- state ---------------------------------------------------------------

	// True when GameNight launched this process (GAMENIGHT=1): skip menus and
	// wait for OnPrepared.
	UFUNCTION(BlueprintPure, Category = "GameNight")
	bool IsLaunchedByGameNight() const { return bLaunched; }

	UFUNCTION(BlueprintPure, Category = "GameNight")
	bool IsConnected() const;

	UFUNCTION(BlueprintPure, Category = "GameNight")
	EGameNightPhase GetPhase() const;

	UFUNCTION(BlueprintPure, Category = "GameNight")
	FString GetSessionId() const;

	UFUNCTION(BlueprintPure, Category = "GameNight")
	FString GetGameId() const { return GameId; }

	UFUNCTION(BlueprintCallable, Category = "GameNight")
	TArray<FGameNightSeat> GetSeats() const;

	UFUNCTION(BlueprintCallable, Category = "GameNight")
	TArray<FGameNightPlayer> GetPlayers() const;

	UFUNCTION(BlueprintCallable, Category = "GameNight")
	bool GetPlayer(const FString& PlayerId, FGameNightPlayer& OutPlayer) const;

	// The person in this seat. False for bots and empty seats.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	bool GetPlayerForSeat(int32 SeatIndex, FGameNightPlayer& OutPlayer) const;

	// Seats left to right as the players sit on the couch. Lay out split
	// screens and score rows in this order; call again on OnPlayersUpdated.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	TArray<FGameNightSeat> GetCouchOrder() const;

	// How many seats hold a person on this machine. This, not the number of
	// pads you can see, is your player count.
	UFUNCTION(BlueprintPure, Category = "GameNight")
	int32 LocalSeatCount() const;

	// How many seats the party wants a bot in.
	UFUNCTION(BlueprintPure, Category = "GameNight")
	int32 AiSeatCount() const;

	// -- lifecycle -----------------------------------------------------------

	// Assets loaded, inputs bound: the session can start instantly.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	void NotifyReady();

	// A round ended. Keep your results screen and next round in the game.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	void NotifyFinished();

	// One short line for the room log in the app ("Ann won round 3").
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	void AddRoomLog(const FString& Text);

	// Opt into OnRosterChanged for this session. Call from OnPrepared, before
	// NotifyReady. bInstantJoin: a running match can take a new player now.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	void NotifyParticipation(bool bInstantJoin);

	// How far loading is, 0 to 100, so the lobby shows something truthful.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	void NotifyProgress(int32 Percent, const FString& Label);

	// Back to the party. F1 does this already.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	void RequestOverlay();

	// -- input ---------------------------------------------------------------

	// Host input for a seat. Neutral unless the session runs; set bAnyPhase
	// to read it anyway, for your own Start menu.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	FGameNightPad GetPad(int32 SeatIndex, bool bAnyPhase = false) const;

	// True on the frame a seat's button went down. A button still held
	// from the lobby must be released first.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	bool JustPressed(int32 SeatIndex, EGameNightButton Button) const;

	// A person is really playing on this seat, so GameNight does not mark
	// them asleep. Call on meaningful input; it sends at most once a second.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	void ReportActivity(int32 SeatIndex);

	// Vibrate this seat's controller. Weak is the light motor, strong the
	// heavy one, both 0 to 1, for up to 5 seconds. Zeros stop it.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	void Rumble(int32 SeatIndex, float Weak, float Strong, float Seconds);

	// -- settings and saves --------------------------------------------------

	// The match settings the party may change, as a JSON array of specs:
	// [{"key":"orbs","label":"Orbs","kind":"number","default":6,"min":2,"max":16}]
	// Re-declared after every reconnect; changes arrive in OnSettingChanged.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	void DeclareSettingsJson(const FString& SettingsJson);
	void DeclareSettings(const gamenight::Json& Settings);

	// Phone buttons next to your settings, as a JSON array:
	// [{"key":"new_round","label":"New round","confirm":true}]
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	void DeclareActionsJson(const FString& ActionsJson);
	void DeclareActions(const gamenight::Json& Actions);

	// Change one of your declared settings, for example from the Start menu,
	// so the party's phones show the same value. Answered by OnSettingChanged.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	void SetSettingJson(const FString& Key, const FString& ValueJson);
	void SetSetting(const FString& Key, const gamenight::Json& Value);

	UFUNCTION(BlueprintCallable, Category = "GameNight")
	int32 GetSettingInt(const FString& Key, int32 Fallback) const;

	UFUNCTION(BlueprintCallable, Category = "GameNight")
	bool GetSettingBool(const FString& Key, bool Fallback) const;

	UFUNCTION(BlueprintCallable, Category = "GameNight")
	FString GetSettingString(const FString& Key, const FString& Fallback) const;

	// A player's own value of a "scope": "player" setting, as JSON ("null" if unset).
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	FString GetPlayerSettingJson(const FString& PlayerId, const FString& Key) const;

	UFUNCTION(BlueprintCallable, Category = "GameNight")
	void SetPlayerSettingJson(const FString& PlayerId, const FString& Key, const FString& ValueJson);

	// A player's saved progress as JSON, "null" when nothing is saved yet.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	FString GetPlayerDataJson(const FString& PlayerId) const;

	// Save one player's progress (any JSON up to 64 KB), kept with their profile.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	void SavePlayerDataJson(const FString& PlayerId, const FString& DataJson);

	// Adds Item to list Key in the saved progress of everyone here now.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	void UnlockForPresent(const FString& Item, const FString& Key = TEXT("unlocks"));

	// Everything in list Key of the players here now: one player's unlock is
	// everyone's tonight. Never save this back into one player's data.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	TArray<FString> PartyUnion(const FString& Key = TEXT("unlocks")) const;

	// -- phone screens -------------------------------------------------------

	// Serve a folder under Content/ (staged as loose files, see the docs) as
	// each player's phone screen. Returns the absolute folder, or empty.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	FString DeclareCompanionFolder(const FString& ContentFolder = TEXT("Phone"), const FString& Entry = TEXT("index.html"));

	// To one player's phone, or every phone when PlayerId is empty.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	void SendCompanionMessageJson(const FString& DataJson, const FString& PlayerId);
	void SendCompanionMessage(const gamenight::Json& Data, const FString& PlayerId = FString());

	// -- faces ---------------------------------------------------------------

	// The player's drawn face, or null when they have none. Nearest-filtered
	// and cached; a profile change gives a new texture.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	UTexture2D* GetFaceTexture(const FGameNightPlayer& Player);

	// Draws the player's head on a HUD canvas: the skin circle with radius
	// Radius at Center, their face on top (or the default face). Facing -1
	// mirrors it to look left.
	UFUNCTION(BlueprintCallable, Category = "GameNight")
	void DrawFace(UCanvas* Canvas, const FGameNightPlayer& Player, FVector2D Center, float Radius, float Facing = 1.0f);

	// -- C++ ------------------------------------------------------------------

	// The protocol core, for anything the Blueprint API does not cover.
	gamenight::Client& Core() { return *Client; }
	const gamenight::Client& Core() const { return *Client; }

	static FString FromUtf8(const std::string& Text);
	static std::string ToUtf8(const FString& Text);
	static FGameNightPlayer PlayerFromJson(const gamenight::Json& Player);

	// USubsystem
	virtual void Initialize(FSubsystemCollectionBase& Collection) override;
	virtual void Deinitialize() override;

	// FTickableGameObject
	virtual void Tick(float DeltaTime) override;
	virtual TStatId GetStatId() const override;
	virtual bool IsTickable() const override { return Client != nullptr; }
	virtual bool IsTickableWhenPaused() const override { return true; }
	virtual bool IsTickableInEditor() const override { return false; }
	virtual ETickableTickType GetTickableTickType() const override;

private:
	void Open();
	void CloseSocket();
	void Pump();
	void Flush();
	void Dispatch(const gamenight::Event& Event);
	void ApplyWorldPause();

	// Screen manners (bAutomaticScreen).
	enum class EScreenGoal : uint8 { None, Away, Front };
	void GoQuiet(const TCHAR* Why);
	void Settle();
	void Unthrottle();
	void TakeTheScreen(const TCHAR* Why);
	void PumpScreen();
	void SetMuted(bool bMuted);

	TUniquePtr<gamenight::Client> Client;
	FSocket* Socket = nullptr;
	TArray<uint8> SendBuffer;
	FString GameId;
	FString HostAddress;
	bool bLaunched = false;
	bool bAutoReconnect = false;
	double ReconnectAt = 0.0;
	bool bQuitting = false;

	EScreenGoal ScreenGoal = EScreenGoal::None;
	double ScreenAskedAt = -1000.0;
	double ScreenDeadline = 0.0;
	float FpsBeforeWarm = -1.0f;
	bool bThrottled = false;

	TSharedPtr<class FGameNightInputProcessor> InputProcessor;

	UPROPERTY(Transient)
	TMap<FString, TObjectPtr<UTexture2D>> FaceTextures;

	UPROPERTY(Transient)
	TObjectPtr<UTexture2D> DiscTexture;
};
