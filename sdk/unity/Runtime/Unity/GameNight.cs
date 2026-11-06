using System;
using System.IO;
using UnityEngine;
#if ENABLE_INPUT_SYSTEM && GAMENIGHT_INPUT_SYSTEM
using UnityEngine.InputSystem;
#endif

namespace GameNightSdk
{
    /// <summary>
    /// GameNight for Unity. <see cref="Client"/> is the connection and session
    /// lifecycle; this component pumps it once per frame, before your scripts'
    /// Update, also while Time.timeScale is 0, and quits the player when GameNight
    /// goes away. It creates itself (with <see cref="GameNightScreen"/>) the first
    /// time you touch <see cref="Client"/>, and at startup when GameNight launched
    /// the game, so you never put it in a scene.
    ///
    ///     void Awake() {
    ///         var gn = GameNight.Client;
    ///         gn.Prepared += (session, seats, players) => { BuildLevel(seats); gn.NotifyReady(session); };
    ///         gn.Started += _ => enabled = true;
    ///     }
    /// </summary>
    [DefaultExecutionOrder(-10000)]
    [DisallowMultipleComponent]
    public sealed class GameNight : MonoBehaviour
    {
        static GameNightClient _client;
        static GameNight _runner;
        static string _gameId;
        static bool _connectStandalone;

        /// <summary>
        /// Set your catalog id (and optionally connect a hand-started game to a
        /// development host) before the first use of <see cref="Client"/>. Under
        /// GameNight, GAMENIGHT_GAME_ID wins. Defaults to the product name.
        /// </summary>
        public static void Configure(string gameId, bool connectStandalone = false)
        {
            if (_client != null)
            {
                Debug.LogWarning("GameNight: Configure() after GameNight.Client was created has no effect.");
                return;
            }
            _gameId = gameId;
            _connectStandalone = connectStandalone;
        }

        /// <summary>The GameNight connection. Subscribe to its events and call its methods from the main thread.</summary>
        public static GameNightClient Client
        {
            get
            {
                if (_client == null) Create();
                return _client;
            }
        }

        /// <summary>True when GameNight started this process: skip your menus and wait for Prepared.</summary>
        public static bool LaunchedByHost => Client.LaunchedByHost;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        static void Boot()
        {
            if (Environment.GetEnvironmentVariable(Protocol.ENV_GAMENIGHT) != "1") return;
            // A warming game must keep its connection and frames going while
            // another window has focus, or it never hears Start.
            Application.runInBackground = true;
            _ = Client;
        }

        static void Create()
        {
            var id = string.IsNullOrEmpty(_gameId) ? DefaultId() : _gameId;
            _client = new GameNightClient(id, _connectStandalone)
            {
                Log = Debug.LogWarning,
                WindowSize = () => (Screen.width, Screen.height),
                LocalRumble = LocalRumble,
            };
            _client.DeviceInfo["cpu"] = Cut(SystemInfo.processorType);
            _client.DeviceInfo["gpu"] = Cut(SystemInfo.graphicsDeviceName);
            _client.DeviceInfo["os"] = OsName();
            _client.DeviceInfo["memory_mib"] = SystemInfo.systemMemorySize;
            if (_client.LaunchedByHost) Application.runInBackground = true;
            if (_runner == null && Application.isPlaying)
            {
                var go = new GameObject("GameNight");
                DontDestroyOnLoad(go);
                _runner = go.AddComponent<GameNight>();
                go.AddComponent<GameNightScreen>();
            }
        }

        static string DefaultId()
        {
            var id = Application.productName.Trim().ToLowerInvariant().Replace(' ', '-');
            return string.IsNullOrEmpty(id) ? "unity-game" : id;
        }

        static string Cut(string text) => string.IsNullOrEmpty(text) ? "" : text.Length > 128 ? text.Substring(0, 128) : text;

        static string OsName()
        {
            switch (Application.platform)
            {
                case RuntimePlatform.WindowsPlayer:
                case RuntimePlatform.WindowsEditor: return "Windows";
                case RuntimePlatform.OSXPlayer:
                case RuntimePlatform.OSXEditor: return "macOS";
                case RuntimePlatform.LinuxPlayer:
                case RuntimePlatform.LinuxEditor: return "Linux";
                default: return Application.platform.ToString();
            }
        }

