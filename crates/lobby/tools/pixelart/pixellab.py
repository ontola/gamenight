"""PixelLab client — native-resolution pixel art, not fake 1024px pixels.

Auth: PIXELLAB_SECRET / PIXELAB_SECRET / PIXELLAB_API_KEY (see pixellab_auth).
Docs: https://api.pixellab.ai/v2/llms.txt

Do not commit the secret. Pass it as an env var for the generate run.
"""

from __future__ import annotations

import base64
import io
import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

import pixellab_auth
from PIL import Image

API = "https://api.pixellab.ai/v2"
CELL = 32

ANIMS = ["idle", "walk", "jump", "fall", "attack", "smash", "hurt", "shield"]

# One action per strip. A whole fighting sheet in one prompt drifts.
ACTIONS = {
    "idle": "idle breathing in place, tiny bob, feet planted, looping, side view facing right",
    "walk": "walk cycle, four frames, feet on the ground, arms swinging, side view facing right",
    "jump": "jumping upward, knees tucked, arms up, side view facing right",
    "fall": "falling downward, arms out, legs down, side view facing right",
    "attack": "punching forward, arm extending then recovering, side view facing right",
    "smash": "powerful smash attack, big forward swing, side view facing right",
    "hurt": "hit stun, knocked slightly back, wincing, still facing right",
    "shield": "blocking, both arms in front, slight crouch, side view facing right",
}


class PixelLabError(RuntimeError):
    pass


def _secret() -> str:
    secret = pixellab_auth.secret()
    if not secret:
        raise PixelLabError(pixellab_auth.missing_message())
    return secret


def _decode_png(b64: str) -> Image.Image:
    raw = b64.split(",", 1)[-1]
    return Image.open(io.BytesIO(base64.b64decode(raw))).convert("RGBA")


def _encode_png(im: Image.Image) -> dict:
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    return {"type": "base64", "format": "png", "base64": base64.b64encode(buf.getvalue()).decode()}


def _request(method: str, path: str, body: dict | None = None, timeout: int = 120) -> dict:
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        API + path,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {_secret()}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        raise PixelLabError(f"{method} {path} → {e.code}: {detail[:800]}") from e


def balance() -> dict:
    return _request("GET", "/balance", timeout=30)


def crunch_palette(im: Image.Image, thresh: int = 14) -> Image.Image:
    """Merge near-duplicate colors. The 32×32 grid stays 32×32."""
    im = im.convert("RGBA")
    px = im.load()
    w, h = im.size
    reps: list[tuple[int, int, int, int]] = []
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    opx = out.load()
    for y in range(h):
        for x in range(w):
            c = px[x, y]
            if c[3] < 16:
                continue
            chosen = None
            for r in reps:
                if abs(r[0] - c[0]) + abs(r[1] - c[1]) + abs(r[2] - c[2]) <= thresh:
                    chosen = r
                    break
            if chosen is None:
                chosen = (c[0], c[1], c[2], 255)
                reps.append(chosen)
            opx[x, y] = chosen
    return out


def fit_cell(im: Image.Image, cell: int = CELL) -> Image.Image:
    """Keep native pixels. Center on a cell; plant feet near the bottom."""
    im = im.convert("RGBA")
    if im.size != (cell, cell):
        alpha = im.split()[-1]
        bbox = alpha.getbbox()
        if bbox:
            im = im.crop(bbox)
        w, h = im.size
        if w > cell or h > cell:
            scale = min(cell / w, cell / h)
            nw, nh = max(1, int(w * scale)), max(1, int(h * scale))
            im = im.resize((nw, nh), Image.NEAREST)
            w, h = im.size
        out = Image.new("RGBA", (cell, cell), (0, 0, 0, 0))
        x = (cell - w) // 2
        y = max(0, cell - h - 1)
        out.paste(im, (x, y), im)
        im = out
    return crunch_palette(im)


def _images_from(payload: Any) -> list[Image.Image]:
    frames: list[Image.Image] = []
    if payload is None:
        return frames
    if isinstance(payload, dict):
        if payload.get("base64"):
            frames.append(_decode_png(payload["base64"]))
            return frames
        for key in ("images", "frames", "animation", "result"):
            if key in payload:
                frames.extend(_images_from(payload[key]))
        return frames
    if isinstance(payload, list):
        for item in payload:
            frames.extend(_images_from(item))
    return frames


def create_pixen(
    description: str,
    width: int = CELL,
    height: int = CELL,
    *,
    outline: str = "single color black outline",
    detail: str = "low detail",
    view: str = "side",
    direction: str = "east",
    seed: int | None = None,
) -> Image.Image:
    """Native WxH pixel sprite with a transparent background."""
    payload: dict[str, Any] = {
        "description": description,
        "image_size": {"width": width, "height": height},
        "outline": outline,
        "detail": detail,
        "view": view,
        "direction": direction,
        "no_background": True,
        "enhance_prompt": True,
    }
    if seed is not None:
        payload["seed"] = seed
    out = _request("POST", "/create-image-pixen", payload, timeout=180)
    image = out.get("image") or {}
    b64 = image.get("base64")
    if not b64:
        raise PixelLabError(f"pixen returned no image: {list(out)}")
    return fit_cell(_decode_png(b64), width)


def animate_v1(first: Image.Image, action: str, n: int = 4, description: str = "") -> list[Image.Image]:
    """Sync 4-frame strip. Older model, still native pixels."""
    w, h = first.size
    out = _request(
        "POST",
        "/animate-with-text",
        {
            "description": description or action,
            "action": action,
            "image_size": {"width": w, "height": h},
            "n_frames": n,
            "reference_image": _encode_png(first),
            "view": "side",
            "direction": "east",
        },
        timeout=180,
    )
    frames = [fit_cell(im, w) for im in _images_from(out)]
    if not frames:
        raise PixelLabError(f"animate-with-text returned no frames: {list(out)}")
    return frames


