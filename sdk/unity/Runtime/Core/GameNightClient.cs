using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

namespace GameNightSdk
{
    /// <summary>
    /// The GameNight connection and session lifecycle, in plain C#. In Unity you
    /// use it through <c>GameNight.Client</c>, which pumps it every frame; a
    /// dotnet test can drive it directly. The integration contract:
    ///
    /// 1. Subscribe to <see cref="Prepared"/>: build the level for the given seats,
    ///    show nothing, then call <see cref="NotifyReady"/>.
    /// 2. <see cref="Started"/>: you are live, start at once.
    /// 3. <see cref="Paused"/> and <see cref="Resumed"/>: freeze and continue the same match.
    /// 4. <see cref="Disposed"/>: tear the session down. A new Prepared may follow.
    ///
    /// Every event fires on the thread that calls <see cref="Pump"/>, never on a
    /// socket thread. Call every method from that thread too.
    /// </summary>
    public sealed class GameNightClient : IDisposable
    {
        // ---- session lifecycle ------------------------------------------------

        /// <summary>Warm up: load everything for these seats, then call NotifyReady. Show nothing yet.</summary>
        public event Action<string, IReadOnlyList<Seat>, IReadOnlyList<Player>> Prepared;
        /// <summary>The transition landed on you. Start the match now.</summary>
        public event Action<string> Started;
        /// <summary>Freeze gameplay, timers and sound. The lobby has the screen.</summary>
        public event Action<string> Paused;
        /// <summary>Continue the same match.</summary>
        public event Action<string> Resumed;
        /// <summary>Tear the session down; its id is never used again.</summary>
        public event Action<string> Disposed;
        /// <summary>Ready went out: loading is over (the screen helper throttles now).</summary>
        public event Action<string> ReadySent;

        // ---- connection and party -----------------------------------------------

        public event Action Connected;
        /// <summary>The host went away. Under GameNight this is followed by <see cref="ShouldQuit"/>.</summary>
        public event Action Disconnected;
        /// <summary>Fresh raw party snapshot (players, seats, playlist, settings...).</summary>
        public event Action<Dictionary<string, object>> PartyUpdated;
        /// <summary>Someone joined, left or moved seat during your session (after <see cref="NotifyParticipation"/>).</summary>
        public event Action<IReadOnlyList<Seat>, IReadOnlyList<Player>> RosterChanged;
        /// <summary>The same players changed name, colour, face or profile. Update in place; never restart over it.</summary>
        public event Action<IReadOnlyList<Player>> PlayersUpdated;

        // ---- settings, saves, phones ---------------------------------------------

        /// <summary>The party changed a declared setting. Value is bool, long or string.</summary>
        public event Action<string, object> SettingChanged;
        /// <summary>One player's own values of your per-player settings, defaults merged in.</summary>
        public event Action<string, Dictionary<string, object>> PlayerSettingsChanged;
        /// <summary>One player's saved progress, as you last stored it.</summary>
        public event Action<string, object> PlayerDataChanged;
        /// <summary>A player pressed one of your phone buttons (key, player id).</summary>
        public event Action<string, string> ActionTriggered;
        /// <summary>A player's phone page sent JSON. Treat it as untrusted input.</summary>
        public event Action<string, object> CompanionMessage;
        /// <summary>A player's phone page opened (true) or closed. Send them their view on open.</summary>
        public event Action<string, bool> CompanionPresence;
        /// <summary>A plain-text request ("10 orbs please"). Answer once with AnswerCommand.</summary>
        public event Action<GameCommand> CommandReceived;
        /// <summary>An error the host reported. Informational; the connection stays.</summary>
        public event Action<string> HostError;

        // ---- state ---------------------------------------------------------------

