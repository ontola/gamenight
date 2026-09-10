# GameNight application branding

Derived from the repository's `site/icon.png` logo. `gamenight.ico` contains
16, 32, 48, 64, 128 and 256 pixel Windows icons. `icon-64.rgba` contains 64x64
raw RGBA pixels for the native window icon, embedded at compile time so it
also works before game assets load.

The Windows build embeds the icon and GameNight product/file descriptions.
The window identity system sets the title and native window icon on all desktop
platforms; it retries until the primary native window exists.
