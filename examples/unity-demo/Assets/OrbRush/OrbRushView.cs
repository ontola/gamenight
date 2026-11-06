// Orb Rush in Unity: draws OrbRushGame and feeds it local pads when nobody
// launched us. All the GameNight work is in OrbRushGame.cs; this file only
// shows what a Unity game adds: faces on the players, colours, a HUD in couch
// order and the Start menu.
//
// It builds its own scene, so any scene (even an empty one) plays the game:
//   OrbRush.exe                          standalone: you plus bots
//   OrbRush.exe -shot out.png -frames 120   bots play; save frame 120 and quit
// With GAME_TRACE=1 it logs what happens, like the headless test build.

using System;
using System.Collections.Generic;
using GameNightSdk;
using UnityEngine;
#if ENABLE_INPUT_SYSTEM && GAMENIGHT_INPUT_SYSTEM
using UnityEngine.InputSystem;
#endif

namespace OrbRush
{
    public sealed class OrbRushView : MonoBehaviour
    {
        OrbRushGame _game;
        Camera _camera;
        Renderer _floor;
        readonly List<GameObject> _orbs = new List<GameObject>();
        readonly Dictionary<Runner, Body> _bodies = new Dictionary<Runner, Body>();
        string _shot;
        int _shotFrame = -1;
        GUIStyle _big, _small, _menu;

        sealed class Body
        {
            public GameObject Root, Shape;
            public string ShapeName, Color;
            public SpriteRenderer Face;
            public Texture2D FaceTexture;
            public float Pop;
        }

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void Boot()
        {
            if (FindObjectOfType<OrbRushView>() == null) new GameObject("Orb Rush").AddComponent<OrbRushView>();
        }

        void Awake()
        {
            // The catalog id. Under GameNight, GAMENIGHT_GAME_ID decides.
            GameNight.Configure("unity-demo");
            var gn = GameNight.Client;
            var args = Environment.GetCommandLineArgs();
            for (var i = 0; i + 1 < args.Length; i++)
            {
                if (args[i] == "-shot") _shot = args[i + 1];
                if (args[i] == "-frames") _shotFrame = int.Parse(args[i + 1]);
            }
            var trace = Environment.GetEnvironmentVariable("GAME_TRACE") == "1";
            _game = new OrbRushGame(gn, ReadLocal, seed: _shot != null ? 7 : 0, trace: trace) { TraceOut = Debug.Log };
            // StreamingAssets/phone is every player's own screen: their score and a boost button.
            _game.PhoneScreenFolder = () => GameNight.DeclarePhoneScreen("phone");
            _game.OrbTaken += r => { if (_bodies.TryGetValue(r, out var b)) b.Pop = 1f; };
            if (!gn.LaunchedByHost)
            {
                // Started by hand: fullscreen at once. Under GameNight the SDK takes the screen on Start.
                if (_shot == null) Screen.fullScreenMode = FullScreenMode.FullScreenWindow;
                var humans = _shot != null ? 0 : Mathf.Max(1, LocalPadCount());
                _game.StartStandalone(humans, Mathf.Max(4, humans));
            }
            BuildScene();
        }

        // ---- the scene ----------------------------------------------------------------

