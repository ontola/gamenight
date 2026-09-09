"""What the lobby room is made of, and how big each piece has to be.

Sizes are not decoration. The interactive props are drawn by the game at exact
dimensions declared in `assets/elements/environment/**`, and art that does not
match them will sit crooked against its own hitbox — a player would land on a
pad that isn't where it looks. Those sizes are quoted here next to the file
that owns them, so a change over there is easy to spot as a mismatch here.

The style clause is doing the heavy lifting. Generating twenty props with
twenty prompts gives twenty little pictures; the shared suffix is what makes
them read as one room.
"""

from __future__ import annotations

# Appended to every prompt. Warm, saturated, low-light — a room lit by a TV and
# a lamp rather than by daylight.
STYLE = (
    "cozy dimly lit living room game night, warm saturated palette, "
    "deep browns and dark teal shadows with warm amber highlights, "
    "chunky readable pixel art, clean dark outline, no text, "
    # The model drew the first TV and poster frame in three-quarter
    # perspective, which fights a flat 2D platformer. It needs telling several
    # ways; "flat side view" alone was not enough.
    "strictly orthographic flat elevation, straight-on front view, "
    "no perspective, no isometric angle, no tilt, no vanishing point"
)

# --------------------------------------------------------------------------
# Interactive furniture. Sizes are contracts — see the referenced YAML.
# --------------------------------------------------------------------------

INTERACTIVE = [
    # music/card.music_screen.yaml: screen 148x48 + 12px frame per side.
    # Wide on purpose, and hard to get from a prompt: "jukebox" pulls the model
    # toward an upright Wurlitzer, which came back 62px wide in a 172px canvas.
    # The shape is game design, not taste — this is a platform players land on.
    dict(name="jukebox", w=172, h=72,
         prompt="a wide low 1970s wooden hi-fi stereo receiver, landscape "
                "cabinet far wider than it is tall, filling the whole width, "
                "warm walnut wood grain, two big round chrome dials at the "
                "left and right, a row of small square buttons, one long dark "
                "rectangular display window across the centre, thin orange "
                "neon tube along the top and bottom edges, chrome corner "
                "brackets"),

    # next_game/next_game_trigger.yaml: screen 144x48, button 72x14 above it.
    dict(name="tv_cabinet", w=176, h=112,
         prompt="a chunky retro television on a low wooden media cabinet, "
                "big blank dark screen, two small game consoles and a stack of "
                "cartridges on the shelf below, thick plastic bezel"),

    # next_game/next_game.element.yaml: the 72x14 landing on top of the cabinet.
    dict(name="start_button_pad", w=72, h=14,
         prompt="a wide flat arcade button pad set into the top of a cabinet, "
                "big round green button, metal rim, seen from the side"),

    # qr_sign/qr_sign.yaml: a 160x160 lit face plus its frame.
    dict(name="qr_poster_frame", w=192, h=192,
         prompt="an empty framed poster on a wall, thick ornate wooden frame, "
                "blank flat dark centre panel, small string of fairy lights "
                "draped over the top corner"),

    # music/pause.music_pad.yaml and skip.music_pad.yaml: 56x14 floor zones.
    dict(name="music_pad_pause", w=56, h=14,
         prompt="a flat dark metal floor plate with two bold bright amber "
                "vertical bars glowing on it, simple bold shape, few colours"),
    dict(name="music_pad_skip", w=56, h=14,
         prompt="a low flat floor pad with a glowing cyan skip-forward icon, "
                "rubber mat edge, seen from the side"),

    # sign_in/sign_in.yaml: a 64x14 floor zone.
    # A woven doormat is unreadable at 14px — it came back as orange mush.
    # A lit strip reads instantly at this size and says "stand here" just as
    # well.
    dict(name="sign_in_pad", w=64, h=14,
         prompt="a flat illuminated floor strip, dark metal plate with a "
                "bright warm amber light bar glowing along its length, "
                "simple bold shape, few colours"),
]

