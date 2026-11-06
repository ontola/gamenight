// Orb Rush: the GameNight demo game for Unreal Engine.
//
// Everyone races for orbs; A dashes and knocks others aside; a round lasts 60
// seconds, then the results show and the next round starts by itself. The
// whole level is built in code from engine shapes, so this file and
// OrbRushGameMode.cpp are the entire game.
//
// What it shows, one GameNight feature at a time:
//   - prepare hidden, NotifyReady, start instantly, pause and resume
//   - input per seat (GetPad, JustPressed), bots in AI seats, activity, rumble
//   - names, colours and drawn faces, updated live (OnPlayersUpdated)
//   - players joining and leaving mid-round (NotifyParticipation)
//   - match settings from the phones and from the Start menu (SetSetting)
//   - a per-player setting (each player's shape)
//   - a phone button (DeclareActions) and a phone screen (Content/Phone)
//   - saved progress per player and an unlock for everyone present
//   - round results (NotifyFinished) and the room log (AddRoomLog)
#pragma once

#include "CoreMinimal.h"
#include "GameFramework/GameModeBase.h"
#include "GameNightTypes.h"

#include "OrbRushGameMode.generated.h"

class ACameraActor;
class AStaticMeshActor;
class UGameNightSubsystem;
class UMaterialInterface;
class UStaticMesh;

// One player on the field: a person in a seat, a bot, or the keyboard.
struct FOrbRunner
{
	FGameNightPlayer Player;  // empty Id for bots and standalone players
	int32 Seat = -1;          // GameNight seat, -1 when not managed
	bool bBot = false;
	bool bKeyboard = false;   // standalone: the local keyboard and first pad
	FString Shape = TEXT("ball");
	FVector2D Position = FVector2D::ZeroVector;
	FVector2D Velocity = FVector2D::ZeroVector;
	float Dash = 0.0f;
	float Cooldown = 0.0f;
	float Boost = 0.0f;           // phone button: a short speed boost
	float BoostCooldown = 0.0f;
	int32 Score = 0;
	bool bPhone = false;          // their phone screen is open
	TWeakObjectPtr<AStaticMeshActor> Body;
	TWeakObjectPtr<AStaticMeshActor> Crown;
	// Standalone menu input: what was held last frame.
	uint32 HeldBefore = 0;
};

UCLASS()
class AOrbRushGameMode : public AGameModeBase
{
	GENERATED_BODY()

public:
	AOrbRushGameMode();

	virtual void BeginPlay() override;
	virtual void PostLogin(APlayerController* NewPlayer) override;
	virtual void Tick(float DeltaSeconds) override;

	// Read by the HUD.
	TArray<FOrbRunner> Runners;
	TArray<FVector2D> Orbs;
	float Clock = 60.0f;
	float Results = 0.0f;
	int32 Round = 0;
	int32 MenuOwner = -1;
	int32 MenuRow = 0;
	int32 RoundSeconds = 60;
	int32 OrbCount = 6;
	bool bBumps = true;
	bool bHostPaused = false;

	static const FBox2D Arena;
	static constexpr float RunnerRadius = 50.0f;
	static constexpr float OrbRadius = 20.0f;
	static constexpr float ResultsSeconds = 4.0f;

	// The Start menu: title, Resume, New round, then the settings.
	static const TArray<FString>& MenuRows();
	FString MenuValue(int32 Row) const;
	FVector BodyLocation(const FOrbRunner& Runner) const;
	bool HasCrown(const FOrbRunner& Runner) const;
	int32 BestScore(const FOrbRunner& Runner) const;

private:
	UFUNCTION() void HandlePrepared(const FString& SessionId);
	UFUNCTION() void HandleStarted(const FString& SessionId);
	UFUNCTION() void HandlePaused(const FString& SessionId);
	UFUNCTION() void HandleResumed(const FString& SessionId);
	UFUNCTION() void HandleDisposed(const FString& SessionId);
	UFUNCTION() void HandleConnected();
	UFUNCTION() void HandleRosterChanged();
	UFUNCTION() void HandlePlayersUpdated();
	UFUNCTION() void HandleSettingChanged(const FString& Key, const FString& ValueJson);
	UFUNCTION() void HandlePlayerSettings(const FString& PlayerId);
	UFUNCTION() void HandleAction(const FString& Key, const FString& PlayerId);
	UFUNCTION() void HandlePhone(const FString& PlayerId, const FString& DataJson);
	UFUNCTION() void HandlePhonePresence(const FString& PlayerId, bool bConnected);

	void BuildLevel();
	void UseFixedCamera(APlayerController* Controller);
	void SeatFromSession();
	void AddRunner(FOrbRunner Runner);
	void ClearRunners();
	void NewRound();
	void EndRound();
	void ApplySetting(const FString& Key, const FString& ValueJson);
	void ApplyShape(FOrbRunner& Runner);
	FVector2D ReadMove(FOrbRunner& Runner, uint32& OutPressed);
	bool StepMenu(const TArray<uint32>& Pressed);
	void Simulate(float DeltaSeconds, const TArray<FVector2D>& Moves, const TArray<uint32>& Pressed);
	void Collide();
	FVector2D FreeSpot();
	void SyncActors();
	void SendPhoneView(const FOrbRunner& Runner);
	void SendPhoneViews();
	void SaveProgress();
	void Trace(const FString& Line) const;

	UGameNightSubsystem* GameNight() const;

	UPROPERTY(Transient) TObjectPtr<UStaticMesh> SphereMesh;
	UPROPERTY(Transient) TObjectPtr<UStaticMesh> CubeMesh;
	UPROPERTY(Transient) TObjectPtr<UStaticMesh> ConeMesh;
	UPROPERTY(Transient) TObjectPtr<UMaterialInterface> ShapeMaterial;
	UPROPERTY(Transient) TArray<TObjectPtr<AStaticMeshActor>> OrbActors;
	UPROPERTY(Transient) TObjectPtr<ACameraActor> FixedCamera;

	FRandomStream Random;
	bool bLevelBuilt = false;
	bool bTrace = false;
	float PhoneViewTimer = 0.0f;
	int32 StandalonePlayers = 1;
};