        /// <summary>True when GameNight started this process (GAMENIGHT=1): skip menus, wait for Prepared.</summary>
        public bool LaunchedByHost { get; private set; }
        /// <summary>Must match the catalog id. GAMENIGHT_GAME_ID overrides it under GameNight.</summary>
        public string GameId { get; private set; }
        public string HostUrl { get; set; }
        /// <summary>The current session, empty between sessions.</summary>
        public string Session { get; private set; } = "";
        /// <summary>"idle", "preparing", "ready", "running" or "paused".</summary>
        public string Phase { get; private set; } = "idle";
        public bool IsRunning => Phase == "running";
        public bool IsConnected => _transport != null && _transport.IsOpen && _saidHello;
        /// <summary>The raw party snapshot.</summary>
        public Dictionary<string, object> Party { get; private set; } = new Dictionary<string, object>();
        public IReadOnlyList<Seat> Seats => _seats;
        public IReadOnlyList<Player> Players => _players;
        /// <summary>Under GameNight, losing the host means the night is over for this process: quit.</summary>
        public bool ShouldQuit { get; private set; }
        /// <summary>Reconnect while the host is away (standalone development connections).</summary>
        public bool AutoReconnect = true;
        /// <summary>Where warnings go. Unity sets Debug.LogWarning.</summary>
        public Action<string> Log = message => Console.Error.WriteLine(message);
        /// <summary>Machine facts for performance reports: cpu, gpu, os, memory_mib.</summary>
        public Dictionary<string, object> DeviceInfo = new Dictionary<string, object>();
        /// <summary>The window size for performance reports.</summary>
        public Func<(int width, int height)> WindowSize = () => (0, 0);
        /// <summary>Drives a local pad when no host owns the pads (standalone). Seat, weak, strong, seconds.</summary>
        public Action<int, float, float, float> LocalRumble;

        const double ReconnectSeconds = 2.0;
        const long StaleInputMs = 250;
        const int AllButtons = (1 << Pad.ButtonCount) - 1;

        readonly string _token;
        readonly Stopwatch _clock = Stopwatch.StartNew();
        Transport _transport;
        bool _saidHello;
        double _reconnectAt;
        List<Seat> _seats = new List<Seat>();
        List<Player> _players = new List<Player>();
        readonly Dictionary<string, ControllerFrame> _frames = new Dictionary<string, ControllerFrame>();
        long _frameAt = -100000;
        readonly Dictionary<int, int> _buttonsNow = new Dictionary<int, int>();
        readonly Dictionary<int, int> _buttonsBefore = new Dictionary<int, int>();
        readonly Dictionary<string, long> _activityAt = new Dictionary<string, long>();
        readonly Dictionary<int, bool> _rumbleQuiet = new Dictionary<int, bool>();
        readonly Dictionary<string, object> _settings = new Dictionary<string, object>();
        readonly Dictionary<string, Dictionary<string, object>> _playerSettings = new Dictionary<string, Dictionary<string, object>>();
        readonly Dictionary<string, object> _playerData = new Dictionary<string, object>();
        readonly Dictionary<string, long> _playerDataRevision = new Dictionary<string, long>();
        List<object> _declaredSettings;
        List<object> _declaredActions;
        Dictionary<string, object> _declaredCompanion;
        Dictionary<string, object> _declaredCommands;

        /// <param name="gameId">Your catalog id; GAMENIGHT_GAME_ID wins when GameNight launched you.</param>
        /// <param name="connectStandalone">Connect a hand-started game to a development host anyway.</param>
        /// <param name="environment">Defaults to the process environment; tests pass their own.</param>
        public GameNightClient(string gameId, bool connectStandalone = false, Func<string, string> environment = null)
        {
            environment = environment ?? Environment.GetEnvironmentVariable;
            LaunchedByHost = environment(Protocol.ENV_GAMENIGHT) == "1";
            var envGame = environment(Protocol.ENV_GAME_ID);
            GameId = string.IsNullOrEmpty(envGame) ? gameId : envGame;
            var envAddr = environment(Protocol.ENV_ADDR);
            HostUrl = "ws://" + (string.IsNullOrEmpty(envAddr) ? Protocol.DEFAULT_ADDR : envAddr);
            _token = environment(Protocol.ENV_TOKEN) ?? "";
            OverlayUrl = environment(Protocol.ENV_OVERLAY_URL) ?? "";
            // A game started by hand stays offline, so a test run never joins the
            // party on this machine, unless GAMENIGHT_ADDR or the flag says so.
            if (!LaunchedByHost && string.IsNullOrEmpty(envAddr) && !connectStandalone)
            {
                AutoReconnect = false;
                return;
            }
            Open();
        }

        /// <summary>The party overlay's URL, for Back in a hand-started game (GAMENIGHT_OVERLAY_URL).</summary>
        public string OverlayUrl { get; set; }

        /// <summary>Connect a hand-started game to the host at <see cref="HostUrl"/> after all.</summary>
        public void ConnectToHost()
        {
            AutoReconnect = true;
            if (_transport == null) Open();
        }

        void Open()
        {
            _transport?.Dispose();
            _transport = new Transport(HostUrl);
            _saidHello = false;
        }

        double Now => _clock.Elapsed.TotalSeconds;
        long NowMs => _clock.ElapsedMilliseconds;

