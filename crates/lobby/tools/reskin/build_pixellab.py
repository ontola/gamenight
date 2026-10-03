"""Rebuild the reviewed character and TV assets. Requires Pillow."""
from pathlib import Path
from PIL import Image
from build_character import build as build_character
ROOT = Path(__file__).resolve().parents[4]

def build():
    build_character()
    tv = Image.open(ROOT / 'docs/art/pixellab-benchmark/tv-1.png').convert('RGBA')
    tv.crop(tv.getbbox()).save(ROOT / 'crates/lobby/assets/elements/environment/next_game/pixellab-tv.png')

if __name__ == '__main__': build()
