# Pinpals — Technical Choices

**Status:** draft v0.1 · **Companion to:** `design.md`

---

## 1. Constraints

| Constraint | Detail |
|---|---|
| **Primary** | The code is written by AI agents. Optimise for agent throughput above all else. |
| Platforms | Develop on macOS; ship macOS + Windows + Linux. Web not required. |
| Footprint | No heavy engine install (Unreal-class is out). |
| Performance | Must be comfortable, but see §3 — this is not the discriminator it looks like. |
| Multiplayer | Local 2P now; online must be addable without a rewrite. |

## 2. Decision: LÖVE2D (Lua) **DECIDED**

Candidates considered: **LÖVE2D**, **Godot 4**, **Bevy**.

### 2.1 What actually governs agent throughput

Agents don't fail by being unable to code. They fail by confidently writing correct-looking
code against the wrong version of an API, and then by being unable to see what went wrong.
So the criteria that dominate are:

**a. API stability in the training data.**
LÖVE's API has been essentially frozen for a decade — nearly every Lua example an agent has
ever seen still runs. Godot has one bad seam (the Godot 3 → 4 renames) but 4.x now
dominates the corpus. Bevy has no stable release and breaks its API every few months; its
training data is a soup of mutually incompatible ECS idioms that agents mix freely.

**b. Feedback loop speed.**
Agents self-correct if they can see the result fast. LÖVE: sub-second (`love .`, read
stderr). Godot: a couple of seconds. Bevy: seconds to tens of seconds for incremental
builds even with dynamic linking and a fast linker. Multiplied over hundreds of iterations,
this is the single largest cost difference.

**c. Error legibility.**
Rust's compiler is normally the *best* argument for agentic development — a free reviewer
that catches plausible-but-wrong code before it runs. But Bevy's ECS produces enormous
trait-bound error walls that are hard for humans to parse, let alone an agent
pattern-matching its way out. High error rate plus low error legibility is the worst
quadrant. Lua's `attempt to index a nil value (field 'foo')` at line 42 is worth more to an
agent than a sixty-line unsatisfied-trait diagnostic.

### 2.2 Scoring

| | LÖVE2D | Godot 4 | Bevy |
|---|---|---|---|
| API stability in corpus | ★★★ | ★★ | ★ |
| Iteration speed | ★★★ | ★★ | ★ |
| Error legibility | ★★★ | ★★ | ★ |
| Everything-as-text | ★★★ | ★★ (`.tscn` is fiddly) | ★★★ |
| Static type safety | ★ (recoverable, §7) | ★★ | ★★★ |
| 2D physics for pinball | ★★★ (Box2D) | ★★ (see §2.3) | ★★★ (Rapier) |
| Raw performance | ★★ | ★★ | ★★★ |
| Install footprint | ★★★ (~5MB) | ★★ | ★★ |

Bevy wins decisively on type safety and raw performance, and loses on all three of the
things that actually determine how fast an agent converges. **Rejected on agent-facing
grounds, not engine quality.**

### 2.3 Why not Godot, given it's already installed

Godot is the defensible runner-up and the export pipeline is genuinely excellent. Two
reasons it loses here:

1. **Built-in 2D physics is its soft spot**, and pinball is precisely its worst case: small
   fast bodies, thin colliders, stable resting contacts. Fixable with the `godot-rapier2d`
   GDExtension, but that's a thinner-documented path — exactly what you don't want an agent
   on.
2. **Its main advantage doesn't apply.** Godot pays off when you lay out scenes in the
   editor. Our two boards want to be *declarative data* loaded by code (§5), which
   neutralises the editor advantage and the `.tscn`-editing drawback simultaneously.

**Revisit if:** we find ourselves wanting to drag bumpers and tweak ramp splines by hand.

### 2.4 Version pinning

Pin an exact LÖVE version in the repo and in CI, and record it here once verified at setup
time. The 11.x line is the long-stable one; if a 12.x stable is available, check the
`love.physics` / Box2D version difference before adopting, since §3 depends on it.

## 3. Performance is not the discriminator

A 2D pinball game with one ball will not stress any of these three engines. LuaJIT plus
Box2D holds a 240 Hz fixed timestep with a full table of static geometry without noticing.

**Measured, 2026-09-06** (`tests/probe_perf.lua`), after a night of additions all landing
on the per-frame path — impact events, particles and a ball trail, a synthesized audio
kit, a session recorder, an objective readout evaluated every draw:

