# Orb Rush: the Unity reference game

A small 3D couch game that uses every Gamepad Party feature: everyone races for
orbs, A dashes and knocks others aside, a round lasts 60 seconds. Copy this
project to start your own Unity game; the [Unity guide](../../docs/site/unity.md)
walks through the code.

Open this folder in Unity 6 (2021.3 or later works). The project uses the
package from this repository (`Packages/manifest.json` points at
`../../../sdk/unity`); in your own project use the git URL from the guide.
Press Play in any scene, even an empty one: the game builds its own.

| File | What it does |
| --- | --- |
| `Assets/OrbRush/OrbRushGame.cs` | the rules and every Gamepad Party call, in plain C# |
| `Assets/OrbRush/OrbRushView.cs` | the Unity side: the 3D scene, faces, the HUD in couch order, the Start menu, local pads |
| `Assets/StreamingAssets/phone/index.html` | every player's phone screen: their score and a boost button |
| `Assets/Editor/BuildOrbRush.cs` | Gamepad Party player settings and builds (menu **Gamepad Party**) |
| `gamenight.json` | the game's store metadata |

Build from the command line:

```sh
Unity -batchmode -quit -projectPath examples/unity-demo -executeMethod OrbRush.Editor.BuildOrbRush.Windows
```

Test the rules without Unity, against a fake Gamepad Party host:

```sh
python3 scripts/test-unity-sdk.py
```

Standalone: WASD or a pad's stick to move, Space or A to dash, Escape or
Start for the menu. Bots fill the other seats. `-shot out.png -frames 120`
lets the bots play and saves frame 120.
