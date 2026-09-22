# Drawing a GameNight face

Put the head where you want it. Pass its centre and radius, not a texture corner.

```lua
local Face = require("shared.face")
Face.drawFace(player, x, y, 24)
-- Optional: point left or rotate the entire head, including its hat.
Face.drawFace(player, x, y, 24, { facing = -1, rotation = angle })
```

The helper draws the circular skin, transparent artwork and a default face when
there is no drawing. It caches textures, follows profile changes and restores
the graphics state. `skin_color` stays separate from the artwork.

## Coordinates

The studio uses a 48 x 48 canvas. The head centre is **(24, 28)** and its radius
is **12** source pixels. Positive Y points down. The default expression looks
three-quarter right. Mirror the complete drawing around the head centre to look
left. Do not mirror around the canvas centre or crop to the painted bounds.
Hats and hair may extend outside the circle; leave that space transparent.

The wire payload remains `{v:1,w:48,h:48,px:[...]}`. Null pixels are transparent.
No skin is baked into it. Face details and accessories share this canvas, so
existing artwork is preserved without a destructive layer conversion.

For Rust, parse `gamenight_protocol::Avatar`, then call `head_layout()`.
Upload `to_rgba()` as a texture. To place the head at `(x,y)` with radius `R`:

- Scale = `R / layout.radius`.
- Texture origin = `layout.center` in source pixels.
- Translate to `(x,y)`; rotate and mirror around that origin.

Never centre the visible pixels: a tall hat would move the eyes down.
The SDK also supplies the historic origins for old 16/32 pixel drawings.
Use nearest-neighbour filtering for the pixel artwork. Draw the skin circle
at the game's output resolution.

## Choosing where to draw it

Blast Party and Bubble Buddies draw the face on the character. Neon Trails,
Neon Siege and Ricochet Club use player portraits beside their names, preserving
the shape of the vehicle or trail. Stack Together uses its player cards, and
Pinpals places one portrait above each player's board.

Pass `{outline = player.color}` for a small clothing-coloured portrait rim.
The circle itself remains skin-coloured. This is optional and does not change
the head centre or radius. Live profile changes invalidate the image cache.

The store's 0–5 integration score counts essential playability checks and the
three independent profile checks: names, colours, and faces. Optional party
features do not affect that score. Development-only results remain unverified
until the evidence matches the platform and downloadable artifact.