| per call | microseconds | share of budget |
|---|---|---|
| sim step (budget 4166µs at 240 Hz) | 6.3 | 0.15% |
| `fx.update` | 0.5 | 0.00% |
| `record.update` | 0.2 | 0.00% |
| `objective.current` | 0.5 | 0.00% |

A 60fps frame is four sim steps plus one pass of the rest: **26µs, 0.2% of 16.7ms**.
Even the `MAX_CATCHUP` worst case of 60 steps in one frame comes to 2.3%. Rendering is
not in these numbers (it needs a window), but it is flat 2D primitives.

The claim above is therefore no longer an assertion. There is roughly three orders of
magnitude of headroom on the simulation side, which is worth knowing before anyone
optimises something that costs nothing.

The real risk is **simulation quality, not throughput**: tunneling, contact jitter,
inconsistent restitution. That's a physics-engine and timestep problem, addressed in §4.

## 4. Physics

**Box2D via `love.physics`.** Mature, well understood, bullet bodies for CCD, long history
of 2D pinball built on it.

### 4.1 Fixed timestep **DECIDED**

- **Simulate at 240 Hz**, fixed step, decoupled from rendering. Render at display rate with
  interpolation between the two most recent sim states.
- Rationale: a ball at pinball speeds moves far enough per 60 Hz step to pass straight
  through a flipper. At 240 Hz the per-step displacement drops to a few pixels, and CCD
  covers the rest.
- Mark the ball as a **bullet body** regardless.
- Never pass a variable `dt` to the simulation. Accumulate real time, consume it in fixed
  chunks.

### 4.2 World scale **DECIDED**

Box2D is tuned for bodies roughly 0.1 m – 10 m. A real pinball is 27 mm across, well below
that floor, so we work at **10× real-world scale**:

- Table ≈ 12 m × 6 m; ball ≈ 0.27 m diameter
- `love.physics.setMeter(64)` → 1 m = 64 px, table ≈ 768 × 384 px in world units, scaled up
  for display
- **Scale gravity by the same factor**, or timings will feel slow. A real table inclined
  ~6.5° gives ~1.11 m/s² down-playfield; at 10× scale use ≈ 11 m/s².

Record the final values in a single constants module — agents must never hardcode them at
call sites.

### 4.3 Determinism — what we do and don't promise

Box2D is deterministic for identical binaries and identical operation ordering, but
cross-platform floating-point determinism is **not** guaranteed. Consequences:

- ✅ Replays and headless tests are reliable on one machine + one build. Use them freely.
- ❌ Do **not** plan lockstep netcode. Online (if built) is **host-authoritative state
  sync**. See §6.

## 5. Architecture

Three tiers, strictly layered. This is the most important section for agents: it's what
makes the game verifiable without a window.

```
core/     pure Lua. Rules, scoring, modes, cross-board state, the intent queue.
          NO love.* calls at all. Testable in a bare `lua` interpreter.

sim/      love.physics only. Bodies, joints, collision handling, the fixed-step loop.
          NO love.graphics / love.window / love.keyboard.
          Testable headless (window disabled — love.physics needs no window).

app/      love.graphics, love.audio, love.keyboard, love.joystick.
          Renders sim state, collects raw input, converts it to intents.
```

Dependency direction is one-way: `app → sim → core`. An agent that adds a `love.graphics`
call inside `sim/` has broken the test harness; §7 should catch it.

### 5.1 The intent layer **DECIDED**

Game logic **never** reads the keyboard. All input becomes intents:

```lua
---@class Intent
---@field player  1|2
---@field action  string   -- "flip_left" | "operator_gate_a" | ...
---@field pressed boolean
---@field tick    integer  -- sim tick the intent applies to
```

The simulation consumes a stream of intents: `world:step(intents, FIXED_DT)`.

- **Local:** intents arrive with zero delay.
- **Online:** intents arrive over a socket.
- Identical code path in both cases.

Free consequences: whole matches can be **recorded and replayed** from the intent stream
plus a seed, which is worth the layer on its own for debugging pinball physics.

### 5.2 Authoritative world state **DECIDED**

One serializable world object. No gameplay state hidden in the renderer, in closures, or in
module-level locals. Even locally, write as if there's a server: then "online" is *one
player hosts*, not a rewrite.

### 5.3 Tables as data **DECIDED**

Board layouts are **declarative data files**, not code and not scenes. Both the game and
the tests load the same definitions.

- Geometry, devices, tube mouths and their destinations, scoring targets, cross-board
  unlock wiring