# --------------------------------------------------------------------------
# Decor. Free-standing, no hitbox to honour — sized to read at the lobby's
# scale, where a standing character is about 54px tall.
# --------------------------------------------------------------------------

DECOR = [
    dict(name="couch", w=112, h=56,
         prompt="a plump red two-seater sofa with cushions, slightly worn, "
                "a game controller left on one cushion"),
    dict(name="arcade_cabinet", w=64, h=96,
         prompt="an upright arcade cabinet, glowing marquee, dark screen, "
                "joystick and coloured buttons on the control deck"),
    dict(name="coffee_table", w=64, h=28,
         prompt="a low wooden coffee table with an open pizza box, "
                "a soda cup and a bowl of snacks on top"),
    dict(name="popcorn_bucket", w=32, h=40,
         prompt="a big red and white striped popcorn bucket overflowing with "
                "popcorn, standing on the floor"),
    dict(name="bean_bag", w=48, h=32,
         prompt="a soft round teal bean bag chair, squashed and comfy"),
    dict(name="floor_lamp", w=24, h=80,
         prompt="a tall floor lamp with a warm glowing cream shade, thin stand"),
    dict(name="potted_plant", w=32, h=44,
         prompt="a leafy houseplant in a terracotta pot"),
    dict(name="shelf_with_games", w=80, h=24,
         prompt="a wooden wall shelf lined with colourful game boxes and "
                "a small trophy"),
    dict(name="rug", w=112, h=20,
         prompt="a round woven rug with a purple and warm red pattern, "
                "flattened, seen from the side at a shallow angle"),
    dict(name="wall_poster_a", w=40, h=48,
         prompt="a small framed pixel art poster of a smiling monster, "
                "thin dark frame"),
    dict(name="wall_poster_b", w=40, h=48,
         prompt="a small framed pixel art poster of a rocket ship, "
                "thin dark frame"),
    dict(name="neon_sign", w=72, h=32,
         prompt="a glowing pink neon wall sign in a simple squiggly shape, "
                "no letters, mounted on a bracket"),
    dict(name="string_lights", w=96, h=24,
         prompt="a drooping string of small round coloured fairy lights, "
                "warm glow, hanging horizontally"),
    dict(name="mini_fridge", w=40, h=52,
         prompt="a small retro mini fridge with a bottle opener on the side "
                "and a sticker on the door"),
    dict(name="controller_pile", w=32, h=16,
         prompt="two game controllers lying on the floor with tangled cables"),
]

# --------------------------------------------------------------------------
# Tiles. These must tile seamlessly left-to-right and match the 32px grid the
# maps address; roles mirror tile_roles.py (surface ends vs interior fill).
# --------------------------------------------------------------------------

TILES = [
    dict(name="floor_wood_mid", w=32, h=32,
         prompt="seamless horizontal wooden floorboard platform tile, top "
                "surface visible as a walkable edge, warm brown planks"),
    dict(name="floor_wood_left", w=32, h=32,
         prompt="left end cap of a wooden floorboard platform, rounded left "
                "edge, top surface walkable, warm brown planks"),
    dict(name="floor_wood_right", w=32, h=32,
         prompt="right end cap of a wooden floorboard platform, rounded right "
                "edge, top surface walkable, warm brown planks"),
    dict(name="floor_wood_center", w=32, h=32,
         prompt="seamless solid interior fill of a wooden structure, no top "
                "edge, dark warm timber, tileable in every direction"),
    dict(name="wall_brick_mid", w=32, h=32,
         prompt="seamless dark red brick wall tile with warm mortar, tileable"),
    dict(name="wall_paper_mid", w=32, h=32,
         prompt="seamless patterned wallpaper tile, deep teal with a subtle "
                "repeating diamond motif, tileable"),
]


def batch(which: str) -> list[dict]:
    return {"interactive": INTERACTIVE, "decor": DECOR, "tiles": TILES,
            "all": INTERACTIVE + DECOR + TILES}[which]
