using System;
using System.Collections.Generic;
using System.Globalization;

namespace GameNightSdk
{
    /// <summary>
    /// A player's pixel-art face, decoded to RGBA bytes (row 0 at the top) plus
    /// where the head circle sits in it. Matches the Godot face.gd and the LÖVE
    /// helper, so a face looks the same in every game. See docs/faces.md.
    /// </summary>
    public sealed class Avatar
    {
        public int Width;
        public int Height;
        /// <summary>RGBA, 4 bytes per pixel, row-major from the top-left.</summary>
        public byte[] Rgba;
        /// <summary>Head centre in artwork pixels, from the top-left.</summary>
        public float HeadX;
        public float HeadY;
        /// <summary>The head radius the artwork was drawn for, in artwork pixels.</summary>
        public float HeadRadius = Protocol.AVATAR_HEAD_RADIUS;

        const int MaxPayload = 800000;
        static readonly Dictionary<string, Avatar> Cache = new Dictionary<string, Avatar>();

        /// <summary>Decode a player's <c>avatar</c> payload, or null when it is empty or invalid.</summary>
        public static Avatar Decode(string payload)
        {
            if (string.IsNullOrEmpty(payload) || payload.Length > MaxPayload) return null;
            lock (Cache)
            {
                if (Cache.TryGetValue(payload, out var cached)) return cached;
            }
            var decoded = DecodeUncached(payload);
            lock (Cache)
            {
                // Profile changes replace their artwork; keep a long night bounded.
                if (Cache.Count >= 32) Cache.Clear();
                Cache[payload] = decoded;
            }
            return decoded;
        }

        static Avatar DecodeUncached(string payload)
        {
            var data = Json.TryParse(payload);
            List<object> pixels;
            int width, height;
            var legacy = data is List<object>;
            if (legacy)
            {
                pixels = (List<object>)data;
                width = height = (int)Math.Sqrt(pixels.Count);
            }
            else if (data is Dictionary<string, object> obj && Json.Long(obj, "v") == Protocol.AVATAR_FORMAT_VERSION)
            {
                var w = Json.Get(obj, "w");
                var h = Json.Get(obj, "h");
                if (!(w is long) || !(h is long)) return null;
                width = (int)(long)w;
                height = (int)(long)h;
                pixels = Json.Get(obj, "px") as List<object>;
                if (pixels == null) return null;
            }
            else return null;
            if (width < 1 || height < 1 || width > Protocol.AVATAR_MAX_SIDE || height > Protocol.AVATAR_MAX_SIDE) return null;
            if (pixels.Count != width * height) return null;

            var rgba = new byte[width * height * 4];
            for (var i = 0; i < pixels.Count; i++)
            {
                if (!(pixels[i] is string hex) || !TryHex(hex, out var r, out var g, out var b)) continue;
                if (legacy && string.Equals(hex, Protocol.AVATAR_LEGACY_TRANSPARENT, StringComparison.OrdinalIgnoreCase)) continue;
                rgba[i * 4] = r;
                rgba[i * 4 + 1] = g;
                rgba[i * 4 + 2] = b;
                rgba[i * 4 + 3] = 255;
            }
            return new Avatar
            {
                Width = width,
                Height = height,
                Rgba = rgba,
                HeadX = Protocol.AVATAR_HEAD_X - Offset(width, 14),
                HeadY = Protocol.AVATAR_HEAD_Y - Offset(height, 15),
            };
        }

        static float Offset(int side, float small)
        {
            if (side == 32) return small;
            if (side == 16) return small + 8;
            return (Protocol.AVATAR_SIZE - side) / 2f;
        }

        /// <summary>Parse "#rrggbb".</summary>
        public static bool TryHex(string hex, out byte r, out byte g, out byte b)
        {
            r = g = b = 0;
            if (hex == null || hex.Length != 7 || hex[0] != '#') return false;
            if (!int.TryParse(hex.Substring(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var value)) return false;
            r = (byte)(value >> 16);
            g = (byte)(value >> 8);
            b = (byte)value;
            return true;
        }

        /// <summary>
        /// Paint a round head into a square RGBA image (row 0 at the top): the skin
        /// circle, then the artwork scaled so its head fills the circle. Hair and
        /// hats may stick out past the circle, as in every GameNight game. With no
        /// artwork it draws the same simple default face as the other SDKs.
        /// </summary>
        public static byte[] PaintHead(Player player, int size, float radiusFraction = 0.36f, bool facingLeft = false)
        {
            var image = new byte[size * size * 4];
            var center = size / 2f;
            var radius = size * radiusFraction;
            if (!TryHex(player?.SkinColor, out var sr, out var sg, out var sb)) { sr = 0xf5; sg = 0xe9; sb = 0xbe; }
            for (var y = 0; y < size; y++)
            for (var x = 0; x < size; x++)
            {
                var dx = x + 0.5f - center;
                var dy = y + 0.5f - center;
                if (dx * dx + dy * dy > radius * radius) continue;
                Put(image, size, x, y, sr, sg, sb, 255);
            }
            var art = Decode(player?.Avatar);
            var scale = radius / Protocol.AVATAR_HEAD_RADIUS;
            if (art != null)
            {
                for (var y = 0; y < size; y++)
                for (var x = 0; x < size; x++)
                {
                    var ax = (x + 0.5f - center) / scale;
                    if (facingLeft) ax = -ax;
                    var px = (int)Math.Floor(ax + art.HeadX);
                    var py = (int)Math.Floor((y + 0.5f - center) / scale + art.HeadY);
                    if (px < 0 || py < 0 || px >= art.Width || py >= art.Height) continue;
                    var i = (py * art.Width + px) * 4;
                    if (art.Rgba[i + 3] == 0) continue;
                    Put(image, size, x, y, art.Rgba[i], art.Rgba[i + 1], art.Rgba[i + 2], 255);
                }
                return image;
            }
            // The shared three-quarter default: two eyes and a mouth.
            var facing = facingLeft ? -1f : 1f;
            Dot(image, size, center + 0 * facing * scale, center - 2 * scale, 1.2f * scale);
            Dot(image, size, center + 6 * facing * scale, center - 2 * scale, 1.2f * scale);
            for (var t = 0f; t <= 1f; t += 0.05f)
                Dot(image, size, center + (2 + 4 * t) * facing * scale, center + 5 * scale, 0.5f * scale);
            return image;
        }

        static void Dot(byte[] image, int size, float cx, float cy, float r)
        {
            for (var y = (int)(cy - r - 1); y <= (int)(cy + r + 1); y++)
            for (var x = (int)(cx - r - 1); x <= (int)(cx + r + 1); x++)
            {
                if (x < 0 || y < 0 || x >= size || y >= size) continue;
                var dx = x + 0.5f - cx;
                var dy = y + 0.5f - cy;
                if (dx * dx + dy * dy <= r * r) Put(image, size, x, y, 20, 23, 31, 255);
            }
        }

        static void Put(byte[] image, int size, int x, int y, byte r, byte g, byte b, byte a)
        {
            var i = (y * size + x) * 4;
            image[i] = r; image[i + 1] = g; image[i + 2] = b; image[i + 3] = a;
        }
    }
}
