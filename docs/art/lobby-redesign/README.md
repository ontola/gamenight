# Lobby redesign artwork

Generated with OpenAI image generation on 2026-09-10 using our living-room concept as a style reference. These are generated assets, not part of the older Kenney CC0 asset collection. Prompts and deterministic mapping are retained for future revisions.

The rear wall is separate from the interactive TV and game shelf. Player names, game titles, QR codes and countdowns are rendered live.

Weapon concepts were generated with OpenAI and used as cropped style references for PixelLab (`generate-with-style-v2`, `no_background=true`, seed 231). The concept export lacked true transparency and is not loaded by the game. PixelLab exports supply actual alpha. Variant 1 is mapped by `crates/lobby/tools/reskin/build_room.py`; all four variations remain available for art review. Existing firing code selects the recoil frames; silhouette and scale stay constant.
