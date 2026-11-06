using System;
using System.Collections.Generic;

namespace GameNightSdk
{
    /// <summary>One seat of a session, as the host sent it in <c>prepare</c> or a
    /// roster update. The seat index, not a Unity joystick number, is who a player is.</summary>
    public sealed class Seat
    {
        public int Index;
        /// <summary>Opaque controller token; empty when the seat has no pad (a bot, a phone-only player).</summary>
        public string Controller = "";
        /// <summary><see cref="Protocol.SeatOccupant"/>: "local", "ai", "remote" or "empty".</summary>
        public string Occupant = Protocol.SeatOccupant.Empty;
        /// <summary>The player sitting here, empty for bots and empty seats.</summary>
        public string PlayerId = "";
        /// <summary>Every field as the host sent it, for anything this class leaves out.</summary>
        public Dictionary<string, object> Raw = new Dictionary<string, object>();

        public bool IsLocal => Occupant == Protocol.SeatOccupant.Local;
        public bool IsBot => Occupant == Protocol.SeatOccupant.Ai;
        public bool IsPlayed => IsLocal || IsBot;

        public static Seat From(object value)
        {
            var obj = Json.Obj(value) ?? new Dictionary<string, object>();
            var occupant = Json.Obj(Json.Get(obj, "occupant"));
            return new Seat
            {
                Index = Json.Int(obj, "index", -1),
                Controller = Json.Str(obj, "controller"),
                Occupant = Json.Str(occupant, "kind", Protocol.SeatOccupant.Empty),
                PlayerId = Json.Str(occupant, "player_id"),
                Raw = obj,
            };
        }

        public static List<Seat> ListFrom(object value)
        {
            var seats = new List<Seat>();
            foreach (var item in Json.List(value)) seats.Add(From(item));
            return seats;
        }
    }

    /// <summary>A person at the party: their name, clothing colour, skin colour and
    /// face. Treat <see cref="Id"/> as opaque; it is how you find their seat.</summary>
    public sealed class Player
    {
        public string Id = "";
        public string Name = "";
        /// <summary>"#rrggbb" clothing or team colour, empty when the host sent none.</summary>
        public string Color = "";
        /// <summary>"#rrggbb" skin colour for the head circle.</summary>
        public string SkinColor = "";
        /// <summary>The avatar payload (JSON pixel art). Decode it with <see cref="Avatar.Decode"/>.</summary>
        public string Avatar = "";
        /// <summary>Stable per signed-in profile; use it to key local saves.</summary>
        public string ProfileKey = "";
        /// <summary>Where they sit on the couch, from the left. Null when unknown.</summary>
        public int? Couch;
        public Dictionary<string, object> Raw = new Dictionary<string, object>();

        public static Player From(object value)
        {
            var obj = Json.Obj(value) ?? new Dictionary<string, object>();
            var couch = Json.Get(obj, "couch");
            return new Player
            {
                Id = Json.Str(obj, "id"),
                Name = Json.Str(obj, "name"),
                Color = Json.Str(obj, "color"),
                SkinColor = Json.Str(obj, "skin_color"),
                Avatar = Json.Str(obj, "avatar"),
                ProfileKey = Json.Str(obj, "profile_key"),
                Couch = couch == null ? (int?)null : (int)Json.ToLong(couch),
                Raw = obj,
            };
        }

        public static List<Player> ListFrom(object value)
        {
            var players = new List<Player>();
            foreach (var item in Json.List(value)) players.Add(From(item));
            return players;
        }
    }

    public static class Couch
    {
        /// <summary>
        /// <paramref name="seats"/> left to right as the players sit (they pick their
        /// place in the lobby's Start menu). Lay split screens and scoreboards out in
        /// this order. Seats without a known place (bots, older hosts) follow the
        /// people in seat order. Call it again on PlayersUpdated: people move.
        /// </summary>
        public static List<Seat> Order(IEnumerable<Seat> seats, IEnumerable<Player> players)
        {
            var place = new Dictionary<string, int>();
            foreach (var player in players)
                if (player.Couch.HasValue) place[player.Id] = player.Couch.Value;
            var keyed = new List<(int place, int index, int order, Seat seat)>();
            var n = 0;
            foreach (var seat in seats)
            {
                var at = place.TryGetValue(seat.PlayerId ?? "", out var p) ? p : 1000;
                keyed.Add((at, seat.Index, n++, seat));
            }
            keyed.Sort((a, b) => a.place != b.place ? a.place.CompareTo(b.place)
                : a.index != b.index ? a.index.CompareTo(b.index) : a.order.CompareTo(b.order));
            var result = new List<Seat>(keyed.Count);
            foreach (var entry in keyed) result.Add(entry.seat);
            return result;
        }
    }

    /// <summary>One pad's state from the host's <c>controller_frame</c> stream.</summary>
    public struct ControllerFrame
    {
        public string Controller;
        /// <summary>Button bits, see <see cref="Pad"/>.</summary>
        public int Buttons;
        /// <summary>Six axes, -32767 to 32767: left x/y, right x/y, left/right trigger.</summary>
        public int[] Axes;

        public bool IsEmpty => string.IsNullOrEmpty(Controller);

        public static ControllerFrame From(object value)
        {
            var obj = Json.Obj(value);
            var frame = new ControllerFrame { Controller = Json.Str(obj, "controller"), Buttons = Json.Int(obj, "buttons"), Axes = new int[6] };
            var axes = Json.List(Json.Get(obj, "axes"));
            for (var i = 0; i < axes.Count && i < 6; i++) frame.Axes[i] = (int)Json.ToLong(axes[i]);
            return frame;
        }
    }

