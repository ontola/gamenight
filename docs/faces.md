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