        // ---- the pump ---------------------------------------------------------------

        /// <summary>
        /// Handle everything the host sent and update input edges. Call once per
        /// frame, also while your game is paused (Unity's Update keeps running at
        /// Time.timeScale 0; GameNight.cs does this for you).
        /// </summary>
        public void Pump()
        {
            if (_transport == null)
            {
                if (AutoReconnect && !ShouldQuit && Now >= _reconnectAt) Open();
                UpdateButtons();
                return;
            }
            if (_transport.IsOpen)
            {
                SamplePerformance();
                if (!_saidHello)
                {
                    _saidHello = true;
                    var hello = new Dictionary<string, object> { ["type"] = Protocol.Msg.Hello, ["role"] = Protocol.Role.Game, ["game"] = GameId };
                    if (!string.IsNullOrEmpty(_token)) hello["token"] = _token;
                    Send(hello);
                }
            }
            while (_transport.Inbox.TryDequeue(out var text))
            {
                if (Json.TryParse(text) is Dictionary<string, object> msg) Handle(msg);
            }
            if (_transport.IsClosed)
            {
                if (!_saidHello && _transport.Failure != null && !LaunchedByHost)
                    Log($"GameNight: cannot reach the host at {HostUrl} ({_transport.Failure})");
                _frames.Clear();
                _performanceRunning = false;
                var wasConnected = _saidHello;
                _transport.Dispose();
                _transport = null;
                if (wasConnected) Disconnected?.Invoke();
                LostHost();
            }
            UpdateButtons();
        }

        void LostHost()
        {
            if (LaunchedByHost)
            {
                // Managed: the night is over for this process. Clear input and quit.
                _frames.Clear();
                Phase = "idle";
                AutoReconnect = false;
                ShouldQuit = true;
                return;
            }
            _reconnectAt = Now + ReconnectSeconds;
        }

        void Send(Dictionary<string, object> msg)
        {
            if (_transport != null && _transport.IsOpen) _transport.Send(Json.Write(msg));
        }

        Dictionary<string, object> Msg(string type) => new Dictionary<string, object> { ["type"] = type };

        // ---- reports ----------------------------------------------------------------

        /// <summary>Assets loaded and the first frame can be drawn: the session can start instantly.</summary>
        public void NotifyReady(string sessionId)
        {
            if (sessionId != Session || Phase != "preparing") return;
            Phase = "ready";
            var msg = Msg(Protocol.Msg.Ready);
            msg["session"] = sessionId;
            Send(msg);
            ReadySent?.Invoke(sessionId);
        }

        /// <summary>A round ended. Keep your own results screen and next round; nothing else changes.</summary>
        public void NotifyFinished(string sessionId)
        {
            var msg = Msg(Protocol.Msg.Finished);
            msg["session"] = sessionId;
            Send(msg);
        }

        /// <summary>How far warming is, 0 to 100, so the lobby can show a real bar. Skip it if you load instantly.</summary>
        public void NotifyProgress(string sessionId, int percent, string label = "")
        {
            var msg = Msg(Protocol.Msg.Progress);
            msg["session"] = sessionId;
            msg["percent"] = Math.Max(0, Math.Min(100, percent));
            if (!string.IsNullOrEmpty(label)) msg["label"] = label;
            Send(msg);
        }

        /// <summary>
        /// Opt into live roster updates (<see cref="RosterChanged"/>). Call it from
        /// Prepared, before NotifyReady. <paramref name="instantJoin"/> true only when a
        /// running match can take a new player at once; false makes newcomers wait for your next round.
        /// </summary>
        public void NotifyParticipation(string sessionId, bool instantJoin)
        {
            var msg = Msg(Protocol.Msg.Participation);
            msg["session"] = sessionId;
            msg["instant_join"] = instantJoin;
            Send(msg);
        }

        /// <summary>One short line for the room log players read back in the app ("Ann won round 3").
        /// Never per frame: the host keeps one line per two seconds, cut at 120 characters.</summary>
        public void AddRoomLog(string text)
        {
            if (string.IsNullOrEmpty(Session) || Phase != "running") return;
            var msg = Msg(Protocol.Msg.RoomLog);
            msg["session"] = Session;
            msg["text"] = text;
            Send(msg);
        }