    /// <summary>Button bits, axis indices and deadzones of a controller frame.</summary>
    public static class Pad
    {
        public const int A = 0;
        public const int B = 1;
        public const int X = 2;
        public const int Y = 3;
        public const int LB = 4;
        public const int RB = 5;
        /// <summary>Owned by GameNight (it returns to the party): never bind it in a game.</summary>
        public const int Back = 6;
        public const int Start = 7;
        public const int LS = 8;
        public const int RS = 9;
        public const int Up = 10;
        public const int Down = 11;
        public const int Left = 12;
        public const int Right = 13;
        public const int ButtonCount = 14;

        public const int AxisLeftX = 0;
        public const int AxisLeftY = 1;
        public const int AxisRightX = 2;
        public const int AxisRightY = 3;
        public const int AxisLeftTrigger = 4;
        public const int AxisRightTrigger = 5;

        /// <summary>The deadzones our games settled on.</summary>
        public const float StickDeadzone = 0.15f;
        public const float TriggerDeadzone = 0.06f;

        public static float Axis(ControllerFrame frame, int index)
        {
            if (frame.Axes == null || index < 0 || index >= frame.Axes.Length) return 0f;
            return Math.Max(-1f, Math.Min(1f, frame.Axes[index] / 32767f));
        }

        public static bool Button(ControllerFrame frame, int index) =>
            index >= 0 && index < ButtonCount && (frame.Buttons & (1 << index)) != 0;

        /// <summary>A stick with a radial deadzone, rescaled so it starts at 0.
        /// <paramref name="side"/> 0 is the left stick. Up is NEGATIVE y, as on the wire;
        /// the Unity helper <c>GameNight.Stick</c> flips it so up is positive.</summary>
        public static (float x, float y) Stick(ControllerFrame frame, int side = 0, float deadzone = StickDeadzone)
        {
            var x = Axis(frame, side * 2);
            var y = Axis(frame, side * 2 + 1);
            var length = (float)Math.Sqrt(x * x + y * y);
            if (length <= deadzone) return (0f, 0f);
            var scale = Math.Min((length - deadzone) / (1f - deadzone), 1f) / length;
            return (x * scale, y * scale);
        }

        /// <summary>A trigger from 0 to 1 with a deadzone. <paramref name="side"/> 0 is the left one.</summary>
        public static float Trigger(ControllerFrame frame, int side = 0, float deadzone = TriggerDeadzone)
        {
            var t = Math.Max(Axis(frame, AxisLeftTrigger + side), 0f);
            return t <= deadzone ? 0f : (t - deadzone) / (1f - deadzone);
        }
    }

    /// <summary>A match setting to declare, see docs/game-settings.md.</summary>
    public sealed class Setting
    {
        public string Key;
        public string Label;
        public string Kind;
        public object Default;
        public int? Min;
        public int? Max;
        public string[] Options;
        public string Description;
        /// <summary>"player" for a value every player picks for themselves.</summary>
        public string Scope;

        public static Setting Toggle(string key, string label, bool value) =>
            new Setting { Key = key, Label = label, Kind = Protocol.SettingKind.Toggle, Default = value };

        public static Setting Number(string key, string label, int value, int min, int max) =>
            new Setting { Key = key, Label = label, Kind = Protocol.SettingKind.Number, Default = value, Min = min, Max = max };

        public static Setting Choice(string key, string label, string value, params string[] options) =>
            new Setting { Key = key, Label = label, Kind = Protocol.SettingKind.Choice, Default = value, Options = options };

        /// <summary>Make this a per-player setting, saved with each player's profile.</summary>
        public Setting PerPlayer() { Scope = Protocol.SettingScope.Player; return this; }

        public Setting Describe(string text) { Description = text; return this; }

        public Dictionary<string, object> ToJson()
        {
            var obj = new Dictionary<string, object> { ["key"] = Key, ["label"] = Label, ["kind"] = Kind, ["default"] = Default };
            if (Min.HasValue) obj["min"] = Min.Value;
            if (Max.HasValue) obj["max"] = Max.Value;
            if (Options != null) obj["options"] = new List<object>(Options);
            if (!string.IsNullOrEmpty(Description)) obj["description"] = Description;
            if (!string.IsNullOrEmpty(Scope)) obj["scope"] = Scope;
            return obj;
        }
    }

    /// <summary>A button on the players' phones, next to your settings.</summary>
    public sealed class PhoneAction
    {
        public string Key;
        public string Label;
        public string Description;
        /// <summary>The phone asks "are you sure?" first.</summary>
        public bool Confirm;

        public PhoneAction(string key, string label, bool confirm = false, string description = null)
        {
            Key = key; Label = label; Confirm = confirm; Description = description;
        }

        public Dictionary<string, object> ToJson()
        {
            var obj = new Dictionary<string, object> { ["key"] = Key, ["label"] = Label };
            if (Confirm) obj["confirm"] = true;
            if (!string.IsNullOrEmpty(Description)) obj["description"] = Description;
            return obj;
        }
    }

    /// <summary>A plain-text request from a player ("10 orbs please"). Answer it once
    /// with <see cref="GameNightClient.AnswerCommand"/>.</summary>
    public sealed class GameCommand
    {
        public string Id;
        public string PlayerId;
        public string Text;
    }
}
