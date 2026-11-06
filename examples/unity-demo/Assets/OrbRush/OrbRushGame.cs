// Orb Rush: the Unity reference game for GameNight. Everyone races for orbs,
// A dashes and knocks others aside, a round lasts 60 seconds.
//
// This file is plain C#: the rules and every GameNight call. OrbRushView.cs
// draws it in Unity and reads local pads when nobody launched us. Keeping the
// two apart lets a dotnet test play the real game against a fake GameNight
// host, without Unity (sdk/unity/Tests~ and scripts/test-unity-sdk.py).
//
// Couch rules it shows: play starts at once, with no setup screen. Settings
// are declared to GameNight, so players change them from their phones (or ask
// the assistant), and Start opens a small menu that changes the same settings
// through GameNight. Back is left to GameNight: it returns to the party.
// Players are their own colour, name and face; the screen shows little else.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;
using GameNightSdk;

namespace OrbRush
{
    /// <summary>One player's input this frame: a stick (up is negative y) and held buttons (Pad bits).</summary>
    public struct PadInput
    {
        public float X, Y;
        public int Buttons;
    }

    public sealed class Runner
    {
        public string Name = "";
        public string Color = "#9aa3ad";
        public Player Profile;
        public bool Bot;
        /// <summary>GameNight seat index, or -1 when standalone.</summary>
        public int Seat = -1;
        /// <summary>Local pad index when standalone.</summary>
        public int LocalPad = -1;
        public float X, Y, VX, VY;
        public float Dash, Cooldown, Boost;
        public int Score;
        public int Held, Pressed;
        /// <summary>Per-player setting: "ball", "cube" or "capsule".</summary>
        public string Body = "ball";
        public bool Pressing(int button) => (Pressed & (1 << button)) != 0;
    }

    public sealed class OrbRushGame
    {
        public const string Title = "Orb Rush";
        public const float ArenaW = 32f, ArenaH = 18f;
        public const float Radius = 0.6f, OrbRadius = 0.3f;
        const float Speed = 7.5f, DashSpeed = 24f, DashTime = 0.18f, DashCooldown = 0.9f, BoostTime = 3f;
        public const float ResultsSeconds = 4f;
        public const string GoldFloor = "gold_floor";
        const int GoldFloorOrbs = 120;

        static readonly string[] Colors = { "#e8553d", "#3d8fe0", "#5cc45a", "#e6c13a", "#b05ce0", "#3ac9c4", "#e07ab8", "#9aa3ad" };
        static readonly string[] Names = { "Red", "Blue", "Green", "Yellow", "Purple", "Teal", "Pink", "Grey" };

        /// <summary>Declared to GameNight; the phones, the assistant and the Start menu change them.</summary>
        public static readonly Setting[] Settings =
        {
            Setting.Number("round_seconds", "Round length in seconds (next round)", 60, 20, 180),
            Setting.Number("orbs", "Orbs on the field", 6, 2, 16),
            Setting.Toggle("bumps", "Dashes knock players away", true),
            Setting.Choice("body", "Your shape", "ball", "ball", "cube", "capsule").PerPlayer()
                .Describe("Each player picks their own shape; it is saved with their profile."),
        };

        public static readonly PhoneAction[] Actions =
        {
            new PhoneAction("new_round", "New round", confirm: true, description: "Ends this round for everyone."),
            new PhoneAction("shuffle", "Shuffle the orbs"),
        };

        public readonly GameNightClient GameNight;
        readonly Func<Runner, PadInput> _localInput;
        readonly Random _random;
        readonly bool _trace;