        /// <summary>
        /// Vibrate the pad on this seat. <paramref name="weak"/> is the light motor,
        /// <paramref name="strong"/> the heavy one, both 0 to 1, for up to 5 seconds. Each
        /// call replaces the last; call it a few times a second while an effect lasts
        /// and with zeros to stop. Only works while your session runs in front.
        /// </summary>
        public void Rumble(int seat, float weak, float strong, float seconds)
        {
            weak = Math.Max(0f, Math.Min(1f, weak));
            strong = Math.Max(0f, Math.Min(1f, strong));
            var quiet = weak == 0f && strong == 0f;
            if (!LaunchedByHost)
            {
                LocalRumble?.Invoke(seat, weak, strong, seconds);
                return;
            }
            if (string.IsNullOrEmpty(Session) || Phase != "running") return;
            // One stop is enough; repeated zeros would only flood the socket.
            if (quiet && (!_rumbleQuiet.TryGetValue(seat, out var was) || was)) return;
            _rumbleQuiet[seat] = quiet;
            var msg = Msg(Protocol.Msg.Rumble);
            msg["session"] = Session;
            msg["seat"] = seat;
            msg["weak"] = (int)(weak * 65535f);
            msg["strong"] = (int)(strong * 65535f);
            msg["ms"] = Math.Max(0, Math.Min(5000, (int)(seconds * 1000f)));
            Send(msg);
        }

        /// <summary>A person is really playing on this seat (a press, a stick past its
        /// deadzone), so the party does not mark them asleep. At most once a second per pad.</summary>
        public void ReportActivity(int seat)
        {
            if (string.IsNullOrEmpty(Session)) return;
            var token = ControllerForSeat(seat);
            if (string.IsNullOrEmpty(token)) return;
            var now = NowMs;
            if (_activityAt.TryGetValue(token, out var at) && now - at < 1000) return;
            _activityAt[token] = now;
            var msg = Msg(Protocol.Msg.ControllerInput);
            msg["session"] = Session;
            msg["controller"] = token;
            Send(msg);
        }

        /// <summary>"Get me back to the party." The host pauses you and shows the lobby.
        /// The host already handles the pad's Back button; use this for a keyboard key or menu item.</summary>
        public void RequestOverlay() => Send(Msg(Protocol.Msg.RequestOverlay));

        /// <summary>An explicit player request to start or resume this game. Never send it on window focus.</summary>
        public void RequestStart() => Send(Msg(Protocol.Msg.RequestStart));

        // ---- settings -------------------------------------------------------------------

        /// <summary>
        /// The settings the party may change from their phones or the assistant.
        /// Call once; it is re-declared after every reconnect, and the host then
        /// replays every value the party moved off its default via SettingChanged.
        /// </summary>
        public void DeclareSettings(IEnumerable<Setting> settings)
        {
            _declaredSettings = new List<object>();
            foreach (var setting in settings) _declaredSettings.Add(setting.ToJson());
            var msg = Msg(Protocol.Msg.DeclareSettings);
            msg["settings"] = _declaredSettings;
            Send(msg);
        }

        /// <summary>Change one of your settings, from your own Start menu, so the phones show the same value.
        /// The host validates it and answers with SettingChanged.</summary>
        public void SetSetting(string key, object value)
        {
            var msg = Msg(Protocol.Msg.SetSetting);
            msg["key"] = key;
            msg["value"] = value;
            Send(msg);
        }

        /// <summary>The last value the host sent for a setting, or <paramref name="fallback"/>.</summary>
        public object SettingValue(string key, object fallback = null) =>
            _settings.TryGetValue(key, out var value) ? value : fallback;

        /// <summary>Change one player's own value of a per-player setting (your character select).</summary>
        public void SetPlayerSetting(string playerId, string key, object value)
        {
            var msg = Msg(Protocol.Msg.SetPlayerSetting);
            msg["player_id"] = playerId;
            msg["key"] = key;
            msg["value"] = value;
            Send(msg);
        }

        public object PlayerSetting(string playerId, string key, object fallback = null) =>
            _playerSettings.TryGetValue(playerId ?? "", out var values) && values.TryGetValue(key, out var value) ? value : fallback;

        // ---- saved progress ---------------------------------------------------------------

        /// <summary>A player's saved progress (unlocks, stats), or <paramref name="fallback"/>.</summary>
        public object PlayerData(string playerId, object fallback = null) =>
            _playerData.TryGetValue(playerId ?? "", out var data) && data != null ? data : fallback;

        /// <summary>
        /// Save one player's progress: any JSON value up to 64 KB, replacing what was
        /// there. Answered with PlayerDataChanged. A save against an older copy than
        /// the host has is refused, so two hosts never overwrite each other.
        /// </summary>
        public void SavePlayerData(string playerId, object data)
        {
            _playerData[playerId] = data;
            var msg = Msg(Protocol.Msg.SavePlayerData);
            msg["player_id"] = playerId;
            msg["data"] = data;
            msg["expected_revision"] = _playerDataRevision.TryGetValue(playerId, out var revision) ? revision : 0;
            Send(msg);
        }

