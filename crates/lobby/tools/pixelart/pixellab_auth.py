"""Where the PixelLab token comes from — one list, imported by everyone.

Kept free of Pillow and every other dependency so the *gate* ("should we call
PixelLab at all?") can be asked without importing the client.

This exists because the client accepted three env names while the two callers
that decide the backend checked only one, so a key under either of the other
names silently fell through to the local pixel artist.
"""

from __future__ import annotations

import os

ENV_NAMES = ("PIXELLAB_SECRET", "PIXELAB_SECRET", "PIXELLAB_API_KEY")


def secret() -> str | None:
    for name in ENV_NAMES:
        value = os.environ.get(name)
        if value and value.strip():
            return value.strip()
    return None


def available() -> bool:
    return secret() is not None


def missing_message() -> str:
    return (
        "no PixelLab token in "
        + " / ".join(ENV_NAMES)
        + " — create one at https://pixellab.ai/account"
    )