        public readonly List<Runner> Runners = new List<Runner>();
        public readonly List<(float x, float y)> Orbs = new List<(float x, float y)>();
        public int RoundSeconds = 60, OrbCount = 6;
        public bool Bumps = true;
        public float Clock = 60f, Results;
        public int Round;
        public string Session = "";
        /// <summary>True while GameNight has not started us, or has paused us: draw, don't simulate.</summary>
        public bool HostPaused;
        public int MenuOwner = -1, MenuRow;
        public static readonly string[] MenuItems = { "Resume", "New round" };
        public const int MenuSettings = 2; // round_seconds and orbs are in the menu
        public bool GoldUnlocked;
        public int OrbsThisRound;
        public readonly Dictionary<string, int> Stats = new Dictionary<string, int> { ["dashes"] = 0, ["orbs"] = 0, ["bumps"] = 0, ["rounds"] = 0 };

        /// <summary>A player picked up an orb, or someone was bumped (seat, strength): the view shakes and rumbles.</summary>
        public event Action<Runner> OrbTaken;
        public event Action<Runner, Runner> Bumped;

        public OrbRushGame(GameNightClient gameNight, Func<Runner, PadInput> localInput, int seed = 0, bool trace = false)
        {
            GameNight = gameNight;
            _localInput = localInput;
            _random = seed != 0 ? new Random(seed) : new Random();
            _trace = trace;
            if (gameNight.LaunchedByHost)
            {
                HostPaused = true;
                Wire();
            }
        }

        // ---- GameNight -------------------------------------------------------------

        void Wire()
        {
            var gn = GameNight;
            // Declaring once is enough: the SDK re-declares after every reconnect.
            gn.Connected += () =>
            {
                gn.DeclareSettings(Settings);
                gn.DeclareActions(Actions);
                gn.DeclareCommands("Change Orb Rush while you play: the number of orbs, the round length, or a new round.",
                    "8 orbs", "rounds of 90 seconds", "new round");
                PhoneScreenFolder?.Invoke();
            };
            gn.Prepared += OnPrepared;
            gn.Started += _ => SetPaused(false);
            gn.Resumed += _ => SetPaused(false);
            gn.Paused += _ => SetPaused(true);
            gn.Disposed += _ =>
            {
                Session = "";
                MenuOwner = -1;
                SetPaused(true);
                Trace("disposed");
            };
            gn.SettingChanged += OnSetting;
            gn.PlayerSettingsChanged += (playerId, values) =>
            {
                foreach (var r in Runners)
                    if (r.Profile?.Id == playerId && values.TryGetValue("body", out var body)) r.Body = Convert.ToString(body, CultureInfo.InvariantCulture);
                Trace("body " + playerId);
            };
            gn.PlayerDataChanged += (_, __) => GoldUnlocked = gn.PartyUnion().Contains(GoldFloor);
            gn.RosterChanged += OnRoster;
            gn.PlayersUpdated += players =>
            {
                // Same players, new name, colour or face: update in place, keep playing.
                foreach (var player in players)
                foreach (var r in Runners)
                    if (r.Profile?.Id == player.Id) Dress(r, player, Runners.IndexOf(r));
                Trace("players updated");
            };
            gn.ActionTriggered += (key, playerId) =>
            {
                Trace("action " + key);
                if (key == "new_round") NewRound();
                if (key == "shuffle") for (var i = 0; i < Orbs.Count; i++) Orbs[i] = FreeSpot();
            };
            gn.CommandReceived += OnCommand;
            gn.CompanionPresence += (playerId, connected) => { if (connected) SendPhone(playerId); };
            gn.CompanionMessage += OnPhoneMessage;
        }

        /// <summary>Set by the view: declares StreamingAssets/phone as the phone screen.</summary>
        public Action PhoneScreenFolder;