        /// <summary>Everything in list <paramref name="key"/> of the saved progress of the players here
        /// now, for this session only: one player's unlock is everyone's tonight.</summary>
        public List<object> PartyUnion(string key = "unlocks")
        {
            var union = new List<object>();
            foreach (var id in PartyPlayerIds())
            {
                if (!(PlayerData(id) is Dictionary<string, object> data)) continue;
                foreach (var item in Json.List(Json.Get(data, key)))
                    if (!union.Exists(x => Equals(x, item))) union.Add(item);
            }
            return union;
        }

        /// <summary>Add <paramref name="item"/> to list <paramref name="key"/> of every player here now.</summary>
        public void UnlockForPresent(object item, string key = "unlocks")
        {
            foreach (var id in PartyPlayerIds())
            {
                var data = PlayerData(id) as Dictionary<string, object> ?? new Dictionary<string, object>();
                var list = Json.Get(data, key) as List<object> ?? new List<object>();
                if (list.Exists(x => Equals(x, item))) continue;
                list.Add(item);
                data[key] = list;
                SavePlayerData(id, data);
            }
        }

        IEnumerable<string> PartyPlayerIds()
        {
            foreach (var player in Json.List(Json.Get(Party, "players")))
            {
                var id = Json.Str(Json.Obj(player), "id");
                if (!string.IsNullOrEmpty(id)) yield return id;
            }
        }

        // ---- phone buttons and plain-text requests -------------------------------------------

        /// <summary>Buttons on the players' phones, like "New round". At most 12. Presses arrive via
        /// ActionTriggered while your session is the one being played. An empty list removes them.</summary>
        public void DeclareActions(IEnumerable<PhoneAction> actions)
        {
            _declaredActions = new List<object>();
            foreach (var action in actions) _declaredActions.Add(action.ToJson());
            var msg = Msg(Protocol.Msg.DeclareActions);
            msg["actions"] = _declaredActions;
            Send(msg);
        }

        /// <summary>Accept plain-text requests from the app and the session assistant.
        /// They arrive via CommandReceived; you decide what the words mean.</summary>
        public void DeclareCommands(string description, params string[] examples)
        {
            _declaredCommands = Msg(Protocol.Msg.DeclareCommands);
            _declaredCommands["description"] = description;
            _declaredCommands["examples"] = new List<object>(examples);
            Send(_declaredCommands);
        }

        /// <summary>Answer a request once, in words for that player.</summary>
        public void AnswerCommand(string id, bool ok, string message)
        {
            var msg = Msg(Protocol.Msg.CommandResult);
            msg["id"] = id;
            msg["ok"] = ok;
            msg["message"] = message;
            Send(msg);
        }

        // ---- phone screens -------------------------------------------------------------------------

        /// <summary>
        /// A screen of their own on every player's phone. <paramref name="root"/> is an
        /// absolute directory (in Unity: under StreamingAssets, see GameNight.DeclarePhoneScreen).
        /// Re-declared after every reconnect.
        /// </summary>
        public void DeclareCompanion(string root, string entry = "index.html", string appName = null, string android = null, string download = null)
        {
            var msg = Msg(Protocol.Msg.DeclareCompanion);
            if (!string.IsNullOrEmpty(root)) msg["root"] = root;
            if (!string.IsNullOrEmpty(entry)) msg["entry"] = entry;
            if (!string.IsNullOrEmpty(appName))
            {
                var app = new Dictionary<string, object> { ["name"] = appName };
                if (!string.IsNullOrEmpty(android)) app["android"] = android;
                if (!string.IsNullOrEmpty(download)) app["download"] = download;
                msg["app"] = app;
            }
            _declaredCompanion = msg;
            Send(msg);
        }

        static readonly HashSet<string> CompanionTypes = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            { ".html", ".htm", ".js", ".mjs", ".css", ".json", ".svg", ".png", ".jpg", ".jpeg", ".webp", ".woff2", ".apk" };

