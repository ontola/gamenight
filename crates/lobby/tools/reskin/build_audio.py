"""Replace the NonCommercial audio with CC0 sound effects.

Music is deliberately not replaced. Kenney's catalogue has no background tracks
— its "Music Jingles" are 0.4-1.8s stings, against the 80-163s loops Jumpy
shipped — so rather than pad the game with something that doesn't fit, every
music slot points at a single silent placeholder and the twelve NC tracks are
deleted. Sound design can come back to this as its own piece of work.

Sources, all CC0:
  Kenney Impact Sounds, Interface Sounds, Digital Audio, Sci-Fi Sounds.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "assets"
CC0 = Path("/tmp/cc0")

IMPACT = CC0 / "kenney_impact-sounds" / "Audio"
UI = CC0 / "kenney_interface-sounds" / "Audio"
DIGITAL = CC0 / "kenney_digital-audio" / "Audio"
SCIFI = CC0 / "kenney_scifi" / "Audio"

# Each weapon gets a distinguishable report rather than one shared gunshot, the
# way the original did — you should be able to hear what killed you.
SFX = {
    "effects/win_indicator/win_indicator.ogg": UI / "confirmation_001.ogg",
    "elements/environment/sproinger/jump.ogg": DIGITAL / "pepSound1.ogg",

    "elements/item/buss/shoot/shoot.ogg": SCIFI / "laserLarge_000.ogg",
    "elements/item/buss/shoot/gun_empty.ogg": UI / "click_002.ogg",
    "elements/item/buss/explosion/bullet_hit_dull.ogg": IMPACT / "impactSoft_medium_000.ogg",

    "elements/item/cannon/shoot/shoot.ogg": SCIFI / "explosionCrunch_003.ogg",
    "elements/item/cannon/shoot/gun_empty.ogg": UI / "click_003.ogg",

    "elements/item/cannonball/explosion.ogg": SCIFI / "explosionCrunch_000.ogg",
    "elements/item/cannonball/fuse.ogg": SCIFI / "thrusterFire_000.ogg",

    "elements/item/crate/fuse.ogg": SCIFI / "thrusterFire_001.ogg",
    "elements/item/crate/land.ogg": IMPACT / "impactWood_heavy_001.ogg",

    "elements/item/grenade/explosion.ogg": SCIFI / "explosionCrunch_001.ogg",
    "elements/item/grenade/fuse.ogg": SCIFI / "thrusterFire_002.ogg",

    "elements/item/jellyfish/flappy_jellyfish/explosion.ogg": SCIFI / "explosionCrunch_002.ogg",

    "elements/item/kick_bomb/explosion.ogg": SCIFI / "explosionCrunch_004.ogg",
    "elements/item/kick_bomb/fuse.ogg": SCIFI / "thrusterFire_003.ogg",

    "elements/item/machine_gun/shoot/shoot.ogg": SCIFI / "laserSmall_001.ogg",
    "elements/item/machine_gun/shoot/gun_empty.ogg": UI / "click_004.ogg",
    "elements/item/machine_gun/explosion/bullet_hit_dull.ogg": IMPACT / "impactMetal_light_000.ogg",

    "elements/item/mine/arm.ogg": DIGITAL / "twoTone1.ogg",
    "elements/item/mine/explosion.ogg": SCIFI / "lowFrequency_explosion_000.ogg",

    "elements/item/musket/shoot/shoot.ogg": SCIFI / "laserRetro_000.ogg",
    "elements/item/musket/shoot/gun_empty.ogg": UI / "click_005.ogg",
    "elements/item/musket/explosion/bullet_hit_dull.ogg": IMPACT / "impactPlank_medium_000.ogg",

    "elements/item/periscope/shoot/shoot.ogg": SCIFI / "laserSmall_003.ogg",
    "elements/item/periscope/shoot/gun_empty.ogg": UI / "click_001.ogg",
    "elements/item/periscope/explosion/bullet_hit_dull.ogg": IMPACT / "impactGeneric_light_000.ogg",

    "elements/item/sniper_rifle/shoot/shoot.ogg": SCIFI / "laserLarge_003.ogg",
    "elements/item/sniper_rifle/shoot/gun_empty.ogg": UI / "click_000.ogg",
    "elements/item/sniper_rifle/explosion/bullet_hit_dull.ogg": IMPACT / "impactMetal_medium_000.ogg",

    "elements/item/sword/sword.ogg": DIGITAL / "zap1.ogg",

    "player/sounds/jump.ogg": DIGITAL / "phaseJump1.ogg",
    "player/sounds/land.ogg": IMPACT / "footstep_concrete_000.ogg",
    "player/sounds/grab.ogg": UI / "select_001.ogg",
    "player/sounds/drop.ogg": UI / "drop_001.ogg",
    "player/sounds/death.ogg": DIGITAL / "lowDown.ogg",
}

SILENCE = ASSETS / "music" / "silence.ogg"


def pick(path: Path) -> Path:
    """Fall back to a sibling if an exact source filename isn't in the pack.

    The packs number their variants inconsistently (`laser1` vs `laser_001`), and
    a missing file should degrade to a near neighbour rather than abort the run.
    """
    if path.exists():
        return path
    stem = path.stem.rstrip("0123456789_")
    for cand in sorted(path.parent.glob(f"{stem}*{path.suffix}")):
        return cand
    raise FileNotFoundError(path)


def build_sfx() -> None:
    print("sfx:")
    missing = []
    for rel, src in SFX.items():
        dest = ASSETS / rel
        try:
            chosen = pick(src)
        except FileNotFoundError:
            missing.append(rel)
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(chosen, dest)
    print(f"  replaced {len(SFX) - len(missing)}/{len(SFX)}")
    if missing:
        print(f"  MISSING SOURCE for: {missing}")


def build_silence() -> None:
    """One shared silent track, referenced by every music slot in game.yaml."""
    SILENCE.parent.mkdir(parents=True, exist_ok=True)
    # Homebrew's ffmpeg ships without libvorbis, so use the built-in Vorbis
    # encoder. It's flagged experimental, hence -strict -2; the output is a
    # normal Vorbis stream that kira reads fine.
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i",
         "anullsrc=channel_layout=stereo:sample_rate=44100",
         "-t", "10", "-c:a", "vorbis", "-strict", "-2", str(SILENCE)],
        check=True,
    )
    for old in sorted(SILENCE.parent.glob("*.ogg")):
        if old != SILENCE:
            old.unlink()
    print(f"music:\n  {SILENCE.name} (10s silence); removed the 12 NC tracks")


if __name__ == "__main__":
    build_sfx()
    build_silence()