        void OnPrepared(string session, IReadOnlyList<Seat> seats, IReadOnlyList<Player> players)
        {
            Session = session;
            // Live roster updates; a newcomer can join this match at once.
            GameNight.NotifyParticipation(session, instantJoin: true);
            GameNight.NotifyProgress(session, 10, "building the arena");
            SeatRunners(seats);
            NewRound(log: false);
            SetPaused(true);
            GoldUnlocked = GameNight.PartyUnion().Contains(GoldFloor);
            var names = new List<string>();
            foreach (var r in Runners) names.Add(r.Bot ? "bot" : $"{r.Name} (seat {r.Seat})");
            Trace("seated " + string.Join(", ", names));
            GameNight.NotifyProgress(session, 100);
            // Ready only once the first frame can be drawn: the level is built above.
            GameNight.NotifyReady(session);
        }

        void SeatRunners(IReadOnlyList<Seat> seats)
        {
            Runners.Clear();
            foreach (var seat in seats)
            {
                if (!seat.IsPlayed) continue;
                var r = new Runner { Bot = seat.IsBot, Seat = seat.Index };
                Dress(r, GameNight.PlayerForSeat(seat), Runners.Count);
                Runners.Add(r);
            }
            if (Runners.Count == 0) Runners.Add(Dressed(new Runner { Bot = true }, 0));
        }

        void Dress(Runner r, Player player, int index)
        {
            Dressed(r, index);
            if (player == null) return;
            r.Profile = player;
            if (!string.IsNullOrEmpty(player.Name)) r.Name = player.Name;
            if (!string.IsNullOrEmpty(player.Color)) r.Color = player.Color;
            r.Body = Convert.ToString(GameNight.PlayerSetting(player.Id, "body", r.Body), CultureInfo.InvariantCulture);
        }

        static Runner Dressed(Runner r, int index)
        {
            r.Name = Names[index % Names.Length];
            r.Color = Colors[index % Colors.Length];
            return r;
        }

        /// <summary>Someone joined or left mid-match: keep everyone else's score and place.</summary>
        void OnRoster(IReadOnlyList<Seat> seats, IReadOnlyList<Player> players)
        {
            var kept = new List<Runner>();
            foreach (var seat in seats)
            {
                if (!seat.IsPlayed) continue;
                var r = Runners.Find(x => x.Seat == seat.Index && x.Bot == seat.IsBot && (x.Bot || x.Profile?.Id == seat.PlayerId));
                if (r == null)
                {
                    r = new Runner { Bot = seat.IsBot, Seat = seat.Index };
                    Place(r, kept.Count, Math.Max(seats.Count, 1));
                    Trace("joined seat " + seat.Index);
                }
                Dress(r, GameNight.PlayerForSeat(seat), kept.Count);
                kept.Add(r);
            }
            if (kept.Count == 0) return;
            Runners.Clear();
            Runners.AddRange(kept);
            if (MenuOwner >= Runners.Count) MenuOwner = -1;
        }

        /// <summary>Values from the party: orbs and bumps apply live, round length from the next round.</summary>
        public void OnSetting(string key, object value)
        {
            switch (key)
            {
                case "round_seconds": RoundSeconds = Clamp((int)Json.ToLong(value, RoundSeconds), 20, 180); break;
                case "orbs":
                    OrbCount = Clamp((int)Json.ToLong(value, OrbCount), 2, 16);
                    while (Orbs.Count < OrbCount) Orbs.Add(FreeSpot());
                    while (Orbs.Count > OrbCount) Orbs.RemoveAt(Orbs.Count - 1);
                    break;
                case "bumps": Bumps = value is bool b ? b : Bumps; break;
                default: return;
            }
            Trace($"setting {key} = {Json.Write(value)}");
        }

