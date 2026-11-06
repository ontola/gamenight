// What the TV shows: faces above the players, the clock, the scores, the
// results and the Start menu. Only the clock and scores are on screen while
// playing; names show on the results. No button hints.
#pragma once

#include "CoreMinimal.h"
#include "GameFramework/HUD.h"

#include "DashDerbyHUD.generated.h"

UCLASS()
class ADashDerbyHUD : public AHUD
{
	GENERATED_BODY()

public:
	virtual void DrawHUD() override;

private:
	void Text(const FString& Line, float X, float Y, float Scale, const FLinearColor& Color, int32 Align = 0);
	void Panel(float X, float Y, float W, float H, const FLinearColor& Border);
	float Unit = 1.0f;
};
