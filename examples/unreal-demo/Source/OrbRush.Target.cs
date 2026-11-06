using UnrealBuildTool;

public class OrbRushTarget : TargetRules
{
	public OrbRushTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Game;
		DefaultBuildSettings = BuildSettingsVersion.Latest;
		IncludeOrderVersion = EngineIncludeOrderVersion.Latest;
		ExtraModuleNames.Add("OrbRush");
	}
}