        /// <summary>Plain words from the app or the assistant. We decide what they mean.</summary>
        void OnCommand(GameCommand command)
        {
            var text = command.Text.ToLowerInvariant();
            var number = Regex.Match(text, @"\d+");
            if (text.Contains("new round") || text.Contains("nieuwe ronde"))
            {
                NewRound();
                GameNight.AnswerCommand(command.Id, true, "New round!");
            }
            else if (number.Success && text.Contains("orb"))
            {
                // Through the host, so every phone shows the new value too.
                GameNight.SetSetting("orbs", Clamp(int.Parse(number.Value, CultureInfo.InvariantCulture), 2, 16));
                GameNight.AnswerCommand(command.Id, true, $"{Clamp(int.Parse(number.Value, CultureInfo.InvariantCulture), 2, 16)} orbs.");
            }
            else if (number.Success && (text.Contains("second") || text.Contains("seconde") || text.Contains("round")))
            {
                GameNight.SetSetting("round_seconds", Clamp(int.Parse(number.Value, CultureInfo.InvariantCulture), 20, 180));
                GameNight.AnswerCommand(command.Id, true, "Next round lasts " + Clamp(int.Parse(number.Value, CultureInfo.InvariantCulture), 20, 180) + " seconds.");
            }
            else GameNight.AnswerCommand(command.Id, false, "Try \"8 orbs\", \"rounds of 90 seconds\" or \"new round\".");
            Trace("command " + command.Text);
        }

        // ---- phone screen ---------------------------------------------------------------

        void OnPhoneMessage(string playerId, object data)
        {
            // Untrusted input: only act on what we expect.
            if (!(Json.Obj(data) is Dictionary<string, object> msg) || Json.Str(msg, "action") != "boost") return;
            var r = Runners.Find(x => x.Profile?.Id == playerId);
            if (r == null || r.Boost > 0f || HostPaused) return;
            r.Boost = BoostTime;
            Trace("boost " + r.Name);
            SendPhone(playerId);
        }

        void SendPhone(string playerId)
        {
            var r = Runners.Find(x => x.Profile?.Id == playerId);
            if (r == null) return;
            GameNight.SendCompanionMessage(new Dictionary<string, object>
            {
                ["name"] = r.Name, ["color"] = r.Color, ["score"] = r.Score, ["round"] = Round, ["boosting"] = r.Boost > 0f,
            }, playerId);
        }

        // ---- standalone -----------------------------------------------------------------------

        /// <summary>Standalone, screenshot and simulation: local pads first, bots fill the rest.</summary>
        public void StartStandalone(int humans, int total)
        {
            Runners.Clear();
            for (var i = 0; i < Math.Max(total, humans); i++)
                Runners.Add(Dressed(new Runner { Bot = i >= humans, LocalPad = i < humans ? i : -1 }, i));
            NewRound(log: false);
        }

        // ---- the round ---------------------------------------------------------------------------

        public void NewRound(bool log = true)
        {
            Round++;
            Clock = RoundSeconds;
            Results = 0f;
            OrbsThisRound = 0;
            for (var i = 0; i < Runners.Count; i++) Place(Runners[i], i, Runners.Count);
            foreach (var r in Runners) r.Score = 0;
            Orbs.Clear();
            for (var i = 0; i < OrbCount; i++) Orbs.Add(FreeSpot());
            if (log) GameNight.AddRoomLog($"Round {Round}");
            foreach (var r in Runners) if (r.Profile != null) SendPhone(r.Profile.Id);
        }

        static void Place(Runner r, int index, int count)
        {
            var angle = Math.PI * 2 * index / Math.Max(count, 1);
            r.X = (float)(Math.Cos(angle) * 5.5);
            r.Y = (float)(Math.Sin(angle) * 5.5);
            r.VX = r.VY = r.Dash = r.Cooldown = 0f;
        }

        (float x, float y) FreeSpot() =>
            ((float)(_random.NextDouble() * (ArenaW - 2) - (ArenaW - 2) / 2), (float)(_random.NextDouble() * (ArenaH - 2) - (ArenaH - 2) / 2));

        void SetPaused(bool paused)
        {
            HostPaused = paused;
            if (!paused)
            {
                // A button held from the lobby (the press that started us) must be
                // released before it counts here.
                foreach (var r in Runners) r.Held = (1 << Pad.ButtonCount) - 1;
            }
            Trace(paused ? "paused" : "running");
        }

