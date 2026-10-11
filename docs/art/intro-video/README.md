# Homepage intro video

`web/intro.webm` (VP9) and `web/intro.mp4` (H.264), 48.6 s at 1920×1080 without sound, and their poster `web/intro.jpg` play
under the homepage hero. The video is rendered from `compose.html`: each frame
is `render(t)` in Chromium, captured by `render.cjs` and encoded with FFmpeg.

The core message is that the next game loads in the background, so nobody
waits. Scenes: intro, Game Room lobby with background loading, instant switching, zero friction (controllers stay
linked), phone companion, open protocol, free and open source, submit your own
game, outro.

## Footage

All game footage is real. Put these next to `compose.html` (not committed):

- `f/<game>/NNN.jpg`: frames of the catalog previews from
  `https://gamenight.ontola.io/games/previews/` (see the private catalog's
  `PREVIEWS.json`), extracted with `ffmpeg -i <game>.mp4 -q:v 3 f/<game>/%03d.jpg`.
- `f/lobby/NNN.jpg`: the Game Room demo, recorded with
  `godot --path lobbies/game-room --rendering-driver vulkan --resolution 1280x720
  --fixed-fps 30 --write-movie action.avi --quit-after 240 -- --demo --scene=action`.
- `stills/*.jpg`: 1280×720 crops of Ballkickers, SpaceRacer, Downhill Rush and
  God Game screenshots.
- `fonts/`: Outfit 600/800 (`lobbies/game-room/assets/fonts`) and the Ark pixel
  font (`web/fonts`); `icon.svg` from `web/`. The logo is Bungee and the
  tried variants are Monoton, Lilita One and Unbounded (Google Fonts, OFL), as
  `fonts/<Name>.woff2`. `compose.html?logo=A|B|C|F|G` switches variants; C is
  the chosen one.
- `f/lobby2/`: a chaotic take of the same demo (bots active from the first
  frame, bombs dropping every 0.9 s), recorded from a scratch copy of
  `src/demo.gd`; the lobby itself is unchanged.
- Faces are the real demo faces from `lobbies/game-room/assets/demo-faces.json`.

## Render

```sh
node render.cjs stills 2.5,14,30   # check single frames in shots/
node render.cjs video master.mp4
ffmpeg -i master.mp4 -c:v libvpx-vp9 -crf 38 -b:v 0 -row-mt 1 -an ../../../web/intro.webm
ffmpeg -i master.mp4 -c:v libx264 -preset slow -crf 25 -pix_fmt yuv420p -movflags +faststart -an ../../../web/intro.mp4
```

The hosted site serves both files with byte ranges from `/web/`.
