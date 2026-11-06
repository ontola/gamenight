using UnrealBuildTool;

public class OrbRushEditorTarget : TargetRules
{
	public OrbRushEditorTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Editor;
		DefaultBuildSettings = BuildSettingsVersion.Latest;
		IncludeOrderVersion = EngineIncludeOrderVersion.Latest;
		ExtraModuleNames.Add("OrbRush");
	}
}
