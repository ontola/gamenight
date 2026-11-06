// The GameNight runtime module. The protocol core (GameNightCore.*) is plain
// C++17 and needs none of these; the rest is the Unreal side: sockets, the
// game window, audio and canvas drawing.
using UnrealBuildTool;

public class GameNight : ModuleRules
{
	public GameNight(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		PublicDependencyModuleNames.AddRange(new string[]
		{
			"Core",
			"CoreUObject",
			"Engine",
			"DeveloperSettings",
		});

		PrivateDependencyModuleNames.AddRange(new string[]
		{
			"ApplicationCore",
			"InputCore",
			"Slate",
			"SlateCore",
			"Sockets",
		});
	}
}
