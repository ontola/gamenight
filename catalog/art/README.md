# Game artwork

Each game has an illustrated cover and matching icon. `*-illustrated.png` files are
the runtime exports. The full-size AI-generated masters (`*-illustrated-source.png`,
1–2 MB each) are not in the repository; they are kept in the GameNight project archive
(`archive/gamenight/catalog/art/<game>/` in the shared project files).
The older `cover.png` and `icon.png` remain available as fallbacks.

TV `screenshot.png` images are actual gameplay captures, not illustrations.
Run `python scripts/build-catalog-art.py --embed` (Pillow required) to embed the
images into catalog metadata for offline use. Add `--sources <archive>/catalog/art`
to re-export the illustrated art from the masters first. Covers fit
288 x 384 and icons fit 64 x 64; every embedded PNG stays below 256 KiB.
Capturing screenshots again does not replace the illustrated masters.
