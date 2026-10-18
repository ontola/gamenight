# Store media

`gamenight-publish.py store` uploads these files to the store page:

| File | What |
| --- | --- |
| `preview.mp4` | five seconds of real gameplay, 960x540, 30 FPS, silent; required to go live |
| `preview.jpg` | poster frame for the clip |
| `cover.png` | portrait cover, 360x480 |
| `icon.png` | square icon, 128x128 |
| `gameplay.png` | screenshot for the TV, 16:9 |
| `screenshots/*.png` | extra gallery images, in name order |

Make the clip with `tools/capture_preview.sh` and `tools/encode_preview.py`.
Read the [gameplay preview guide](https://github.com/ontola/gamenight/blob/main/docs/gameplay-previews.md) first.
