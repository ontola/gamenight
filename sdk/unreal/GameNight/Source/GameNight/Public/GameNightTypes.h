// Blueprint-facing types of the GameNight plugin: seats, players and pads.
// They are snapshots of the protocol JSON (docs/protocol.md), copied out of
// the core whenever you ask the subsystem for them.
#pragma once

#include "CoreMinimal.h"
#include "Engine/DeveloperSettings.h"

#include "GameNightTypes.generated.h"

UENUM(BlueprintType)
enum class EGameNightPhase : uint8
{
	// No session: warming up, or between games.
	Idle,
	// Load hidden, then call NotifyReady.
	Preparing,
	// Ready and waiting for Start.
	Ready,
	// On screen and playing.
	Running,
	// The party went back to the lobby. Freeze simulation, timers and audio.
	Paused,
};

UENUM(BlueprintType)
enum class EGameNightOccupant : uint8
{
	Empty,
	// A person on this machine.
	Local,
	// A person over the network (already on the wire).
	Remote,
	// Play this seat with a bot.
	AI,
};

// Controller frame buttons, in wire order (bit N of `buttons`).
UENUM(BlueprintType)
enum class EGameNightButton : uint8
{
	A = 0,
	B = 1,
	X = 2,
	Y = 3,
	LB = 4,
	RB = 5,
	// Owned by GameNight: it returns to the party. Never bind it in a game.
	Back = 6,
	Start = 7,
	LeftStick = 8,
	RightStick = 9,
	Up = 10,
	Down = 11,
	Left = 12,
	Right = 13,
};

USTRUCT(BlueprintType)
struct GAMENIGHT_API FGameNightPlayer
{
	GENERATED_BODY()

	// Opaque and stable for the night.
	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	FString Id;

	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	FString Name;

	// Clothing or team colour. Use it for the player's body.
	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	FLinearColor Color = FLinearColor::White;

	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	bool bHasColor = false;

	// The colour of the whole head circle; the drawn face goes on top.
	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	FLinearColor SkinColor = FLinearColor(0.913f, 0.815f, 0.515f);

	// Encoded face artwork. Draw it with UGameNightSubsystem::DrawFace.
	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	FString Avatar;

	// Where they sit on the couch from the left, or -1 when unknown.
	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	int32 Couch = -1;

	// Stable key for the person behind the player, for your own saves.
	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	FString ProfileKey;
};

USTRUCT(BlueprintType)
struct GAMENIGHT_API FGameNightSeat
{
	GENERATED_BODY()

	// Stable all night: player 2 stays player 2 across games.
	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	int32 Index = 0;

	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	EGameNightOccupant Occupant = EGameNightOccupant::Empty;

	// Empty for bots and empty seats.
	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	FString PlayerId;
};

// One seat's controller. Missing, disconnected and stale input is neutral.
USTRUCT(BlueprintType)
struct GAMENIGHT_API FGameNightPad
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	bool bPresent = false;

	// Bit N is EGameNightButton N.
	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	int32 Buttons = 0;

	// Radial deadzone applied, -1 to 1. Up is NEGATIVE Y, as on the wire.
	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	FVector2D LeftStick = FVector2D::ZeroVector;

	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	FVector2D RightStick = FVector2D::ZeroVector;

	// 0 to 1, deadzone applied.
	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	float LeftTrigger = 0.0f;

	UPROPERTY(BlueprintReadOnly, Category = "GameNight")
	float RightTrigger = 0.0f;

	bool IsDown(EGameNightButton Button) const { return (Buttons & (1 << static_cast<int32>(Button))) != 0; }
};

// Project Settings > Plugins > GameNight. Stored in DefaultGame.ini.
UCLASS(Config = Game, DefaultConfig, meta = (DisplayName = "GameNight"))
class GAMENIGHT_API UGameNightSettings : public UDeveloperSettings
{
	GENERATED_BODY()

public:
	// Must match the game's id in the GameNight catalog. GameNight passes it
	// in GAMENIGHT_GAME_ID when it launches the game; this is the fallback.
	// Empty means the project name in lower case.
	UPROPERTY(Config, EditAnywhere, Category = "Connection")
	FString GameId;

	// A game started by hand stays offline, so a test run never joins the
	// party on this machine. Turn this on (or set GAMENIGHT_ADDR) to connect
	// a hand-started game or a Play In Editor session to a running GameNight.
	UPROPERTY(Config, EditAnywhere, Category = "Connection")
	bool bConnectStandalone = false;

	UPROPERTY(Config, EditAnywhere, Category = "Connection")
	FString HostAddress = TEXT("127.0.0.1:7912");

	// Follow the session with the window: off screen and muted until Start,
	// borderless fullscreen in front on Start and Resume, away on Pause.
	UPROPERTY(Config, EditAnywhere, Category = "Screen")
	bool bAutomaticScreen = true;

	// Pause the world (UGameplayStatics::SetGamePaused) whenever the session is
	// not running, so physics, timers and game sounds stop on Pause.
	UPROPERTY(Config, EditAnywhere, Category = "Screen")
	bool bPauseWorldWhenNotRunning = true;

	// Frame cap once warm and ready, while nobody is watching yet.
	UPROPERTY(Config, EditAnywhere, Category = "Screen", meta = (ClampMin = 1))
	int32 WarmMaxFPS = 10;

	virtual FName GetCategoryName() const override { return TEXT("Plugins"); }
};
