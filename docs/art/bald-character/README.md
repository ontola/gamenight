# Pixel-stable base character

`master.png` is the single reviewed 96 by 80 source drawing, cropped from the
original generated atlas. The generated archive remains as provenance only.
`build_character.py` never reads any other generated frame.

The runtime atlas is 672 by 80, with seven 96 by 80 cells:
0 idle; 1–4 walk; 5 jump; 6 seated sleep. Wake reuses idle; crouch and inactive
poses reuse sleep. There is no repeated generated idle animation.

Walking moves copied leg pixels by integer offsets. The first 52 rows remain
byte-for-byte equal across standing, walking and jumping. Sleeping lowers the
same torso and head eight pixels; metadata moves the face along with it.
All output uses the original palette and integer coordinates, without resampling.

Run `python crates/lobby/tools/reskin/build_character.py` with Pillow installed.
The builder writes all four legacy skin slots, atlas metadata and the independent
skin mask. Clothing uses a neutral tint mask; skin is coloured separately.
The custom drawing remains 48 by 48 at (24, 4) in the idle cell.