        /// <summary>One simulation step. Call it every frame (or at a fixed rate for a deterministic run).</summary>
        public void Tick(float dt)
        {
            if (HostPaused || Runners.Count == 0) return;
            var moves = new (float x, float y)[Runners.Count];
            for (var i = 0; i < Runners.Count; i++) moves[i] = Read(Runners[i]);
            if (Menu()) return;
            var scoring = Results <= 0f;
            if (!scoring)
            {
                // Players keep moving while the result shows; nothing scores.
                Results -= dt;
                if (Results <= 0f) { NewRound(); return; }
            }
            else Clock -= dt;

            for (var i = 0; i < Runners.Count; i++)
            {
                var r = Runners[i];
                var (mx, my) = moves[i];
                r.Cooldown = Math.Max(0f, r.Cooldown - dt);
                r.Dash = Math.Max(0f, r.Dash - dt);
                r.Boost = Math.Max(0f, r.Boost - dt);
                if (r.Pressing(Pad.A) && r.Cooldown == 0f)
                {
                    r.Dash = DashTime;
                    r.Cooldown = DashCooldown;
                    var (dx, dy) = mx == 0f && my == 0f ? (1f, 0f) : (mx, my);
                    r.VX = dx * DashSpeed;
                    r.VY = dy * DashSpeed;
                    Stats["dashes"]++;
                    if (!r.Bot) Trace("dash " + r.Name);
                }
                if (r.Dash == 0f)
                {
                    var speed = Speed * (r.Boost > 0f ? 1.5f : 1f);
                    var k = 1f - (float)Math.Exp(-12f * dt);
                    r.VX += (mx * speed - r.VX) * k;
                    r.VY += (my * speed - r.VY) * k;
                }
                r.X = Clamp(r.X + r.VX * dt, -ArenaW / 2 + Radius, ArenaW / 2 - Radius);
                r.Y = Clamp(r.Y + r.VY * dt, -ArenaH / 2 + Radius, ArenaH / 2 - Radius);
                if (!r.Bot && r.Seat >= 0 && (mx != 0f || my != 0f || r.Pressed != 0))
                    GameNight.ReportActivity(r.Seat);
            }
            Collide();
            if (!scoring) return;
            foreach (var r in Runners)
            {
                for (var i = 0; i < Orbs.Count; i++)
                {
                    var dx = r.X - Orbs[i].x;
                    var dy = r.Y - Orbs[i].y;
                    if (dx * dx + dy * dy >= (Radius + OrbRadius) * (Radius + OrbRadius)) continue;
                    r.Score++;
                    Stats["orbs"]++;
                    OrbsThisRound++;
                    Orbs[i] = FreeSpot();
                    if (r.Seat >= 0) GameNight.Rumble(r.Seat, 0.3f, 0f, 0.08f);
                    OrbTaken?.Invoke(r);
                    if (r.Profile != null) SendPhone(r.Profile.Id);
                }
            }
            if (OrbsThisRound >= GoldFloorOrbs && !GoldUnlocked)
            {
                // What the group earns together counts for everyone who was there.
                GoldUnlocked = true;
                GameNight.UnlockForPresent(GoldFloor);
                GameNight.AddRoomLog("The gold floor is unlocked");
                Trace("unlocked " + GoldFloor);
            }
            if (Clock <= 0f) EndRound();
        }