        void Awake()
        {
            if (_runner != null && _runner != this)
            {
                Destroy(gameObject);
                return;
            }
            _runner = this;
            DontDestroyOnLoad(gameObject);
        }

        void Update()
        {
            if (_client == null) return;
            _client.Pump();
            if (_client.ShouldQuit)
            {
                // Managed: the host is gone, so the night is over for this process.
                _client.Dispose();
                Application.Quit();
                return;
            }
            if (OverlayKeyPressed())
            {
                // The host already handles the pad's Back/Select. F1 is the keyboard way back.
                if (_client.LaunchedByHost) _client.RequestOverlay();
                else if (!string.IsNullOrEmpty(_client.OverlayUrl)) Application.OpenURL(_client.OverlayUrl);
            }
        }

        static bool OverlayKeyPressed()
        {
#if ENABLE_INPUT_SYSTEM && GAMENIGHT_INPUT_SYSTEM
            var keyboard = Keyboard.current;
            if (keyboard != null && (keyboard.f1Key.wasPressedThisFrame || keyboard.f12Key.wasPressedThisFrame)) return true;
#endif
#if ENABLE_LEGACY_INPUT_MANAGER
            if (Input.GetKeyDown(KeyCode.F1) || Input.GetKeyDown(KeyCode.F12)) return true;
#endif
            return false;
        }

        void OnApplicationQuit()
        {
            _client?.Dispose();
        }

        static void LocalRumble(int seat, float weak, float strong, float seconds)
        {
#if ENABLE_INPUT_SYSTEM && GAMENIGHT_INPUT_SYSTEM
            // Standalone: the seat's local pad. Unity has no timed rumble, so stop it later.
            if (seat < 0 || seat >= Gamepad.all.Count) return;
            var pad = Gamepad.all[seat];
            pad.SetMotorSpeeds(weak, strong);
            if (_runner != null) _runner.StartCoroutine(StopRumble(pad, seconds));
#endif
        }

#if ENABLE_INPUT_SYSTEM && GAMENIGHT_INPUT_SYSTEM
        static System.Collections.IEnumerator StopRumble(Gamepad pad, float seconds)
        {
            yield return new WaitForSecondsRealtime(seconds);
            pad.SetMotorSpeeds(0f, 0f);
        }
#endif

        // ---- Unity-flavoured helpers ----------------------------------------------------

        /// <summary>A stick with the SDK deadzone, as a Vector2 with UP POSITIVE (Unity's
        /// convention; the wire and <see cref="Pad.Stick"/> have up negative).</summary>
        public static Vector2 Stick(ControllerFrame frame, int side = 0, float deadzone = Pad.StickDeadzone)
        {
            var (x, y) = Pad.Stick(frame, side, deadzone);
            return new Vector2(x, -y);
        }

        /// <summary>A seat's stick this frame, up positive. Zero while paused or when the input is stale.</summary>
        public static Vector2 Stick(int seat, int side = 0) => Stick(Client.FrameForSeat(seat), side);

        public static float Trigger(int seat, int side = 0) => Pad.Trigger(Client.FrameForSeat(seat), side);
        public static bool Held(int seat, int button) => Pad.Button(Client.FrameForSeat(seat), button);
        public static bool JustPressed(int seat, int button) => Client.JustPressed(seat, button);

        /// <summary>"#rrggbb" to a Color, or <paramref name="fallback"/>.</summary>
        public static Color ParseColor(string hex, Color fallback)
        {
            return Avatar.TryHex(hex, out var r, out var g, out var b) ? new Color32(r, g, b, 255) : fallback;
        }

        /// <summary>
        /// Declare a folder under StreamingAssets as the phone screen every player
        /// gets. StreamingAssets is a real folder in desktop builds, which is what
        /// the host serves pages from. Call it from Client.Connected.
        /// </summary>
        public static bool DeclarePhoneScreen(string folder = "phone", string entry = "index.html") =>
            Client.DeclareCompanionFolder(Path.Combine(Application.streamingAssetsPath, folder), entry);
    }
}