- Format: **OPEN** — Lua tables (zero parsing, agent-native, but executable) vs JSON
  (inert, diffable, needs a parser). Leaning Lua tables returned from a module, with a
  validator in `core/` that agents can run.

## 6. Online, later

Not built in v1. What v1 must not foreclose:

- **Host-authoritative, state-synced.** Not lockstep (§4.3), not rollback — rollback on
  pinball physics looks broken, because correcting a ball's position after a flipper contact
  changes its entire future.
- **The design already carries the netcode constraint.** `design.md` §6.1 requires operator
  actions to be persistent states rather than instantaneous impulses. That is the thing that
  makes ~100 ms RTT invisible, and it's a design rule precisely so it can't be
  accidentally engineered away.
- **Tube transit (~750–900 ms) is the latency budget** for ball handoff — ample at any
  realistic RTT between two friends.
- Note that operator input targets the *active* board, so there is no clean
  one-client-owns-the-ball model. Both players continuously affect one simulation. This is
  fine given the rule above, and is why we need nothing exotic.

## 7. Verification — the agent feedback loop

Agents must be able to prove their work without a human looking at a screen. Set this up
in the first commit.

| Gate | Tool | What it catches |
|---|---|---|
| Static analysis | `lua-language-server` in strict mode with `---@class` / `---@param` annotations | Type errors, nil-safety, wrong arities — recovers much of what we give up by not using Rust |
| Lint | `luacheck` | Undefined globals, unused vars, shadowing, accidental global writes |
| Unit tests | `busted` against `core/` in a bare `lua` interpreter | Rules, scoring, cross-board state, table-data validation. Instant, no LÖVE needed. |
| Physics tests | `love` with `t.window = false` in `conf.lua`, results to stdout | Tunneling, ball-trajectory regressions, tube handoff correctness |
| Visual check | `love.graphics.captureScreenshot` behind a CLI flag | Lets an agent actually look at what it built |

A single `make check` (or equivalent) must run all of the above and exit non-zero on
failure. Agents should be instructed to run it before claiming a task is done.

## 8. Project layout

```
pinpals/
  main.lua
  conf.lua
  core/            pure Lua — rules, scoring, state, intents, constants
  sim/             love.physics — bodies, fixed-step loop, collisions
  app/             rendering, audio, input → intents
  data/
    tables/        board definitions (§5.3)
  tests/
    core/          busted, bare lua
    sim/           headless love
  docs/
  Makefile
```

## 9. Input

- **Two gamepads** is the target configuration (`love.joystick`).
- **Shared keyboard** as fallback: split the board so both players can reach it comfortably.
- Both paths produce identical intents (§5.1). Bindings live in one config table; nothing
  downstream knows which device an intent came from.

## 10. Build and distribution

- `.love` archive + platform runtimes; **`makelove`** for macOS / Windows / Linux artifacts.
- Cross-building all three targets from macOS is fine; CI should produce all three per tag.
- Total install footprint stays in the single-digit MB range.

## 11. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Box2D can't deliver satisfying pinball feel (jitter, mushy flippers, bad restitution) | **High** — kills the project | Test this *first*, in the §14 prototype, before any structure is built |
| Agents write untyped Lua that fails only at runtime | Medium | §7 static-analysis gate, enforced in `make check` |
| Layer boundaries erode (`love.graphics` creeping into `sim/`) | Medium | Lint rule + CI check on module imports; headless tests fail loudly if breached |
| Tunneling at high ball speed | Medium | 240 Hz fixed step + bullet bodies + a dedicated regression test |
| Lua's lack of structure invites sprawl in a large codebase | Low–Medium | Strict three-tier layering (§5), enforced module boundaries |

## 12. Decisions log

| # | Decision | Date |
|---|---|---|
| 1 | LÖVE2D over Godot and Bevy, on agent-throughput grounds | 2026-09-05 |
| 2 | Box2D via `love.physics`; 240 Hz fixed timestep; bullet bodies | 2026-09-05 |
| 3 | 10× world scale, gravity scaled to match | 2026-09-05 |
| 4 | Three-tier architecture: `core` (pure) / `sim` (physics) / `app` (LÖVE) | 2026-09-05 |
| 5 | All input routed through a tick-stamped intent stream | 2026-09-05 |
| 6 | Board layouts as declarative data, not scenes or code | 2026-09-05 |
| 7 | Online (if built) is host-authoritative state sync, never lockstep | 2026-09-05 |
