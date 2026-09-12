# Shared GameNight web UI

Public source for the local and hosted Studio. HTML, CSS and JavaScript; no build framework required. The local Rust server embeds these files. The private deployment vendors a pinned snapshot using its import script; do not edit that generated snapshot.

`studio.js` retains the existing editor behavior. Event handlers and styles are external files so hosted deployments can keep a strict CSP. `site.css` and `shell.js` are the shared brand/navigation layer. Storage adapters are the next extraction step.