        /// <summary>Declare a folder as the phone screen, after checking it fits a hosted room
        /// (128 files, 2 MiB, 512 KiB a file, web types only). Returns false when it is missing.</summary>
        public bool DeclareCompanionFolder(string folder, string entry = "index.html")
        {
            if (!Directory.Exists(folder) || !File.Exists(Path.Combine(folder, entry)))
            {
                Log($"GameNight: no phone screen at {Path.Combine(folder, entry)}");
                return false;
            }
            long total = 0;
            var count = 0;
            foreach (var path in Directory.GetFiles(folder, "*", SearchOption.AllDirectories))
            {
                if (path.EndsWith(".meta", StringComparison.OrdinalIgnoreCase)) continue; // Unity's own files
                count++;
                var encoded = (new FileInfo(path).Length + 2) / 3 * 4;
                total += encoded;
                var name = path.Substring(folder.Length).TrimStart('/', '\\');
                if (encoded > 512 * 1024) Log($"GameNight: phone file {name} is {encoded >> 10} KiB in a hosted room; the limit is 512 KiB");
                if (!CompanionTypes.Contains(Path.GetExtension(path)))
                    Log($"GameNight: hosted rooms do not serve phone file {name} (use HTML, JS, CSS, JSON, SVG, PNG, JPEG, WebP or WOFF2)");
            }
            if (count > 128 || total > 2 * 1024 * 1024)
                Log($"GameNight: the phone screen is {count} files, {total >> 10} KiB in a hosted room; the limit is 128 files, 2048 KiB");
            DeclareCompanion(Path.GetFullPath(folder), entry);
            return true;
        }

        /// <summary>Send JSON to one player's phone page, or every phone when <paramref name="playerId"/> is empty.</summary>
        public void SendCompanionMessage(object data, string playerId = "")
        {
            var msg = Msg(Protocol.Msg.CompanionMessage);
            msg["data"] = data;
            if (!string.IsNullOrEmpty(playerId)) msg["player_id"] = playerId;
            Send(msg);
        }

        // ---- seats and input ----------------------------------------------------------------------

        /// <summary>How many seats hold a person on this machine: your player count, not the pads you see.</summary>
        public static int LocalSeatCount(IEnumerable<Seat> seats)
        {
            var n = 0;
            foreach (var seat in seats) if (seat.IsLocal) n++;
            return n;
        }

        /// <summary>How many seats the party wants a bot in.</summary>
        public static int AiSeatCount(IEnumerable<Seat> seats)
        {
            var n = 0;
            foreach (var seat in seats) if (seat.IsBot) n++;
            return n;
        }

        /// <summary>The player sitting in a seat, or null.</summary>
        public Player PlayerForSeat(Seat seat)
        {
            if (seat == null || string.IsNullOrEmpty(seat.PlayerId)) return null;
            foreach (var player in _players) if (player.Id == seat.PlayerId) return player;
            return null;
        }

        /// <summary>
        /// The host's input for a seat. Empty (neutral) when the seat has no pad,
        /// the input is more than 250 ms old, or the session is not running; pass
        /// <paramref name="anyPhase"/> to read it anyway, for your own Start menu.
        /// </summary>
        public ControllerFrame FrameForSeat(int seat, bool anyPhase = false)
        {
            if ((Phase != "running" && !anyPhase) || NowMs - _frameAt >= StaleInputMs) return Neutral;
            var token = ControllerForSeat(seat);
            return !string.IsNullOrEmpty(token) && _frames.TryGetValue(token, out var frame) ? frame : Neutral;
        }

        static readonly ControllerFrame Neutral = new ControllerFrame { Controller = "", Axes = new int[6] };

        /// <summary>True in the one frame a seat's button went down. After Start and Resume a button
        /// still held from the lobby must be released first, so one press never does two things.</summary>
        public bool JustPressed(int seat, int button)
        {
            var bit = 1 << button;
            _buttonsNow.TryGetValue(seat, out var now);
            _buttonsBefore.TryGetValue(seat, out var before);
            return (now & bit) != 0 && (before & bit) == 0;
        }

        string ControllerForSeat(int index)
        {
            foreach (var seat in _seats) if (seat.Index == index) return seat.Controller;
            return "";
        }

        void UpdateButtons()
        {
            _buttonsBefore.Clear();
            foreach (var pair in _buttonsNow) _buttonsBefore[pair.Key] = pair.Value;
            _buttonsNow.Clear();
            foreach (var seat in _seats) _buttonsNow[seat.Index] = FrameForSeat(seat.Index, true).Buttons;
        }

        void HoldButtons()
        {
            foreach (var seat in _seats) _buttonsNow[seat.Index] = AllButtons;
        }

        // ---- performance ---------------------------------------------------------------------------