def animate_v3(first: Image.Image, action: str, n: int = 4) -> list[Image.Image]:
    """Better animator. Async — poll /background-jobs/{id}."""
    started = _request(
        "POST",
        "/animate-with-text-v3",
        {
            "first_frame": _encode_png(first),
            "action": action,
            "frame_count": n,
            "no_background": True,
            "enhance_prompt": True,
        },
        timeout=60,
    )
    job = started.get("background_job_id")
    if not job:
        frames = [fit_cell(im, first.size[0]) for im in _images_from(started)]
        if frames:
            return frames
        raise PixelLabError(f"animate v3 did not start a job: {list(started)}")
    deadline = time.time() + 120
    while time.time() < deadline:
        time.sleep(3)
        st = _request("GET", f"/background-jobs/{job}", timeout=30)
        status = st.get("status", "")
        if status == "failed":
            raise PixelLabError(f"animate v3 failed: {st.get('last_response')}")
        if status == "completed":
            last = st.get("last_response") or {}
            frames = [fit_cell(im, first.size[0]) for im in _images_from(last)]
            if frames:
                return frames
            raise PixelLabError(f"animate v3 completed with no frames: {list(last)[:20]}")
    raise PixelLabError("animate v3 timed out")


def animate(first: Image.Image, action: str, n: int = 4, description: str = "") -> list[Image.Image]:
    try:
        return animate_v3(first, action, n)
    except PixelLabError as e:
        print(f"  animate v3 failed ({e}); trying v1")
        return animate_v1(first, action, n, description=description)


def _pad4(frames: list[Image.Image], fallback: Image.Image) -> list[Image.Image]:
    if not frames:
        frames = [fallback]
    while len(frames) < 4:
        frames.append(frames[-1])
    return frames[:4]


def pixen_prompt(pack: dict) -> str:
    pal = pack.get("palette") or {}
    name = pack.get("name") or pack.get("id") or "fighter"
    look = (pack.get("prompt") or "").strip()
    studio = pack.get("studio") or {}
    extra = (studio.get("description") or "").strip()
    if extra and extra not in look:
        look = f"{look} {extra}".strip()
    shape = pack.get("body_shape") or "humanoid"
    return (
        f"{name}, {look}. "
        f"Tiny {shape} platform-fighter mascot, one character only, "
        f"true 32x32 pixel art, limited palette, 1px black outline, "
        f"body {pal.get('body', '#ff6b4a')}, accent {pal.get('accent', '#ffd166')}, "
        f"side view facing right, feet planted, readable silhouette, "
        f"no text, no UI, no grid, no sprite sheet, transparent background."
    )


def create_bitforge(
    description: str,
    *,
    init: Image.Image | None = None,
    init_strength: int = 40,
    width: int = CELL,
    height: int = CELL,
) -> Image.Image:
    """Native grid, optional photo as init. Not a downscale."""
    payload: dict[str, Any] = {
        "description": description,
        "image_size": {"width": width, "height": height},
        "outline": "single color black outline",
        "detail": "low detail",
        "view": "side",
        "direction": "east",
        "no_background": True,
    }
    if init is not None:
        payload["init_image"] = _encode_png(init.convert("RGBA"))
        payload["init_image_strength"] = init_strength
    out = _request("POST", "/create-image-bitforge", payload, timeout=180)
    image = out.get("image") or {}
    b64 = image.get("base64")
    if not b64:
        raise PixelLabError(f"bitforge returned no image: {list(out)}")
    return fit_cell(_decode_png(b64), width)


def find_photo(pack_dir: Path | None, pack: dict) -> Path | None:
    if pack_dir is None:
        return None
    pack_dir = Path(pack_dir)
    names = []
    studio = pack.get("studio") or {}
    if studio.get("photo"):
        names.append(str(studio["photo"]))
    names.extend(["source.png", "source.jpg", "source.jpeg", "photo.png", "photo.jpg"])
    for name in names:
        p = Path(name)
        if not p.is_absolute():
            p = pack_dir / name
        if p.is_file():
            return p
    return None


def idle_for(pack: dict, pack_dir: Path | None = None) -> Image.Image:
    """Photo and/or description → one native 32×32 idle, facing right."""
    desc = pixen_prompt(pack)
    photo = find_photo(pack_dir, pack)
    if photo is not None:
        print(f"  idle from photo {photo.name}")
        init = Image.open(photo).convert("RGBA")
        try:
            return create_bitforge(desc, init=init)
        except PixelLabError as e:
            print(f"  bitforge from photo failed ({e}); pixen from text")
    print(f"  pixen idle: {pack.get('id')}")
    return create_pixen(desc)


def build_character(pack: dict, pack_dir: Path | None = None) -> dict[str, list[Image.Image]]:
    """Idle (photo and/or text) + one 4-frame strip per action. Not one giant sheet."""
    desc = pixen_prompt(pack)
    idle = idle_for(pack, pack_dir)
    out: dict[str, list[Image.Image]] = {"idle": [idle, idle, idle, idle]}
    for anim in ANIMS:
        action = ACTIONS[anim]
        print(f"  animate {anim}")
        try:
            frames = animate(idle, action, 4, description=desc)
            out[anim] = _pad4(frames, idle)
        except PixelLabError as e:
            print(f"  {anim} failed ({e}); duplicating idle")
            out[anim] = [idle, idle, idle, idle]
    return out
