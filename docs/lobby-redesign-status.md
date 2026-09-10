# Lobby redesign status

Updated 2026-09-10 on `codex/lobby-redesign`.

## Implemented

- Warm generated rear wall, centered on the room with stationary scenery.
- TV and shelf behind players, without furniture collision. Three compact ground dwell zones preserve the countdown and feedback behavior.
- Large next-game face with five smaller game spines, animated on playlist changes.
- Developer artwork: title plus optional PNG and color; documented limits and title/color fallback. Embedded images also work offline.
- Personal QR in Start, linked identity and Unlink, with no empty wall QR panel when unused.
- Mobile Session tab reports real profile binding and party/game state.
- Mobile playlist pointer dragging and per-entry remove button (previous commit).
- Leave completion latch and stale departure protection; a fresh rejoin cannot be cancelled by a delayed old snapshot.
- Existing sleep/wake poses wired to AFK presence; input bypasses the visual immediately.
- Six weapon silhouettes from PixelLab, with constant-scale cannon/SMG firing recoil.

## Art work still to do

- Proper authored jump/crouch poses (current explicit action fallbacks remain).
- Sword, bombs, explosions, hats and secondary props still need the same art treatment; six ranged weapons are the first completed pass.
- Some original floor/platform/furniture tiles remain. Replace these coherently after reviewing the new room composition.
- Other room themes are future work.

## Playtest checklist

- Leave: one completed countdown, then release controls and press A; no ghost respawn or second Leave countdown.
- Walk in front of TV/shelf; hold ground zones to resume, play next or skip. Verify later case moves forward and mobile changes appear on TV.
- On phone, drag a playlist entry and remove one with the cross; verify real touch feel and server synchronization.
- Start: scan personal QR, verify linked name, Unlink, and scan again. A host restart requires a fresh session link.
- AFK sleep and immediate wake with physical controller input.

Native Windows builds and focused lobby/protocol/catalog/web/daemon tests pass. Physical controller and phone-touch checks require the next user playtest; automated tests do not substitute for those checks.
