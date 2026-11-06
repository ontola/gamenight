#include "OrbRushHUD.h"

#include "CanvasItem.h"
#include "Engine/Canvas.h"
#include "Engine/Engine.h"
#include "Engine/Font.h"
#include "Engine/World.h"
#include "GameNightSubsystem.h"
#include "OrbRushGameMode.h"

void AOrbRushHUD::Text(const FString& Line, float X, float Y, float Scale, const FLinearColor& Color, int32 Align)
{
	UFont* Font = GEngine->GetLargeFont();
	float Width = 0.0f;
	float Height = 0.0f;
	Canvas->TextSize(Font, Line, Width, Height, Scale * Unit, Scale * Unit);
	// Align: 0 centre, -1 left, 1 right of X.
	const float Left = Align == 0 ? X - Width / 2.0f : (Align < 0 ? X : X - Width);
	FCanvasTextItem Item(FVector2D(Left, Y - Height / 2.0f), FText::FromString(Line), Font, Color);
	Item.Scale = FVector2D(Scale * Unit, Scale * Unit);
	Item.EnableShadow(FLinearColor(0.0f, 0.0f, 0.0f, 0.6f));
	Canvas->DrawItem(Item);
}

void AOrbRushHUD::Panel(float X, float Y, float W, float H, const FLinearColor& Border)
{
	FCanvasTileItem Fill(FVector2D(X, Y) * Unit, FVector2D(W, H) * Unit, FLinearColor(0.02f, 0.015f, 0.04f, 0.9f));
	Fill.BlendMode = SE_BLEND_Translucent;
	Canvas->DrawItem(Fill);
	FCanvasBoxItem Box(FVector2D(X, Y) * Unit, FVector2D(W, H) * Unit);
	Box.LineThickness = 4.0f * Unit;
	Box.SetColor(Border);
	Canvas->DrawItem(Box);
}

void AOrbRushHUD::DrawHUD()
{
	Super::DrawHUD();
	AOrbRushGameMode* Mode = GetWorld() ? GetWorld()->GetAuthGameMode<AOrbRushGameMode>() : nullptr;
	UGameNightSubsystem* GN = UGameNightSubsystem::Get(this);
	if (!Mode || !GN || !Canvas || Mode->Runners.Num() == 0) return;
	// Lay out on a 1920 x 1080 grid, scaled to the real screen.
	Unit = Canvas->ClipY / 1080.0f;
	const float Middle = Canvas->ClipX / Unit / 2.0f;
	const FLinearColor White = FLinearColor::White;

	// Each player's own face rides above their body.
	for (const FOrbRunner& Runner : Mode->Runners)
	{
		const FVector Screen = Project(Mode->BodyLocation(Runner) + FVector(0.0, 0.0, 95.0));
		if (Screen.Z <= 0.0) continue;
		const float Facing = Runner.Velocity.X < -1.0 ? -1.0f : 1.0f;
		GN->DrawFace(Canvas, Runner.Player, FVector2D(Screen.X, Screen.Y), 30.0f * Unit, Facing);
	}

	// The only text while playing: the clock and the scores.
	Text(FString::FromInt(FMath::CeilToInt(FMath::Max(Mode->Clock, 0.0f))), Middle * Unit, 60.0f * Unit, 2.4f, White);
	const float RowLeft = Middle - Mode->Runners.Num() * 70.0f;
	for (int32 I = 0; I < Mode->Runners.Num(); ++I)
	{
		const FOrbRunner& Runner = Mode->Runners[I];
		const float X = RowLeft + I * 140.0f + 30.0f;
		GN->DrawFace(Canvas, Runner.Player, FVector2D(X, 1030.0f) * Unit, 22.0f * Unit);
		Text(FString::FromInt(Runner.Score), (X + 32.0f) * Unit, 1030.0f * Unit, 1.6f, Runner.Player.Color, -1);
	}

	if (Mode->Results > 0.0f)
	{
		TArray<const FOrbRunner*> Ranking;
		for (const FOrbRunner& Runner : Mode->Runners) Ranking.Add(&Runner);
		Ranking.StableSort([](const FOrbRunner& A, const FOrbRunner& B) { return A.Score > B.Score; });
		const float Height = 110.0f + Ranking.Num() * 70.0f;
		Panel(Middle - 330.0f, 300.0f, 660.0f, Height, Ranking[0]->Player.Color);
		Text(FString::Printf(TEXT("Round %d"), Mode->Round), Middle * Unit, 350.0f * Unit, 1.8f, White);
		for (int32 I = 0; I < Ranking.Num(); ++I)
		{
			const FOrbRunner& Runner = *Ranking[I];
			const float Y = 430.0f + I * 70.0f;
			GN->DrawFace(Canvas, Runner.Player, FVector2D(Middle - 260.0f, Y) * Unit, 24.0f * Unit);
			Text(Runner.Player.Name, (Middle - 220.0f) * Unit, Y * Unit, 1.5f, Runner.Player.Color, -1);
			const int32 Best = Mode->BestScore(Runner);
			const FString Score = Best > 0 ? FString::Printf(TEXT("%d   best %d"), Runner.Score, Best) : FString::FromInt(Runner.Score);
			Text(Score, (Middle + 300.0f) * Unit, Y * Unit, 1.5f, White, 1);
		}
	}

	if (Mode->MenuOwner >= 0 && Mode->Runners.IsValidIndex(Mode->MenuOwner))
	{
		// Every GameNight Start menu: the game's name, Resume, New round, then
		// the settings. No button hints.
		const TArray<FString>& Rows = AOrbRushGameMode::MenuRows();
		Panel(Middle - 300.0f, 260.0f, 600.0f, 150.0f + Rows.Num() * 64.0f, Mode->Runners[Mode->MenuOwner].Player.Color);
		Text(TEXT("Orb Rush"), Middle * Unit, 320.0f * Unit, 2.0f, White);
		for (int32 I = 0; I < Rows.Num(); ++I)
		{
			const float Y = 420.0f + I * 64.0f;
			const FLinearColor Color = I == Mode->MenuRow ? White : FLinearColor(1.0f, 1.0f, 1.0f, 0.5f);
			const FString Value = Mode->MenuValue(I);
			if (Value.IsEmpty())
			{
				Text(Rows[I], Middle * Unit, Y * Unit, 1.4f, Color);
				continue;
			}
			Text(Rows[I], (Middle - 260.0f) * Unit, Y * Unit, 1.4f, Color, -1);
			Text(FString::Printf(TEXT("< %s >"), *Value), (Middle + 260.0f) * Unit, Y * Unit, 1.4f, Color, 1);
		}
	}
}
