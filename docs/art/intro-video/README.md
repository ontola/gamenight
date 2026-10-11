# Homepage intro video

`web/intro.mp4` (58 s, 1920×1080, silent) and its poster `web/intro.jpg` play
under the homepage hero. The video is rendered from `compose.html`: each frame
is `render(t)` in Chromium, captured by `render.cjs` and encoded with FFmpeg.

Scenes: intro, Game Room lobby, fast switching, zero friction (controllers stay
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
  font (`web/fonts`); `icon.svg` from `web/`.

## Render

```sh
node render.cjs stills 2.5,14,30   # check single frames in shots/
node render.cjs video master.mp4
ffmpeg -i master.mp4 -c:v libx264 -preset slow -crf 25 -pix_fmt yuv420p -movflags +faststart -an ../../../web/intro.mp4
```

The hosted site serves the file with byte ranges from `/web/intro.mp4`.