        void Collide()
        {
            for (var i = 0; i < Runners.Count; i++)
            for (var j = i + 1; j < Runners.Count; j++)
            {
                var a = Runners[i];
                var b = Runners[j];
                var gx = b.X - a.X;
                var gy = b.Y - a.Y;
                var length = (float)Math.Sqrt(gx * gx + gy * gy);
                var overlap = Radius * 2 - length;
                if (overlap <= 0f || length == 0f) continue;
                var nx = gx / length;
                var ny = gy / length;
                a.X -= nx * overlap / 2; a.Y -= ny * overlap / 2;
                b.X += nx * overlap / 2; b.Y += ny * overlap / 2;
                if (!Bumps || (a.Dash <= 0f && b.Dash <= 0f)) continue;
                // A dashing player shoves the other one away.
                var hitter = a.Dash > b.Dash ? a : b;
                var hit = hitter == a ? b : a;
                var sign = hit == b ? 1f : -1f;
                hit.VX = nx * sign * DashSpeed * 0.8f;
                hit.VY = ny * sign * DashSpeed * 0.8f;
                hit.Dash = DashTime;
                Stats["bumps"]++;
                if (hit.Seat >= 0) GameNight.Rumble(hit.Seat, 0.2f, 0.8f, 0.2f);
                Bumped?.Invoke(hitter, hit);
            }
        }

        void EndRound()
        {
            Results = ResultsSeconds;
            Stats["rounds"]++;
            var winner = Ranking()[0];
            Trace($"round {Round} won by {winner.Name}");
            GameNight.AddRoomLog($"Round {Round}: {winner.Name} won with {winner.Score} orbs");
            // Saved progress: every player's best round, and wins.
            foreach (var r in Runners)
            {
                if (r.Profile == null) continue;
                var data = GameNight.PlayerData(r.Profile.Id) as Dictionary<string, object> ?? new Dictionary<string, object>();
                data["best"] = Math.Max((int)Json.Long(data, "best"), r.Score);
                if (r == winner) data["wins"] = Json.Long(data, "wins") + 1;
                GameNight.SavePlayerData(r.Profile.Id, data);
            }
            // The host keeps the session going: we show results, then the next round.
            if (!string.IsNullOrEmpty(Session)) GameNight.NotifyFinished(Session);
        }

        public List<Runner> Ranking()
        {
            var ranking = new List<Runner>(Runners);
            ranking.Sort((x, y) => y.Score.CompareTo(x.Score));
            return ranking;
        }

        /// <summary>Scoreboard order, left to right as the players sit on the couch.</summary>
        public List<Runner> CouchOrder()
        {
            var seats = new List<Seat>();
            foreach (var r in Runners) seats.Add(new Seat { Index = r.Seat, PlayerId = r.Profile?.Id ?? "" });
            var ordered = Couch.Order(seats, GameNight.Players);
            var result = new List<Runner>();
            foreach (var seat in ordered) result.Add(Runners.Find(r => r.Seat == seat.Index && (r.Profile?.Id ?? "") == seat.PlayerId && !result.Contains(r)));
            result.RemoveAll(r => r == null);
            return result;
        }

        // ---- input and the Start menu --------------------------------------------------------------

        (float x, float y) Read(Runner r)
        {
            PadInput input;
            if (r.Bot) input = BotInput(r);
            else if (r.Seat >= 0)
            {
                // GameNight's input for this seat: neutral while paused or stale.
                var frame = GameNight.FrameForSeat(r.Seat);
                var (sx, sy) = Pad.Stick(frame);
                input = new PadInput { X = sx, Y = sy, Buttons = frame.Buttons };
            }
            else input = _localInput != null ? _localInput(r) : default;
            var mx = input.X;
            var my = input.Y;
            var held = input.Buttons;
            // Menu navigation uses the stick like a d-pad: one step per push.
            if (mx < -0.6f) held |= 1 << Pad.Left;
            if (mx > 0.6f) held |= 1 << Pad.Right;
            if (my < -0.6f) held |= 1 << Pad.Up;
            if (my > 0.6f) held |= 1 << Pad.Down;
            r.Pressed = held & ~r.Held;
            r.Held = held;
            var length = (float)Math.Sqrt(mx * mx + my * my);
            return length > 1f ? (mx / length, my / length) : (mx, my);
        }

