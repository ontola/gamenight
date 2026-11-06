using System.Collections.Generic;
using UnityEngine;

namespace GameNightSdk
{
    /// <summary>
    /// Player faces as textures: the skin circle with their own pixel art on it,
    /// the same head every GameNight game draws. Put the texture on a quad, a
    /// sprite or a RawImage; it is cached per face and size, so asking every
    /// frame is cheap. Hair may stick out past the circle, so leave some room.
    /// </summary>
    public static class GameNightFaces
    {
        static readonly Dictionary<string, Texture2D> Cache = new Dictionary<string, Texture2D>();

        /// <param name="size">Texture side in pixels; the head circle is 72% of it.</param>
        /// <param name="facingLeft">Mirror the three-quarter face for a player looking left.</param>
        public static Texture2D Head(Player player, int size = 64, bool facingLeft = false)
        {
            var key = (player?.Avatar ?? "") + "|" + (player?.SkinColor ?? "") + "|" + size + "|" + facingLeft;
            if (Cache.TryGetValue(key, out var cached) && cached != null) return cached;
            // Profile changes replace their face; keep a long night bounded.
            if (Cache.Count >= 64)
            {
                foreach (var texture in Cache.Values) if (texture != null) Object.Destroy(texture);
                Cache.Clear();
            }
            var rgba = Avatar.PaintHead(player, size, 0.36f, facingLeft);
            // Unity textures start at the bottom row; the painter starts at the top.
            var flipped = new byte[rgba.Length];
            var row = size * 4;
            for (var y = 0; y < size; y++) System.Buffer.BlockCopy(rgba, y * row, flipped, (size - 1 - y) * row, row);
            var head = new Texture2D(size, size, TextureFormat.RGBA32, false)
            {
                filterMode = FilterMode.Point, // pixel art stays crisp
                wrapMode = TextureWrapMode.Clamp,
                name = "GameNight face " + (player?.Name ?? ""),
            };
            head.LoadRawTextureData(flipped);
            head.Apply(false, true);
            Cache[key] = head;
            return head;
        }

        /// <summary>The player's clothing colour, or <paramref name="fallback"/>.</summary>
        public static Color Color(Player player, Color fallback) => GameNight.ParseColor(player?.Color, fallback);
    }
}
