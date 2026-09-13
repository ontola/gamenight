# Game artwork

Each game has an illustrated cover and matching icon. The `*-illustrated-source.png`
files are AI-generated artwork masters; `*-illustrated.png` files are runtime exports.
The older `cover.png` and `icon.png` remain available as fallbacks.

TV `screenshot.png` images are actual gameplay captures, not illustrations.
Run `python scripts/build-catalog-art.py --embed` (Pillow required) to export the
masters and embed the images into catalog metadata for offline use. Covers fit
288 x 384 and icons fit 64 x 64; every embedded PNG stays below 256 KiB.
Capturing screenshots again does not replace the illustrated masters.
