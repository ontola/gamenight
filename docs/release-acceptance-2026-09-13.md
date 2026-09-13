# Windows preview 2 release acceptance — 2026-09-13

Published release: https://github.com/ontola/gamenight/releases/tag/v0.1.0-preview.2
Public installer: https://gamenight.ontola.io/download/GameNight-Setup.exe

## Build provenance

- Windows installer workflow 34749239707 succeeded; built source 8cb34135f17f5d7a0f5fd45b12ca21fef0430a38.
- Full Windows/macOS/Linux CI 34749877524 passed at e640bdc. The later commits contain test/documentation corrections and a Windows media string-allocation cleanup, not additional game features.
- Party pack workflow 34749090480 passed, including software-OpenGL rendering on Linux and Windows protocol/certification tests.
- Installer SHA-256: 9ca32a3781346558ab5a632d13932e95b14a943ac1b507f6af55078b1e7328bf.

## Actual installation and download test

The workflow artifact was downloaded, its checksums verified, and Setup installed successfully (exit 0) into a separate Windows directory. The installed launcher opened the lobby, with its first lobby frame submitted after 1,245 ms, and downloaded all nine catalog games into its initially empty data directory.

A second instance of the same installed daemon used port 7932, another empty game cache and AI seats, so the test would not replace a controller player who joined the visible lobby. `scripts/test-installed-downloads.mjs` verified download, prepare, start, pause and resume twice for:

- Neon Trails
- Blast Party
- Neon Siege
- Ricochet Club
- Paint Rush
- Volley Trouble
- Stack Together
- Bubble Buddies

Pinpals was downloaded by the fresh launcher but was not included in this eight-game lifecycle loop. Separately, downloaded LÖVE packages passed their protocol and simulation tests. Volley Trouble rendered an actual 3840×2160 preview.

After publication, the installer was downloaded again through the website. Its SHA-256 exactly matched the installed and tested artifact. Production health, homepage Windows CTA, catalog, catalog guide, studio and the existing Mac download returned successfully. All eight LÖVE entries advertise their Windows download in the live catalog. Cloud deployment followed a database backup; the previous Docker image remains available for rollback.

## Limits

This verifies real downloads and executable lifecycle through the host protocol. Physical controller routing, perceived fullscreen/focus transitions and interactive gameplay are not certified by these automated checks. Native computer-use initialization failed in the Codex environment (`failed to write kernel assets`, OS error 3); that limitation must not be reported as a passing visual/controller test.

The initial test runner connected before the host listened. It now retries connection for up to 30 seconds. It still refuses to alter a party with existing user profiles.