        void BuildScene()
        {
            var cameraObject = new GameObject("Camera");
            _camera = cameraObject.AddComponent<Camera>();
            _camera.clearFlags = CameraClearFlags.SolidColor;
            _camera.backgroundColor = new Color32(0x14, 0x12, 0x1c, 255);
            _camera.fieldOfView = 40f;
            cameraObject.transform.position = new Vector3(0f, 30f, -24f);
            cameraObject.transform.LookAt(new Vector3(0f, 0f, -1.5f));
            cameraObject.AddComponent<AudioListener>();

            var light = new GameObject("Sun").AddComponent<Light>();
            light.type = LightType.Directional;
            light.intensity = 1.1f;
            light.shadows = LightShadows.Soft;
            light.transform.rotation = Quaternion.Euler(55f, -30f, 0f);
            RenderSettings.ambientLight = new Color(0.45f, 0.42f, 0.55f);

            var floor = GameObject.CreatePrimitive(PrimitiveType.Cube);
            floor.name = "Floor";
            floor.transform.localScale = new Vector3(OrbRushGame.ArenaW, 0.2f, OrbRushGame.ArenaH);
            floor.transform.position = new Vector3(0f, -0.1f, 0f);
            _floor = floor.GetComponent<Renderer>();
            _floor.material.color = new Color32(0x1f, 0x1c, 0x2b, 255);
            foreach (var (x, z, w, d) in new[]
                     {
                         (0f, OrbRushGame.ArenaH / 2 + 0.25f, OrbRushGame.ArenaW + 1f, 0.5f), (0f, -OrbRushGame.ArenaH / 2 - 0.25f, OrbRushGame.ArenaW + 1f, 0.5f),
                         (OrbRushGame.ArenaW / 2 + 0.25f, 0f, 0.5f, OrbRushGame.ArenaH), (-OrbRushGame.ArenaW / 2 - 0.25f, 0f, 0.5f, OrbRushGame.ArenaH),
                     })
            {
                var wall = GameObject.CreatePrimitive(PrimitiveType.Cube);
                wall.transform.localScale = new Vector3(w, 0.6f, d);
                wall.transform.position = new Vector3(x, 0.3f, z);
                wall.GetComponent<Renderer>().material.color = new Color32(0x3a, 0x35, 0x50, 255);
            }
        }

        static Vector3 World(float x, float y, float height) => new Vector3(x, height, -y);

        Body BodyFor(Runner r)
        {
            if (!_bodies.TryGetValue(r, out var body))
            {
                body = new Body { Root = new GameObject("Runner " + r.Name) };
                var face = new GameObject("Face");
                face.transform.SetParent(body.Root.transform, false);
                face.transform.localPosition = new Vector3(0f, 1.9f, 0f);
                body.Face = face.AddComponent<SpriteRenderer>();
                _bodies[r] = body;
            }
            if (body.ShapeName != r.Body)
            {
                // A per-player setting: each player picks their own shape on their phone.
                if (body.Shape != null) Destroy(body.Shape);
                var shape = r.Body == "cube" ? PrimitiveType.Cube : r.Body == "capsule" ? PrimitiveType.Capsule : PrimitiveType.Sphere;
                body.Shape = GameObject.CreatePrimitive(shape);
                Destroy(body.Shape.GetComponent<Collider>());
                body.Shape.transform.SetParent(body.Root.transform, false);
                body.ShapeName = r.Body;
                body.Color = null;
            }
            if (body.Color != r.Color)
            {
                body.Shape.GetComponent<Renderer>().material.color = GameNight.ParseColor(r.Color, Color.white);
                body.Color = r.Color;
            }
            // The player's own face, from their GameNight profile. Bots get the default face.
            var head = GameNightFaces.Head(r.Profile ?? new Player { Name = r.Name }, 64);
            if (body.FaceTexture != head)
            {
                body.FaceTexture = head;
                body.Face.sprite = Sprite.Create(head, new Rect(0, 0, head.width, head.height), new Vector2(0.5f, 0.5f), 40f);
            }
            return body;
        }

        // ---- every frame --------------------------------------------------------------

        void Update()
        {
            // GameNight pumps first (its execution order is earlier), so input and events are fresh here.
            _game.Tick(Mathf.Min(Time.unscaledDeltaTime, 0.05f));
            // Physics and animations freeze with the session; the GameNight pump keeps going at timeScale 0.
            Time.timeScale = _game.HostPaused ? 0f : 1f;
            Draw();
            if (_shot != null && Time.frameCount == _shotFrame)
            {
                ScreenCapture.CaptureScreenshot(_shot);
                Debug.Log("shot: " + _shot);
            }
            if (_shot != null && Time.frameCount > _shotFrame + 2) Application.Quit();
        }

