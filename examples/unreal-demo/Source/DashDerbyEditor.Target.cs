using UnrealBuildTool;

public class DashDerbyEditorTarget : TargetRules
{
	public DashDerbyEditorTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Editor;
		DefaultBuildSettings = BuildSettingsVersion.Latest;
		IncludeOrderVersion = EngineIncludeOrderVersion.Latest;
		ExtraModuleNames.Add("DashDerby");
	}
}