        string _performanceSession = "";
        bool _performanceRunning;
        double _performanceLast;
        long _frames_, _elapsedUs, _slowFrames, _maxFrameUs, _sentUs;

        void ResetPerformance(string sessionId)
        {
            _performanceSession = sessionId;
            _performanceRunning = false;
            _performanceLast = 0;
            _frames_ = _elapsedUs = _slowFrames = _maxFrameUs = _sentUs = 0;
        }

        void SamplePerformance()
        {
            var now = Now;
            if (!_performanceRunning || string.IsNullOrEmpty(_performanceSession))
            {
                _performanceLast = 0;
                return;
            }
            var elapsedUs = _performanceLast > 0 ? (long)((now - _performanceLast) * 1e6) : 0;
            _performanceLast = now;
            // Skip OS suspension; report real frame intervals, not scaled game time.
            if (elapsedUs <= 0 || elapsedUs > 2000000) return;
            _frames_++;
            _elapsedUs += elapsedUs;
            if (elapsedUs > 33333) _slowFrames++;
            _maxFrameUs = Math.Max(_maxFrameUs, elapsedUs);
            if (_elapsedUs - _sentUs < 10000000) return;
            var sample = new Dictionary<string, object>(DeviceInfo)
            {
                ["frames"] = _frames_, ["elapsed_us"] = _elapsedUs, ["slow_frames"] = _slowFrames, ["max_frame_us"] = _maxFrameUs,
            };
            var size = WindowSize();
            sample["width"] = size.width;
            sample["height"] = size.height;
            var msg = Msg(Protocol.Msg.Performance);
            msg["session"] = _performanceSession;
            msg["sample"] = sample;
            Send(msg);
            _sentUs = _elapsedUs;
        }

        // ---- incoming --------------------------------------------------------------------------------