        void Draw()
        {
            _floor.material.color = _game.GoldUnlocked ? new Color32(0x5a, 0x48, 0x1a, 255) : new Color32(0x1f, 0x1c, 0x2b, 255);
            while (_orbs.Count < _game.Orbs.Count)
            {
                var orb = GameObject.CreatePrimitive(PrimitiveType.Sphere);
                Destroy(orb.GetComponent<Collider>());
                orb.transform.localScale = Vector3.one * OrbRushGame.OrbRadius * 2f;
                orb.GetComponent<Renderer>().material.color = new Color32(0xff, 0xe5, 0x8a, 255);
                _orbs.Add(orb);
            }
            for (var i = 0; i < _orbs.Count; i++)
            {
                var visible = i < _game.Orbs.Count;
                _orbs[i].SetActive(visible);
                if (visible) _orbs[i].transform.position = World(_game.Orbs[i].x, _game.Orbs[i].y, 0.35f + 0.1f * Mathf.Sin(Time.unscaledTime * 3f + i));
            }
            var gone = new List<Runner>();
            foreach (var pair in _bodies) if (!_game.Runners.Contains(pair.Key)) gone.Add(pair.Key);
            foreach (var r in gone)
            {
                Destroy(_bodies[r].Root);
                _bodies.Remove(r);
            }
            foreach (var r in _game.Runners)
            {
                var body = BodyFor(r);
                body.Pop = Mathf.Max(0f, body.Pop - Time.unscaledDeltaTime * 4f);
                var scale = OrbRushGame.Radius * 2f * (1f + 0.25f * body.Pop + (r.Dash > 0f ? 0.15f : 0f));
                body.Shape.transform.localScale = Vector3.one * scale;
                body.Root.transform.position = World(r.X, r.Y, scale / 2f);
                // Faces look at the camera.
                body.Face.transform.rotation = _camera.transform.rotation;
            }
        }

        // ---- HUD: the clock, scores in couch order, results and the Start menu ----------

        void OnGUI()
        {
            var unit = Screen.height / 1080f;
            _big = _big ?? new GUIStyle(GUI.skin.label) { alignment = TextAnchor.MiddleCenter, fontStyle = FontStyle.Bold };
            _small = _small ?? new GUIStyle(GUI.skin.label) { alignment = TextAnchor.MiddleLeft, fontStyle = FontStyle.Bold };
            _menu = _menu ?? new GUIStyle(GUI.skin.label) { alignment = TextAnchor.MiddleCenter };
            _big.fontSize = Mathf.RoundToInt(56 * unit);
            _small.fontSize = Mathf.RoundToInt(34 * unit);
            _menu.fontSize = Mathf.RoundToInt(34 * unit);
            _big.normal.textColor = _small.normal.textColor = Color.white;

            GUI.Label(new Rect(0, 20 * unit, Screen.width, 70 * unit), Mathf.CeilToInt(Mathf.Max(_game.Clock, 0f)).ToString(), _big);

            // Left to right as the players sit on the couch, not by seat.
            var order = _game.CouchOrder();
            var x = 60 * unit;
            foreach (var r in order)
            {
                var head = GameNightFaces.Head(r.Profile ?? new Player { Name = r.Name }, 64);
                GUI.DrawTexture(new Rect(x, Screen.height - 110 * unit, 80 * unit, 80 * unit), head);
                _small.normal.textColor = GameNight.ParseColor(r.Color, Color.white);
                GUI.Label(new Rect(x + 86 * unit, Screen.height - 100 * unit, 90 * unit, 60 * unit), r.Score.ToString(), _small);
                x += 190 * unit;
            }
            _small.normal.textColor = Color.white;

            if (_game.Results > 0f)
            {
                var ranking = _game.Ranking();
                Box(new Rect(Screen.width / 2 - 320 * unit, 260 * unit, 640 * unit, (90 + ranking.Count * 70) * unit), Color.white);
                for (var i = 0; i < ranking.Count; i++)
                {
                    var r = ranking[i];
                    var y = (300 + i * 70) * unit;
                    GUI.DrawTexture(new Rect(Screen.width / 2 - 260 * unit, y, 60 * unit, 60 * unit), GameNightFaces.Head(r.Profile ?? new Player { Name = r.Name }, 64));
                    _small.normal.textColor = GameNight.ParseColor(r.Color, Color.white);
                    GUI.Label(new Rect(Screen.width / 2 - 180 * unit, y, 440 * unit, 60 * unit), $"{r.Name}   {r.Score}", _small);
                }
                _small.normal.textColor = Color.white;
            }

            if (_game.MenuOwner >= 0 && _game.MenuOwner < _game.Runners.Count)
            {
                // Title, Resume, New round, then the settings. No button hints.
                var rows = OrbRushGame.MenuItems.Length + OrbRushGame.MenuSettings;
                var box = new Rect(Screen.width / 2 - 320 * unit, 240 * unit, 640 * unit, (150 + rows * 66) * unit);
                Box(box, GameNight.ParseColor(_game.Runners[_game.MenuOwner].Color, Color.white));
                GUI.Label(new Rect(box.x, box.y + 20 * unit, box.width, 80 * unit), OrbRushGame.Title, _big);
                for (var i = 0; i < rows; i++)
                {
                    _menu.normal.textColor = i == _game.MenuRow ? Color.white : new Color(1f, 1f, 1f, 0.55f);
                    var text = i < OrbRushGame.MenuItems.Length
                        ? OrbRushGame.MenuItems[i]
                        : $"{OrbRushGame.Settings[i - OrbRushGame.MenuItems.Length].Label}   < {_game.MenuValue(i)} >";
                    GUI.Label(new Rect(box.x, box.y + (120 + i * 66) * unit, box.width, 60 * unit), text, _menu);
                }
            }
        }

