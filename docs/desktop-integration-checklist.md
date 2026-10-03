# Desktop integration checklist

These requirements come from physical-controller testing of the Windows lobby and
LÖVE games. Reuse the existing integration code instead of inventing another lifecycle.

## Pause and return to the lobby

The host owns start, pause, resume and dispose. Window focus is not a lifecycle
command: never send request_start or resume because a window regained focus.
SDL focus events can arrive during a handoff and immediately undo it.

Back/Select sends one overlay request only from a running game. On every start or
resume, reset the Back gate. Require release and at least one second before another
switch. Holding the button and replayed events after focus changes must not switch twice.
Keep polling host messages while paused, but stop simulation, timers and audio.

Reference: `games/love-party/shared/back_gate.lua`, `shared/lifecycle.lua` and `main.lua`.
Regression cases: open lobby, hold Back, release, resume, hold again; repeat both
ways with a short tap and a long press. Focus changes alone must do nothing.

## Player/controller identity

Bind physical input to the host-provided seat/controller mapping, not roster array
position or player name. Each controller has at most one owner; rebinding removes
the old mapping in both directions. Missing assignments must not fall back to a pad
already owned by somebody else. Controller enumeration order across SDL and other
input libraries is not guaranteed to identify the same physical device; test it on hardware.

Test reversed join order, reconnect, unlink, joining during a game, and moving a
profile between controllers. Names, artwork, skin and clothing colors belong to
player identity; team colors are separate presentation.

## Fullscreen and native pixels

Fullscreen and resolution are separate. Opt into high-DPI rendering before creating
the window. On this Windows setup, a 4K display at 200% scaling produced a 1920x1080
frame until the process opted into per-monitor DPI awareness. Verify the captured
framebuffer dimensions, not just window size. Expected here: 3840x2160.

Use desktop fullscreen and frame the playable court rather than an old UI canvas.
Preserve proportions and visible gameplay bounds. Avoid permanent instructional
chrome during play. Pixel-art avatars intentionally retain their original pixel grid;
geometry and text should render at the display resolution.

## Readiness and verification

Ready must include creation of graphics resources and the first prepared frame,
not merely loaded simulation data. Keep prewarmed games hidden and silent; dispose
and host disconnect must clean up their process.

Run lifecycle/input regressions and a real render preview, then test transitions
with two physical controllers. Compilation or a passing simulation test cannot prove
focus behavior, display resolution, or physical controller identity is correct.