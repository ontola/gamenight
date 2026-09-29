# Host guide imagery

`host-lobby.png` is an actual GameNight lobby capture from the public macOS
installer workflow, run 35768101137 (22 September 2026), artifact
`gamenight-macos-smoke` (10712409675). It is not a rendered mockup.
Lobby artwork retains its existing licenses in `crates/lobby`.

Other gameplay stills use the catalog's existing versioned preview URLs.
The controller illustration is original inline SVG in `host.html`.

Download sizes default to approximate values measured from the hosted installers
on 29 September 2026. `host.js` refreshes these using HEAD / Content-Length
(decimal MB) when the guide is opened; a failed request leaves the estimate.
