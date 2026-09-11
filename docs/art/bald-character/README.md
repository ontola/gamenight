# Bald base character

Generated with the built-in image generation tool from the existing fishy body atlas.
Prompt: Preserve the 14 by 7 animation atlas and poses; remove the hood, hat and
sprout in every frame, replacing them with a blank bald cream head. No eyes,
mouth, hair or headwear. Transparent background, hard pixel edges.

`generated-atlas.png` is the original generated output. `body.png` is the runtime
atlas, normalized to 1344 by 560 pixels with nearest-neighbour sampling, background
removed and an eight-colour palette. All cells are 96 by 80 pixels.
`build_pixellab.py` copies this same base for each legacy skin slot.

The user drawing remains 48 by 48 at cell coordinate (24, 4), one drawing pixel
per sprite pixel. Existing face data is unchanged. Random draws editable hair or
headwear above the facial features inside that canvas.
