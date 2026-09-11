# Lobby redesign status

Updated 2026-09-11 on `codex/lobby-redesign`.

## Implemented

- Four additional room backgrounds (underwater, sky, school, gameroom), with matching animated outfits in four color variants each. F6 cycles rooms in the Windows lobby. Asset validation checks maps, animation indices, shared sounds and unchanged colliders in CI.

- Warm generated rear wall, centered on the room with stationary scenery.
- TV and shelf behind players, without furniture collision. Three compact ground dwell zones preserve the countdown and feedback behavior.
- Large next-game face with five narrower game spines at the same height, animated on playlist changes.
- Developer artwork: title plus optional PNG and color; documented limits and title/color fallback. Embedded images also work offline.
- Personal QR in Start, linked identity and Unlink, with no empty wall QR panel when unused.
- Mobile Session tab reports real profile binding and party/game state.
- Mobile playlist pointer dragging and per-entry remove button (previous commit).
- Leave completion latch and stale departure protection; a fresh rejoin cannot be cancelled by a delayed old snapshot.
- Existing sleep/wake poses wired to AFK presence; input bypasses the visual immediately.
- Six weapon silhouettes from PixelLab, with constant-scale cannon/SMG firing recoil.

## Art work still to do

- Original living-room jump/crouch poses still use action fallbacks; the four new outfits have authored poses.
- Sword, bombs, explosions, hats and secondary props still need the same art treatment; six ranged weapons are the first completed pass.
- Some original floor/platform/furniture tiles remain. Replace these coherently after reviewing the new room composition.
- Theme selection currently uses F6 or a launch environment variable; a controller-friendly persistent selector remains to do.

## Playtest checklist

- Leave: one completed countdown, then release controls and press A; no ghost respawn or second Leave countdown.
- Walk in front of TV/shelf; hold ground zones to resume, play next or skip. Verify later case moves forward and mobile changes appear on TV.
- On phone, drag a playlist entry and remove one with the cross; verify real touch feel and server synchronization.
- Start: scan personal QR, verify linked name, Unlink, and scan again. A host restart requires a fresh session link.
- AFK sleep and immediate wake with physical controller input.

Native Windows builds and focused lobby/protocol/catalog/web/daemon tests pass. Physical controller and phone-touch checks require the next user playtest; automated tests do not substitute for those checks.