        PadInput BotInput(Runner r)
        {
            var best = (x: 0f, y: 0f);
            var bestD = float.MaxValue;
            foreach (var o in Orbs)
            {
                var d = (o.x - r.X) * (o.x - r.X) + (o.y - r.Y) * (o.y - r.Y);
                if (d < bestD) { bestD = d; best = o; }
            }
            var dx = best.x - r.X;
            var dy = best.y - r.Y;
            var length = Math.Max((float)Math.Sqrt(dx * dx + dy * dy), 0.001f);
            var dash = length < 5f && _random.NextDouble() < 0.03;
            return new PadInput { X = dx / length, Y = dy / length, Buttons = dash ? 1 << Pad.A : 0 };
        }

        /// <summary>
        /// Every GameNight Start menu looks the same: the game's name, Resume,
        /// New round (applies the options), then the settings. No button hints.
        /// Start opens it for whoever pressed; play waits meanwhile.
        /// </summary>
        bool Menu()
        {
            if (MenuOwner < 0)
            {
                for (var i = 0; i < Runners.Count; i++)
                {
                    if (Runners[i].Bot || !Runners[i].Pressing(Pad.Start)) continue;
                    MenuOwner = i;
                    MenuRow = 0;
                    Trace("menu open");
                    return true;
                }
                return false;
            }
            var p = Runners[MenuOwner];
            var rows = MenuItems.Length + MenuSettings;
            if (p.Pressing(Pad.Start) || p.Pressing(Pad.B)) { CloseMenu(); return true; }
            if (p.Pressing(Pad.Up)) MenuRow = (MenuRow + rows - 1) % rows;
            if (p.Pressing(Pad.Down)) MenuRow = (MenuRow + 1) % rows;
            if (p.Pressing(Pad.A) && MenuRow < MenuItems.Length)
            {
                if (MenuItems[MenuRow] == "New round") NewRound();
                CloseMenu();
                return true;
            }
            var step = (p.Pressing(Pad.Right) ? 1 : 0) - (p.Pressing(Pad.Left) ? 1 : 0);
            if (step != 0 && MenuRow >= MenuItems.Length)
            {
                var setting = Settings[MenuRow - MenuItems.Length];
                var value = setting.Key == "round_seconds" ? RoundSeconds + step * 10 : OrbCount + step;
                OnSetting(setting.Key, value);
                // Tell GameNight, so the phones and the assistant see the same value.
                if (GameNight.LaunchedByHost) GameNight.SetSetting(setting.Key, setting.Key == "round_seconds" ? RoundSeconds : OrbCount);
            }
            return true;
        }

        void CloseMenu()
        {
            MenuOwner = -1;
            Trace("menu closed");
        }

        public string MenuValue(int row)
        {
            var setting = Settings[row - MenuItems.Length];
            return setting.Key == "round_seconds" ? RoundSeconds.ToString(CultureInfo.InvariantCulture) : OrbCount.ToString(CultureInfo.InvariantCulture);
        }

        /// <summary>A short fingerprint of the state, for deterministic simulation checks.</summary>
        public string StateHash()
        {
            var parts = new List<string>();
            foreach (var r in Runners) parts.Add(string.Format(CultureInfo.InvariantCulture, "{0:F3},{1:F3},{2}", r.X, r.Y, r.Score));
            var text = string.Join(";", parts);
            unchecked
            {
                var hash = 1469598103934665603UL;
                foreach (var c in text) { hash ^= c; hash *= 1099511628211UL; }
                return hash.ToString("x16");
            }
        }

        /// <summary>Where GAME_TRACE lines go; the Unity view sends them to the player log.</summary>
        public Action<string> TraceOut = Console.WriteLine;

        void Trace(string line)
        {
            if (_trace) TraceOut(line);
        }

        static int Clamp(int v, int lo, int hi) => v < lo ? lo : v > hi ? hi : v;
        static float Clamp(float v, float lo, float hi) => v < lo ? lo : v > hi ? hi : v;
    }
}
