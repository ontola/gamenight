# Performance

A GameNight PC is often a living-room machine, not a gaming rig, and it runs
the lobby next to your game. This page collects what our own games learned
about staying smooth there. Numbers come from those games; they are examples,
not guarantees.

## Pick the renderer for the weakest machine

In Godot, `gl_compatibility` runs on the most hardware and is what Ballkickers,
Spellstorm, Downhill Rush and Bombing Bugs use. Forward+ looks better but needs
a capable GPU; choose it on purpose and measure it on a modest one. A game
that also runs on phones can develop on the Mobile renderer, so every day of
development tests the renderer players will get.

The compatibility renderer has low per-object light limits. Raise
`rendering/limits/opengl/max_lights_per_object` and
`max_renderable_lights` when you need more, and split large floors into
chunks so each chunk only receives the lights near it.

## Load everything before Ready

Prepare happens while the game is hidden. After `ready`, the Godot SDK
throttles a hidden game to 10 frames a second so it does not slow the lobby,
so anything still loading after Ready loads slowly. Do the heavy work first:

- Load levels, meshes and sounds in Prepare.
- **Compile shaders before Ready.** Draw every material variant once, for a
  few frames, somewhere the player won't see it, and enable Godot's shader
  cache. Otherwise the first explosion stutters while it compiles.
- Report progress with `notify_progress` when loading takes more than a
  moment, and stay responsive: keep handling roster changes and Dispose while
  you load. For very long loads, report a stage at least every five seconds.
- A minimized window never draws. Don't wait for `frame_post_draw` before
  Ready; see [Godot](/docs/godot#screen-ownership).

## Smooth motion on 120 Hz TVs

When physics runs at 60 ticks and the screen at 120 Hz, moving characters
judder or appear twice. Turn on physics interpolation
(`physics/common/physics_interpolation`), and make the camera follow the
interpolated positions rather than the raw physics ones.

## Keep heavy work off the frame

- **Generate in the background.** Build terrain or level chunks on a
  low-priority thread and add at most one finished chunk per frame. Downhill
  Rush builds its mountain in 60 m chunks while you ride; a large shared
  worker pool starved the engine in another game.
- **Time-slice expensive work.** Spend a fixed budget per frame (a few
  milliseconds) and continue next frame.
- **Cap catch-up.** If a fixed-step simulation falls behind, run at most a few
  steps per frame instead of spiralling.
- **Debounce rebuilds.** Rebuild meshes a few times a second at most, not on
  every change.
- **Batch input-driven work.** High-rate input (touch, mouse) can deliver
  events faster than frames; accumulate and apply once per frame.

## Draw less

- In split-screen the bottleneck is usually CPU draw submission, not the GPU.
  Every extra view draws the scene again: narrow the camera, cut shadow
  cascades and drop optional effects per view.
- Merge static geometry by material. Ballkickers went from about 555 to 260
  draw calls this way.
- Use MultiMesh for crowds, grass and particles, and leave their shadows off.
- Pool effects and cap them: a fixed number of explosions, lights and
  shadow-casting lights at once.
- Keep expensive features (global illumination, screen-space reflections)
  optional, and measure what each one costs before turning it on by default.
- Offer quality presets that change render scale and keep the HUD at native
  resolution.

## Hidden and paused cost nothing

While warming or paused, a game shares the PC with the lobby. Stop
simulation, disable extra viewports, cap the frame rate and mute audio. Use
the game clock for effects and tweens too, so smoke and sound freeze with the
game. The Godot `GameNightScreen` helper does the window, frame rate and master
bus; the simulation is yours.

## Measure

- **Build a repeatable benchmark**: a fixed seed, a fixed camera, a warm-up of
  a few seconds, vsync off, and a way to turn single features off to see what
  they cost. Compare against the same scene every time.
- **Measure before optimising.** One game went from 2.5 to 60 frames a second
  late in a match by caching a single repeated lookup; the profiler found it,
  guessing would not have.
- **Check the result stays the same.** When you speed up generation, compare a
  checksum of the output before and after.
- **Measure on modest hardware.** A laptop with integrated graphics is a fair
  stand-in for a living-room PC. Numbers from a fast desktop say little.
- The SDKs report frame times, slow frames and the machine's CPU, GPU and
  memory to GameNight while your game runs. See
  [session diagnostics](/docs/protocol#session-diagnostics). A Godot game that
  overrides the SDK's message handling must still let it see Prepare, Start and
  Pause, or these reports stop.

Headless runs (`--headless`) don't render, so they say nothing about frame
rate. Use them for logic, and real windows for performance.
