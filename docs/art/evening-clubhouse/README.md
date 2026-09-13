# Evening clubhouse — approved direction, 2026-09-13

The user approved concept.png after reviewing three directions and explicitly requested movable, front-facing assets. The runtime uses separate wall, terrain, exit, TV and cupboard textures. Screenshots, covers, QR and player colours remain dynamic. No collider or interaction position was changed.

## Sources and reproduction

Images generated with the built-in image_gen tool, using concept.png as the style reference. Original exports are retained beside this document. These are generated artwork, not third-party stock.

- wall-source.png: quiet full-bleed navy wall, edge windows and amber lighting; no furniture, platforms or floor.
- props-source.png: four-object production atlas containing door, ledge, television and cupboard.
- concept.png: approved modular kit and two layout examples; reference only, never rendered in-game.

Run `python crates/lobby/tools/reskin/build_clubhouse.py` from any directory (Pillow and NumPy). The deterministic exporter removes the neutral checker matte accidentally baked into the sprite export, crops individual silhouettes, downsamples using nearest-neighbour sampling, and assembles the existing 17x5 terrain grid. The cupboard frame is nine-sliced to preserve corner proportions. Original images are never overwritten.

Outputs: `crates/lobby/assets/themes/clubhouse/`. Default living-room and gameroom use wall.png. The shared terrain atlas uses the oak ledges and darker timber shell; other theme backgrounds remain available. All jump-through tops retain their existing tile boundary. Door is 64x100 world pixels, with its bottom on the existing doorway floor.

## Generation prompts

### Wall
Production background asset for the evening clubhouse 2D platform game in reference. Generate ONLY the BACK WALL, full bleed landscape 5:3 ratio. Dark midnight navy vertical wooden wall panels with warm amber light at upper left and upper right, two narrow sunset windows at far left and far right edges, small trailing plants in upper corners. Main center 75 percent and entire bottom quarter empty quiet dark navy wall. Flat orthographic front elevation, crisp chunky low resolution pixel art intended for 640x384 pixels, restrained texture, warm cozy lighting with stepped pixel shading. NO floor, NO baseboard, NO ceiling depth, NO platforms, NO furniture, NO door, NO television, NO sign, NO text, NO borders. These will be separate movable sprites. Wall extends beyond every image edge. Preserve approved reference midnight navy and honey amber palette. No perspective. This is a single runtime background texture not a presentation board.

### Props
Produce a clean production sprite atlas on genuinely transparent alpha background using the approved evening clubhouse objects from reference. Four isolated objects in a 2 by 2 grid with very generous transparent padding, no overlap and no labels. TOP LEFT: front-facing arched oak exit door with warm amber round window, no mat. TOP RIGHT: long straight horizontal oak stepping ledge with two short front-facing brackets, flat front elevation no top or side perspective. BOTTOM LEFT: front-facing wide television outer frame only, thin midnight blue metal frame, two short feet, screen interior pure dark navy, no console. BOTTOM RIGHT: front-facing oak cupboard outer frame, portrait-shaped tall rectangular dark empty center opening occupying almost all cupboard area, thin oak side pillars and cornice and plinth; no books no drawers no compartments. All match reference oak material and chunky deliberate pixel art. Every object in strict front elevation. Sparse controlled pixel grain, crisp silhouette, top-left edge highlights, no shadows outside silhouette, NO blur or antialiasing, NO background, NO fake transparency checkerboard. These are separate movable game sprites for a 2D platformer.
