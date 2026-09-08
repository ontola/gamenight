"""Rebuild items, environment, hats, UI and effects from CC0 source art.

Same contract as the other builders: atlas grids keep their declared geometry so
no element YAML has to change, and non-atlas images keep their exact pixel
dimensions so anything measuring them (nine-patch borders, parallax sizes) still
lines up.

Sources, all CC0:
  Kenney Platformer Art Deluxe, Kenney UI Pack, and Kay Lousberg's "2D Guns"
  (opengameart.org/content/2d-guns).

Explosions and muzzle flashes are drawn here rather than sourced: the packs have
no frame-by-frame blast animations, and a flat cartoon burst is cheap to
generate and matches the rest of the art better than a stock sprite would.
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw

import atlaslib as al

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "assets"
CC0 = Path("/tmp/cc0")

DELUXE = CC0 / "kenney_platformer-art-deluxe"
ITEMS = DELUXE / "Base pack" / "Items"
TILES = DELUXE / "Base pack" / "Tiles"
ENEMIES = DELUXE / "Base pack" / "Enemies"
REQUEST = DELUXE / "Request pack" / "Tiles"
GUNS = CC0 / "kenney_guns" / "PNG higher resolution (@2x)"
UIPACK = CC0 / "kenney_ui-pack" / "PNG"

built: list[str] = []


# --------------------------------------------------------------------------
# generated effects
# --------------------------------------------------------------------------

def burst_frame(w: int, h: int, t: float, blobs: int = 7) -> Image.Image:
    """One frame of a flat cartoon explosion. `t` runs 0 -> 1 over the animation."""
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx, cy = w / 2, h / 2
    grow = 0.15 + 0.85 * t
    fade = 1.0 if t < 0.55 else max(0.0, 1.0 - (t - 0.55) / 0.45)
    # Hot core fades to smoke as the blast expands.
    layers = [
        ((255, 236, 150), 0.55, 0.0),
        ((252, 168, 52), 0.80, 0.12),
        ((214, 96, 40), 1.00, 0.24),
    ]
    if t > 0.5:
        layers.append(((120, 120, 132), 1.05, 0.30))
    for colour, spread, delay in layers:
        local = max(0.0, (t - delay)) / max(1e-6, 1 - delay)
        if local <= 0:
            continue
        r_max = min(w, h) * 0.48 * spread
        for i in range(blobs):
            a = 2 * math.pi * i / blobs + t * 0.6
            dist = r_max * grow * 0.55
            bx = cx + math.cos(a) * dist
            by = cy + math.sin(a) * dist * 0.8
            br = r_max * (0.42 - 0.16 * local) * grow
            if br <= 0.5:
                continue
            d.ellipse([bx - br, by - br, bx + br, by + br],
                      fill=colour + (int(235 * fade),))
        cr = r_max * (0.55 - 0.25 * local) * grow
        if cr > 0.5:
            d.ellipse([cx - cr, cy - cr, cx + cr, cy + cr],
                      fill=colour + (int(235 * fade),))
    return img


def flash_frame(w: int, h: int, t: float) -> Image.Image:
    """Muzzle flash: a short star burst that pops then vanishes."""
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx, cy = w / 2, h / 2
    env = math.sin(math.pi * min(1.0, t * 1.15)) ** 0.6
    if env <= 0.02:
        return img
    for colour, scale in (((255, 214, 92), 1.0), ((255, 248, 214), 0.55)):
        rx, ry = w * 0.48 * env * scale, h * 0.46 * env * scale
        pts = []
        spikes = 8
        for i in range(spikes * 2):
            a = math.pi * i / spikes
            rad = 1.0 if i % 2 == 0 else 0.45
            pts.append((cx + math.cos(a) * rx * rad, cy + math.sin(a) * ry * rad))
        d.polygon(pts, fill=colour + (int(240 * env),))
    return img


def build_generated() -> None:
    """Fill every explosion / muzzle-flash atlas with drawn frames."""
    specs = [
        # (atlas yaml relative to assets, kind)
        ("elements/item/cannonball/explosion.atlas.yaml", "burst"),
        ("elements/item/grenade/explosion.atlas.yaml", "burst"),
        ("elements/item/kick_bomb/explosion.atlas.yaml", "burst"),
        ("elements/item/mine/explosion.atlas.yaml", "burst"),
        ("elements/item/jellyfish/flappy_jellyfish/explosion.atlas.yaml", "burst"),
        ("elements/item/buss/explosion/explosion.atlas.yaml", "burst"),
        ("elements/item/machine_gun/explosion/explosion.atlas.yaml", "burst"),
        ("elements/item/musket/explosion/explosion.atlas.yaml", "burst"),
        ("elements/item/periscope/explosion/explosion.atlas.yaml", "burst"),
        ("elements/item/sniper_rifle/explosion/explosion.atlas.yaml", "burst"),
        ("elements/item/buss/shoot/buss_shoot.atlas.yaml", "flash"),
        ("elements/item/cannon/shoot/cannon_shoot.atlas.yaml", "flash"),
        ("elements/item/musket/shoot/musket_shoot.atlas.yaml", "flash"),
        ("elements/item/periscope/shoot/periscope_shoot.atlas.yaml", "flash"),
        ("elements/item/sniper_rifle/shoot/sniper_shoot.atlas.yaml", "flash"),
    ]
    for rel, kind in specs:
        atlas = ASSETS / rel
        if not atlas.exists():
            print(f"  !! missing atlas {rel}")
            continue
        grid = al.read_grid(atlas)
        n = grid.columns * grid.rows
        sheet = al.transparent(grid)
        for i in range(n):
            t = i / max(1, n - 1)
            frame = (burst_frame(grid.tile_w, grid.tile_h, t) if kind == "burst"
                     else flash_frame(grid.tile_w, grid.tile_h, t))
            ox, oy = grid.cell(i)
            sheet.alpha_composite(frame, (ox, oy))
        dest = atlas.parent / _image_name(atlas)
        al.save(sheet, dest)
        al.verify(dest, grid)
        built.append(str(dest.relative_to(ASSETS)))


def _image_name(atlas_yaml: Path) -> str:
    for line in atlas_yaml.read_text().splitlines():
        if line.startswith("image:"):
            return line.split(":", 1)[1].strip().lstrip("./")
    raise ValueError(atlas_yaml)


# --------------------------------------------------------------------------
# atlas fills from source sprites
# --------------------------------------------------------------------------

def fill(atlas_rel: str, sources: list[Path], pad: float = 0.92,
         bottom: bool = False, rotate_arc: float | None = None) -> None:
    """Fill an atlas, cycling `sources` across its frames.

    `rotate_arc` sweeps the sprite through that many degrees across the frames,
    which is how the sword's swing and the toppling animations are produced.
    """
    atlas = ASSETS / atlas_rel
    grid = al.read_grid(atlas)
    n = grid.columns * grid.rows
    imgs = [al.load(s) for s in sources if s.exists()]
    if not imgs:
        print(f"  !! no sources for {atlas_rel}")
        return
    sheet = al.transparent(grid)
    for i in range(n):
        src = imgs[i % len(imgs)]
        if rotate_arc is not None:
            ang = -rotate_arc / 2 + rotate_arc * (i / max(1, n - 1))
            src = src.rotate(ang, resample=Image.BICUBIC, expand=True)
        spr = al.fit(src, grid.tile_w, grid.tile_h, pad)
        if bottom:
            al.paste_bottom_center(sheet, grid, i, spr, grid.tile_h)
        else:
            al.paste_center(sheet, grid, i, spr)
    dest = atlas.parent / _image_name(atlas)
    al.save(sheet, dest)
    al.verify(dest, grid)
    built.append(str(dest.relative_to(ASSETS)))


def replace_image(rel: str, source: Path, pad: float = 0.92,
                  stretch: bool = False) -> None:
    """Swap a non-atlas image, preserving its exact pixel dimensions."""
    dest = ASSETS / rel
    w, h = Image.open(dest).size
    src = al.load(source)
    if stretch:
        out = src.resize((w, h), al.RESAMPLE)
    else:
        out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        spr = al.fit(src, w, h, pad)
        out.alpha_composite(spr, ((w - spr.width) // 2, (h - spr.height) // 2))
    al.save(out, dest)
    built.append(rel)


# --------------------------------------------------------------------------
# the mapping
# --------------------------------------------------------------------------

def build_items() -> None:
    g = lambda n: GUNS / f"{n}.png"
    i = lambda n: ITEMS / f"{n}.png"
    t = lambda n: TILES / f"{n}.png"

    fill("elements/item/buss/buss.atlas.yaml", [g("shotgun")])
    fill("elements/item/buss/bullet/buss_bullet.atlas.yaml", [g("small_bullet")])
    fill("elements/item/cannon/cannon.atlas.yaml", [g("ammobox")])
    fill("elements/item/cannonball/cannonball.atlas.yaml", [i("bomb")])
    fill("elements/item/crate/crate.atlas.yaml", [t("boxCrate") if t("boxCrate").exists() else t("box")])
    fill("elements/item/grenade/grenade.atlas.yaml", [g("grenade")])
    fill("elements/item/jellyfish/jellyfish.atlas.yaml", [ENEMIES / "slimeWalk1.png"])
    fill("elements/item/jellyfish/flappy_jellyfish/flappy_jellyfish.atlas.yaml",
         [ENEMIES / "flyFly1.png", ENEMIES / "flyFly2.png"])
    fill("elements/item/kick_bomb/kick_bomb.atlas.yaml", [i("bomb"), i("bombFlash")])
    fill("elements/item/machine_gun/machine_gun.atlas.yaml", [g("smg")])
    fill("elements/item/machine_gun/bullet/machine_gun_bullet.atlas.yaml",
         [g("small_bullet")], pad=1.0)
    fill("elements/item/mine/mine.atlas.yaml", [i("bomb"), i("bombFlash")])
    fill("elements/item/musket/musket.atlas.yaml", [g("assaultrifle")])
    fill("elements/item/musket/bullet/musket_bullet.atlas.yaml", [g("medium_bullet")])
    fill("elements/item/periscope/periscope.atlas.yaml", [g("magazine")])
    fill("elements/item/periscope/bullet/periscope_bullet.atlas.yaml", [g("medium_bullet")])
    fill("elements/item/sniper_rifle/sniper_rifle.atlas.yaml", [g("sniper")])
    fill("elements/item/sniper_rifle/bullet/sniper_bullet.atlas.yaml", [g("large_bullet")])
    fill("elements/item/sword/sword.atlas.yaml",
         [REQUEST / "swordSilver.png"], pad=0.95, rotate_arc=160.0)
    fill("elements/item/stomp_boots/stomp_boots_icon.atlas.yaml", [i("springboardUp")])
    # The boots are a decoration drawn over the player's own frames, so they are
    # placed at the foot line of every cell in the shared 14x7 player grid.
    _build_boots()
    _build_crate_breaking()


def _build_boots() -> None:
    atlas = ASSETS / "elements/item/stomp_boots/stomp_boots.atlas.yaml"
    grid = al.read_grid(atlas)
    boot = al.load(ITEMS / "springboardUp.png")
    spr = al.fit(boot, 34, 20, 1.0)
    sheet = al.transparent(grid)
    for idx in range(grid.columns * grid.rows):
        al.paste_bottom_center(sheet, grid, idx, spr, 64)
    dest = atlas.parent / _image_name(atlas)
    al.save(sheet, dest)
    al.verify(dest, grid)
    built.append(str(dest.relative_to(ASSETS)))


def _build_crate_breaking() -> None:
    """Crate holds, then bursts into brick fragments over 25 frames."""
    atlas = ASSETS / "elements/item/crate/crate_breaking.atlas.yaml"
    grid = al.read_grid(atlas)
    n = grid.columns * grid.rows
    box = al.fit(al.load(TILES / "box.png"), grid.tile_w, grid.tile_h, 0.55)
    frags = [al.load(ITEMS / f"particleBrick{k}.png")
             for k in ("1a", "1b", "2a", "2b") if (ITEMS / f"particleBrick{k}.png").exists()]
    sheet = al.transparent(grid)
    hold = max(1, n // 5)
    for idx in range(n):
        if idx < hold:
            al.paste_center(sheet, grid, idx, box)
            continue
        t = (idx - hold) / max(1, n - hold - 1)
        for k, f in enumerate(frags or [box]):
            spr = al.fit(f, grid.tile_w // 5, grid.tile_h // 5, 1.0)
            a = 2 * math.pi * k / max(1, len(frags or [box])) + 0.4
            dist = int(grid.tile_w * 0.42 * t)
            al.paste_center(sheet, grid, idx, spr,
                            dx=int(math.cos(a) * dist),
                            dy=int(math.sin(a) * dist) - int(grid.tile_h * 0.1 * t))
    dest = atlas.parent / _image_name(atlas)
    al.save(sheet, dest)
    al.verify(dest, grid)
    built.append(str(dest.relative_to(ASSETS)))


def build_environment() -> None:
    i = lambda n: ITEMS / f"{n}.png"
    e = lambda n: ENEMIES / f"{n}.png"

    fill("elements/decoration/anemones/anemones.atlas.yaml",
         [i("plant"), i("plantPurple"), i("bush"), i("mushroomRed"), i("mushroomBrown")],
         bottom=True)
    fill("elements/decoration/seaweed/seaweed.atlas.yaml",
         [i("bush"), i("cactus"), i("plant"), i("plantPurple"), i("rock")], bottom=True)
    fill("elements/environment/slippery_seaweed/slippery_seaweed.atlas.yaml",
         [i("bush"), i("cactus"), i("plant"), i("plantPurple"), i("rock")], bottom=True)
    fill("elements/environment/coral_spikes/coral_spikes.atlas.yaml",
         [i("spikes")], bottom=True)
    fill("elements/environment/crab/crab.atlas.yaml", [e("slimeWalk1"), e("slimeWalk2")])
    fill("elements/environment/snail/snail.atlas.yaml", [e("snailWalk1"), e("snailWalk2")])
    fill("elements/environment/sproinger/sproinger.atlas.yaml",
         [i("springboardUp"), i("springboardDown")], bottom=True)
    fill("elements/environment/slippery/slippery.atlas.yaml", [TILES / "snowHalf.png"])
    for fish in ("ArabianAngelfish", "BandedButterflyFish", "BlueGreenChromis",
                 "BlueTang", "RoyalGramma"):
        fill(f"elements/environment/fish_school/{fish}.atlas.yaml",
             [e("flyFly1"), e("flyFly2")])
    replace_image("elements/environment/urchin/urchin.png", i("rock"))


HATS = {
    "bonnet": "mushroomRed", "bow": "gemRed", "bucket": "boxEmpty",
    "chef": "mushroomBrown", "chest": "boxCoin", "cowboy": "cactus",
    "crown": "star", "diving_goggles": "gemBlue", "fisherman": "bush",
    "pineapple": "plant", "pirate": "flagRed", "pot": "boxItem",
    "pufferfish": "rock", "spicy_lobster": "fireball", "straw": "plantPurple",
    "topper": "boxWarning", "viking": "mushroomBrown", "unicorn": "gemYellow", "water_lily": "cloud1",
}


def build_hats() -> None:
    for hat, prop in HATS.items():
        src = ITEMS / f"{prop}.png"
        if not src.exists():
            src = TILES / f"{prop}.png"
        fill(f"player/hats/{hat}/{hat}.atlas.yaml", [src], pad=0.95)


def build_misc() -> None:
    fill("effects/win_indicator/win_indicator.atlas.yaml", [ITEMS / "star.png"])
    fill("plugins/anchor/anchor.atlas.yaml", [ITEMS / "weight.png"])
    # The alarm emote is a two-frame "!" blink drawn over the player's face.
    atlas = ASSETS / "player/emotes/alarm.atlas.yaml"
    grid = al.read_grid(atlas)
    sheet = al.transparent(grid)
    for idx in range(grid.columns * grid.rows):
        cellimg = Image.new("RGBA", (grid.tile_w, grid.tile_h), (0, 0, 0, 0))
        d = ImageDraw.Draw(cellimg)
        cx = grid.tile_w / 2
        colour = (255, 224, 80, 255) if idx % 2 == 0 else (255, 255, 255, 255)
        d.rounded_rectangle([cx - 3, 4, cx + 3, grid.tile_h - 11], 2, fill=colour)
        d.ellipse([cx - 3, grid.tile_h - 8, cx + 3, grid.tile_h - 2], fill=colour)
        ox, oy = grid.cell(idx)
        sheet.alpha_composite(cellimg, (ox, oy))
    dest = atlas.parent / _image_name(atlas)
    al.save(sheet, dest)
    al.verify(dest, grid)
    built.append(str(dest.relative_to(ASSETS)))


def build_ui() -> None:
    blue = UIPACK / "Blue" / "Default"
    grey = UIPACK / "Grey" / "Default"
    replace_image("ui/button.png", grey / "button_rectangle_depth_border.png", stretch=True)
    replace_image("ui/button-focused.png", blue / "button_rectangle_depth_border.png", stretch=True)
    replace_image("ui/button-down.png", blue / "button_rectangle_border.png", stretch=True)
    replace_image("ui/panel.png", grey / "button_rectangle_depth_flat.png", stretch=True)
    replace_image("ui/menu-background.png",
                  DELUXE / "Mushroom expansion" / "Backgrounds" / "bg_grasslands.png",
                  stretch=True)
    icons = {
        "Object.png": blue / "icon_outline_square.png",
        "Tile.png": grey / "icon_outline_square.png",
        "PointerAndMap.png": blue / "icon_cross.png",
        "Cursor.png": blue / "arrow_basic_n.png",
        "Pointer.png": blue / "arrow_basic_n.png",
        "Eraser.png": grey / "icon_cross.png",
    }
    for name, src in icons.items():
        dest = ASSETS / "ui" / "editor" / name
        if not dest.exists():
            continue
        if not src.exists():
            src = blue / "icon_outline_square.png"
        replace_image(f"ui/editor/{name}", src, pad=0.8)


# Unreferenced NonCommercial leftovers: nothing in the code or YAML loads these,
# so they are deleted rather than reskinned.
ORPHANS = [
    "elements/item/musket/muskets.png",
    "elements/item/sniper_rifle/snipers.png",
    "ui/lifebar.png",
    "ui/lifebar-progress.png",
]


def drop_orphans() -> None:
    for rel in ORPHANS:
        p = ASSETS / rel
        if p.exists():
            p.unlink()
            print(f"  removed unreferenced {rel}")


if __name__ == "__main__":
    build_generated()
    build_items()
    build_environment()
    build_hats()
    build_misc()
    build_ui()
    drop_orphans()
    print(f"props: wrote {len(built)} images")
