using UnrealBuildTool;

public class DashDerbyTarget : TargetRules
{
	public DashDerbyTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Game;
		DefaultBuildSettings = BuildSettingsVersion.Latest;
		IncludeOrderVersion = EngineIncludeOrderVersion.Latest;
		ExtraModuleNames.Add("DashDerby");
	}
}
