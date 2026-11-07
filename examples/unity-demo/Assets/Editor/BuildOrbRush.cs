// Builds Orb Rush from the menu (GameNight > Build Orb Rush) or the command line:
//
//   Unity -batchmode -quit -projectPath examples/unity-demo -executeMethod OrbRush.Editor.BuildOrbRush.Windows
//
// The game builds its own scene at runtime, so the build only needs one empty
// scene. The player settings below are the ones every GameNight game needs.
using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

namespace OrbRush.Editor
{
    public static class BuildOrbRush
    {
        const string Scene = "Assets/OrbRush/OrbRush.unity";

        [MenuItem("GameNight/Build Orb Rush (Windows)")]
        public static void Windows() => Build(BuildTarget.StandaloneWindows64, "Builds/Windows/OrbRush.exe");

        [MenuItem("GameNight/Build Orb Rush (macOS)")]
        public static void MacOS() => Build(BuildTarget.StandaloneOSX, "Builds/macOS/OrbRush.app");

        [MenuItem("GameNight/Build Orb Rush (Linux)")]
        public static void Linux() => Build(BuildTarget.StandaloneLinux64, "Builds/Linux/OrbRush.x86_64");

        /// <summary>The player settings a GameNight game needs.</summary>
        [MenuItem("GameNight/Apply Gamepad Party player settings")]
        public static void ApplyPlayerSettings()
        {
            PlayerSettings.productName = "Orb Rush";
            PlayerSettings.companyName = "GameNight";
            // Keep running while another game or the lobby has focus: a warming
            // game that stops updating never hears Start.
            PlayerSettings.runInBackground = true;
            PlayerSettings.visibleInBackground = true;
            // Start windowed and small; the SDK takes borderless fullscreen on
            // Start. Never exclusive fullscreen: no display-mode switch between games.
            PlayerSettings.fullScreenMode = FullScreenMode.Windowed;
            PlayerSettings.defaultScreenWidth = 1280;
            PlayerSettings.defaultScreenHeight = 720;
            PlayerSettings.resizableWindow = true;
            PlayerSettings.forceSingleInstance = false;
            // No splash: Start must show gameplay within a second.
            PlayerSettings.SplashScreen.show = false;
        }

        static void Build(BuildTarget target, string output)
        {
            ApplyPlayerSettings();
            if (!File.Exists(Scene))
            {
                var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
                EditorSceneManager.SaveScene(scene, Scene);
            }
            Directory.CreateDirectory(Path.GetDirectoryName(output));
            var report = BuildPipeline.BuildPlayer(new[] { Scene }, output, target, BuildOptions.None);
            Debug.Log($"Orb Rush build: {report.summary.result}, {report.summary.totalSize / (1024 * 1024)} MiB at {output}");
            if (report.summary.result != UnityEditor.Build.Reporting.BuildResult.Succeeded && Application.isBatchMode)
                EditorApplication.Exit(1);
        }
    }
}