        static void Box(Rect rect, Color edge)
        {
            var before = GUI.color;
            GUI.color = edge;
            GUI.DrawTexture(new Rect(rect.x - 4, rect.y - 4, rect.width + 8, rect.height + 8), Texture2D.whiteTexture);
            GUI.color = new Color(0.05f, 0.04f, 0.08f, 0.94f);
            GUI.DrawTexture(rect, Texture2D.whiteTexture);
            GUI.color = before;
        }

        // ---- standalone input: keyboard and local pads ------------------------------------

        static int LocalPadCount()
        {
#if ENABLE_INPUT_SYSTEM && GAMENIGHT_INPUT_SYSTEM
            return Gamepad.all.Count;
#elif ENABLE_LEGACY_INPUT_MANAGER
            var n = 0;
            foreach (var name in Input.GetJoystickNames()) if (!string.IsNullOrEmpty(name)) n++;
            return n;
#else
            return 0;
#endif
        }

        /// <summary>Only for a game started by hand. Under GameNight, input comes from the host per seat.</summary>
        static PadInput ReadLocal(Runner r)
        {
            var input = new PadInput();
#if ENABLE_INPUT_SYSTEM && GAMENIGHT_INPUT_SYSTEM
            if (r.LocalPad >= 0 && r.LocalPad < Gamepad.all.Count)
            {
                var pad = Gamepad.all[r.LocalPad];
                var stick = pad.leftStick.ReadValue();
                input.X = stick.x;
                input.Y = -stick.y;
                if (pad.buttonSouth.isPressed) input.Buttons |= 1 << Pad.A;
                if (pad.buttonEast.isPressed) input.Buttons |= 1 << Pad.B;
                if (pad.startButton.isPressed) input.Buttons |= 1 << Pad.Start;
            }
            var keys = Keyboard.current;
            if (r.LocalPad == 0 && keys != null)
            {
                input.X += (keys.dKey.isPressed ? 1f : 0f) - (keys.aKey.isPressed ? 1f : 0f);
                input.Y += (keys.sKey.isPressed ? 1f : 0f) - (keys.wKey.isPressed ? 1f : 0f);
                if (keys.spaceKey.isPressed) input.Buttons |= 1 << Pad.A;
                if (keys.escapeKey.isPressed) input.Buttons |= 1 << Pad.Start;
                if (keys.backspaceKey.isPressed) input.Buttons |= 1 << Pad.B;
            }
#elif ENABLE_LEGACY_INPUT_MANAGER
            if (r.LocalPad == 0)
            {
                input.X = Input.GetAxisRaw("Horizontal");
                input.Y = -Input.GetAxisRaw("Vertical");
                if (Input.GetKey(KeyCode.Space) || Input.GetKey(KeyCode.JoystickButton0)) input.Buttons |= 1 << Pad.A;
                if (Input.GetKey(KeyCode.Backspace) || Input.GetKey(KeyCode.JoystickButton1)) input.Buttons |= 1 << Pad.B;
                if (Input.GetKey(KeyCode.Escape) || Input.GetKey(KeyCode.JoystickButton7)) input.Buttons |= 1 << Pad.Start;
            }
#endif
            if (Mathf.Abs(input.X) < 0.2f && Mathf.Abs(input.Y) < 0.2f) input.X = input.Y = 0f;
            return input;
        }
    }
}
