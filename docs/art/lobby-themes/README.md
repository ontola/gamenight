# Lobby themes

Five rooms: the original living room plus underwater, sky, school and gameroom.
Each extra room has a matching version of the same hooded mascot, in four outfit color variants.

- Room sources: OpenAI built-in image generation, using the existing living-room wall as a style/composition reference.
- Character and animation exports: PixelLab, using the existing mascot as the character reference. Real alpha exports remain here, separately from runtime atlases.
- Runtime mapping: `crates/lobby/tools/reskin/build_themes.py`. This reuses the existing player frame layout, face customization, physics and item attachments.
- Gameplay furniture and colliders remain shared so controls are in the same places in each room.

Use F6 in the lobby to cycle rooms, or set `GAMENIGHT_LOBBY_THEME` to `living-room`, `underwater`, `sky`, `school` or `gameroom` before launch. Unrecognized names use the living room. The keyboard shortcut is a preview selector, not persisted party configuration.

These generated assets are separate from the older Kenney CC0 collection. Source prompts are kept alongside the exports. The scripts do not contain credentials.