        void Handle(Dictionary<string, object> msg)
        {
            var kind = Json.Str(msg, "type");
            var sessionScoped = kind == Protocol.Msg.Start || kind == Protocol.Msg.Pause || kind == Protocol.Msg.Resume
                || kind == Protocol.Msg.Dispose || kind == Protocol.Msg.PartyUpdated || kind == Protocol.Msg.PlayersUpdated;
            if (sessionScoped && (string.IsNullOrEmpty(Session) || Json.Str(msg, "session") != Session)) return;
            switch (kind)
            {
                case Protocol.Msg.Welcome:
                    Party = Json.Obj(Json.Get(msg, "party")) ?? new Dictionary<string, object>();
                    Connected?.Invoke();
                    PartyUpdated?.Invoke(Party);
                    // A reconnect: re-declare, so the host replays values the party changed meanwhile.
                    if (_declaredSettings != null)
                    {
                        var settings = Msg(Protocol.Msg.DeclareSettings);
                        settings["settings"] = _declaredSettings;
                        Send(settings);
                    }
                    if (_declaredActions != null)
                    {
                        var actions = Msg(Protocol.Msg.DeclareActions);
                        actions["actions"] = _declaredActions;
                        Send(actions);
                    }
                    if (_declaredCompanion != null) Send(_declaredCompanion);
                    if (_declaredCommands != null) Send(_declaredCommands);
                    break;
                case Protocol.Msg.PartyState:
                    Party = Json.Obj(Json.Get(msg, "party")) ?? new Dictionary<string, object>();
                    PartyUpdated?.Invoke(Party);
                    break;
                case Protocol.Msg.ControllerFrame:
                    _frames.Clear();
                    _frameAt = NowMs;
                    foreach (var item in Json.List(Json.Get(msg, "controllers")))
                    {
                        var frame = ControllerFrame.From(item);
                        if (!frame.IsEmpty && !_frames.ContainsKey(frame.Controller)) _frames[frame.Controller] = frame;
                    }
                    break;
                case Protocol.Msg.PartyUpdated:
                    foreach (var key in new[] { "seats", "players", "presence" }) Party[key] = Json.List(Json.Get(msg, key));
                    _seats = Seat.ListFrom(Party["seats"]);
                    _players = Player.ListFrom(Party["players"]);
                    RosterChanged?.Invoke(_seats, _players);
                    PartyUpdated?.Invoke(Party);
                    break;
                case Protocol.Msg.PlayersUpdated:
                {
                    var updated = Player.ListFrom(Json.Get(msg, "players"));
                    var raw = Json.List(Json.Get(Party, "players"));
                    foreach (var player in updated)
                    {
                        var known = _players.FindIndex(p => p.Id == player.Id);
                        if (known >= 0) _players[known] = player;
                        else _players.Add(player);
                        var rawIndex = raw.FindIndex(p => Json.Str(Json.Obj(p), "id") == player.Id);
                        if (rawIndex >= 0) raw[rawIndex] = player.Raw;
                        else raw.Add(player.Raw);
                    }
                    Party["players"] = raw;
                    PlayersUpdated?.Invoke(updated);
                    PartyUpdated?.Invoke(Party);
                    break;
                }
                case Protocol.Msg.Prepare:
                {
                    var session = Json.Str(msg, "session");
                    if (Json.Str(msg, "game", GameId) != GameId || string.IsNullOrEmpty(session) || session == Session) return;
                    if (!string.IsNullOrEmpty(Session)) Disposed?.Invoke(Session);
                    Session = session;
                    Phase = "preparing";
                    _frames.Clear();
                    Party["seats"] = Json.List(Json.Get(msg, "seats"));
                    Party["players"] = Json.List(Json.Get(msg, "players"));
                    _seats = Seat.ListFrom(Party["seats"]);
                    _players = Player.ListFrom(Party["players"]);
                    ResetPerformance(session);
                    Prepared?.Invoke(session, _seats, _players);
                    break;
                }
                case Protocol.Msg.Start:
                    if (Phase != "ready") return;
                    Phase = "running";
                    _performanceRunning = Session == _performanceSession;
                    HoldButtons();
                    Started?.Invoke(Session);
                    break;
                case Protocol.Msg.Pause:
                    if (Phase != "running") return;
                    Phase = "paused";
                    _performanceRunning = false;
                    _performanceLast = 0;
                    Paused?.Invoke(Session);
                    break;
                case Protocol.Msg.Resume:
                    if (Phase != "paused") return;
                    Phase = "running";
                    _performanceRunning = Session == _performanceSession;
                    HoldButtons();
                    Resumed?.Invoke(Session);
                    break;
                case Protocol.Msg.Dispose:
                {
                    var ended = Session;
                    _performanceRunning = false;
                    Session = "";
                    Phase = "idle";
                    _frames.Clear();
                    Disposed?.Invoke(ended);
                    break;
                }
                case Protocol.Msg.SettingChanged:
                {
                    var key = Json.Str(msg, "key");
                    var value = Normalize(Json.Get(msg, "value"));
                    _settings[key] = value;
                    SettingChanged?.Invoke(key, value);
                    break;
                }
                case Protocol.Msg.PlayerSettings:
                {
                    var playerId = Json.Str(msg, "player_id");
                    var values = new Dictionary<string, object>();
                    var raw = Json.Obj(Json.Get(msg, "values"));
                    if (raw != null) foreach (var pair in raw) values[pair.Key] = Normalize(pair.Value);
                    _playerSettings[playerId] = values;
                    PlayerSettingsChanged?.Invoke(playerId, values);
                    break;
                }
                case Protocol.Msg.PlayerData:
                {
                    var playerId = Json.Str(msg, "player_id");
                    var data = Json.Get(msg, "data");
                    _playerData[playerId] = data;
                    _playerDataRevision[playerId] = Json.Long(msg, "revision");
                    PlayerDataChanged?.Invoke(playerId, data);
                    break;
                }
                case Protocol.Msg.ActionTriggered:
                    ActionTriggered?.Invoke(Json.Str(msg, "key"), Json.Str(msg, "player_id"));
                    break;
                case Protocol.Msg.GameCommand:
                    CommandReceived?.Invoke(new GameCommand { Id = Json.Str(msg, "id"), PlayerId = Json.Str(msg, "player_id"), Text = Json.Str(msg, "text") });
                    break;
                case Protocol.Msg.CompanionMessage:
                    CompanionMessage?.Invoke(Json.Str(msg, "player_id"), Json.Get(msg, "data"));
                    break;
                case Protocol.Msg.CompanionPresence:
                    CompanionPresence?.Invoke(Json.Str(msg, "player_id"), Json.Bool(msg, "connected"));
                    break;
                case Protocol.Msg.Error:
                {
                    var text = Json.Str(msg, "message", "unknown error");
                    Log("GameNight host: " + text);
                    HostError?.Invoke(text);
                    break;
                }
            }
        }

        /// <summary>Number settings are whole numbers: JSON 3.0 arrives as long 3.</summary>
        static object Normalize(object value) => value is double d && d == Math.Floor(d) ? (object)(long)d : value;

        public void Dispose()
        {
            AutoReconnect = false;
            _transport?.Dispose();
            _transport = null;
        }
    }
}
