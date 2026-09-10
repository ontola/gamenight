# PixelLab benchmark: living-room lobby

Generated 2026-09-10 using PixelLab's official v2 API, from our own
`../lobby-concepts/03-living-room.png` concept. These are review drafts, not runtime
assets. No current lobby files were replaced. Prompts and reference-crop settings
are in `brief.json`; billed usage is in `usage.json` (101 generation units total).
Credentials are read locally and are not stored here.

## Outputs

- `preview.png`: character and TV variants, plus the 32px wooden platform tiles.
- `character-1.png` through `character-4.png`: four 96x96 transparent variants.
- `tv-1.png` through `tv-4.png`: four 128x128 transparent variants.
- `platform-tiles.png`: 4x4 contact sheet of the 16 returned 32x32 tiles. This is
  API return order, not an engine tile-index layout; see `platform-layout.json`.
- `walk.gif`, `sleep.gif`, `wake.gif`: 3x nearest-neighbor previews, 120ms per frame.
- Corresponding `*-sheet.png` files and numbered PNGs preserve transparent frames.
- `*-original.png`: original provider output before its palette quantization.
  Files without that suffix are the provider's quantized versions.

## Review

Character 1 is the first candidate: close to the concept, simple face, good silhouette.
The TV variants are clean but generic. The platform material is broadly consistent,
but connected tile seams and collision edges have not been tested in-engine.

Each requested animation returned four frames. Walk is recognizable, but frame two
shifts horizontally; sleep reads as closing eyes and drooping rather than sitting;
wake stretches nicely but the bottom pixel shifts from y82 to y85. Sleep and wake
were generated independently from the same standing reference, so their endpoints
are not guaranteed to match. Align anchors and author matching transition poses
before integration. No claim of production-ready animation or strict palette
consistency across separate requests.

The first platform request was rejected before generation because the reference
was not 32x32. The corrected request succeeded. The returned CDN link gave HTTP 403;
tiles were recovered via the authenticated tileset API's base64 response. No API
credential was sent to the CDN.

## Provenance

Provider: PixelLab, https://www.pixellab.ai/termsofservice (checked 2026-09-10).
The provider permits commercial use and distribution of outputs and has separate
restrictions concerning model training. These outputs are not claimed to be CC0.
Reference concept: built-in image generation, with exact prompts stored alongside
that concept. Reference crops and contact sheets were prepared with Pillow as part
of this explicitly requested PixelLab workflow.
