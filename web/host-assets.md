# Host guide imagery

`host-lobby.png` is an actual GameNight lobby capture from the public macOS
installer workflow, run 35768101137 (22 September 2026), artifact
`gamenight-macos-smoke` (10712409675). The base image is an unmodified capture; the guide layers illustrated example
players over it, clearly captioned as an illustration.
Lobby artwork retains its existing licenses in `crates/lobby`.

Other gameplay stills use the catalog's existing versioned preview URLs.
The controller and phone UI are inline SVG/CSS in `host.html`. Character bodies
use the actual lobby idle sprite at `/assets/characters/living-room`, recoloured
and drawn at native resolution with nearest-neighbour scaling in `host.js`.
There are no synthetic vector body silhouettes.
Four faces are generated from the real character editor's `FACE_RECIPES` and
`dressRandomFace`, with fixed samples so the same player stays recognizable in
the controller, lobby, and profile illustrations. Regenerate the SVG symbols
with `node scripts/generate-host-faces.cjs`. No image or game runtime dependency
is added. The lobby already supports generated guest avatars and drawn profiles;
new presets face right within the fixed head anchor, as lobby guest artwork does. Saved
profile artwork keeps its original coordinates.

Download sizes default to approximate values measured from the hosted installers
on 29 September 2026. `host.js` refreshes these using HEAD / Content-Length
(decimal MB) when the guide is opened; a failed request leaves the estimate.
