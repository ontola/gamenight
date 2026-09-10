# GameNight lobby art direction

Proposal, 2026-09-10. Research and repo audit; no production assets replaced.

## Recommendation

Build an original, cohesive GameNight art kit, then themed environments that share
its character design and interaction language. For highest quality, commission a
pixel artist to establish and finish the kit; use AI for exploration and controlled
variations. For an agent-driven workflow, benchmark PixelLab against RetroDiffusion
on the same small kit before choosing a production service. Tool features alone do
not establish comparative output quality.

Start with a cozy game room. It naturally explains the central TV, seating, music,
and joining. An underwater room should be the second test: if both look like one
game, the visual rules are useful. Build air and school after that.

## Current repository findings

- The lobby map uses 32-unit tiles and two parallax backgrounds.
- The character atlas uses 96x80 cells, 14 columns and seven rows. The reskin
  script targets a roughly 54-pixel visible character with a fixed foot baseline.
- Characters, faces, and hats are separate layers. Preserve custom phone-drawn
  avatars, player colors, and identifiable silhouettes across themes.
- `tools/reskin/build_players.py` adapts Kenney poses to inherited animation slots;
  a fin layer is an empty compatibility asset. This is migration scaffolding,
  not an art direction to preserve indefinitely.
- `tools/reskin/ASSET-SOURCES.md` records the CC0 replacement pipeline. The inspected
  source record does not identify the online pixel generator mentioned by the user.
  Update the per-asset provenance as newer artwork is traced/replaced.
- Key lobby objects are drawn in Rust. A background swap alone will not make the
  TV cabinet, pads, QR signs, and music objects match a new environment.

## Visual rules to prototype

Chunky, playful side-view pixel art with strong silhouettes and restrained detail.
Keep the current tile grid initially. Set one pixel scale, lighting direction,
outline treatment, material vocabulary, and bounded palette for each theme. Do not
invent a new pixel scale for each prop. Test from couch distance at 1080p and 4K.

Backgrounds are quieter than platforms; platforms are quieter than players and
interactive objects. Platform top edges remain obvious. Reserve bright accents for
players, actionable controls, hold progress, and warnings. Keep labels and QR codes
rendered by the engine, so they remain dynamic and scannable. Never bake UI text
into a generated picture.

Create distinct idle, walk, jump, fall, land, hold-button, sleep, and wake poses.
Prefer a small, well-authored animation set over many inconsistent generated frames.
Keep foot anchors and face attachment points stable across frames.

## Theme brief

| Theme | Setting and materials | Motion | Shared objects interpreted as |
|---|---|---|---|
| Game room | Warm wood, dark blue walls, CRT glow, cushions | Screen glow, dust, tiny lamp flicker | TV cabinet, jukebox, welcome sign |
| Underwater | Glass observatory, brass, coral outside, deep teal | Bubbles, fish silhouettes, slow caustics | Sealed monitor, buoy-like lamps, porthole signage |
| Air | Airship lounge or floating clubhouse, cream clouds, sky blue | Clouds, hanging pennants, propellers | Navigation display, radio, boarding sign |
| School | After-hours clubroom, chalk green, cream, warm timber | Clock, paper mobile, subtle dust | AV-cart TV, school radio, noticeboard |

Initially themes change visuals and ambient audio, not gravity, camera behaviour,
button timing, or collision layout. Later theme-specific layouts must satisfy the
same spawn safety, visibility, and interaction tests.

## Production workflow

1. Create three game-room concept compositions with the actual lobby layout and
   player scale. Select one reference before generating individual props.
2. Produce one benchmark kit: platform tiles including corners, TV cabinet,
   sign-in stand, decorative prop, and one character with walk/sleep/wake frames.
3. Compare PixelLab, RetroDiffusion, and an artist-finished reference using the same
   brief. Record iteration time and cleanup required, not just generation time.
4. Import the kit into the lobby. Test tile seams, animation anchors, clear collision
   surfaces, four-player readability, avatar placement, QR scanning and hold states.
5. Finish a game-room vertical slice, then reproduce it as an underwater theme.
6. Expand only after these two environments share a coherent character/UI language.

Use Aseprite as an editable pixel-art source format and PNG atlases as runtime
exports. Store source files and generation recipes with dimensions, anchors, palette,
author/provider, original reference, and license evidence. Verify source-asset
redistribution rights for the public repo separately from commercial game use.

## Theme implementation outline

Introduce an explicit theme manifest selecting backgrounds, terrain atlas, decorative
props, interactive-object skins, palette and ambient effects/audio. Keep shared map
collision and interaction definitions separate. Move visual constants for TV/pads/
signs out of Rust into theme data; keep their actions and dynamic text in code.
Validate atlas dimensions, referenced files, animation frame indices and collision
bounds during builds. Add screenshots of each theme with four avatars and all pad
states. Themes should not require a new physics or controller implementation.

## Tools and sources checked

- PixelLab: first candidate for the benchmark. Has side-scroller tilesets at 16/32px,
  reference-guided generation, animation and an API. Its terms permit commercial use
  and output distribution but restrict training other models; do not assume the
  commercial-use statement alone settles every FOSS asset-licensing question.
  https://www.pixellab.ai/docs/tools/create-tileset
  https://api.pixellab.ai/v2/docs
  https://www.pixellab.ai/termsofservice
- RetroDiffusion: second pixel-art candidate; official API examples include tilesets
  and animation output. Needs direct comparison on this game's art brief.
  https://github.com/Retro-Diffusion/api-examples
- Scenario: offers custom-model and style-consistency workflows. Revisit once we
  have enough original reference artwork to justify that pipeline.
  https://www.scenario.com/industries
- Aseprite: animation/layers and tilemap authoring for finishing and source files.
  https://www.aseprite.org/docs/
- Kenney: CC0 sources remain useful for prototypes, but mixing more packs is not the
  proposed route to an original finished GameNight identity.
  https://kenney.nl/support

No paid service was purchased and no comparative generation benchmark has yet run.
