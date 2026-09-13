--- §10: "audio does the warning work". Incoming ball, operator device arming
--- and the purgatory timer all have to be legible without looking, because
--- both players are watching one board and only one of them is holding it.
---
--- Every sound is synthesized at load rather than shipped as an asset. Two
--- reasons: the repo stays text-only and diffable, and a voice becomes a
--- table of numbers an agent can tune and re-measure instead of a binary it
--- can only replace. Costs ~40ms and ~1.5MB at startup.
---
--- app/ layer: love.audio and love.sound live here and nowhere else. Every
--- entry point no-ops when the audio modules are absent, so the headless test
--- runner (which disables them) never has to know this file exists.

local C = require("core.constants")

local A = {}

local RATE      = 44100
local VOICES    = 6      -- clones per sound; beyond this, overlaps steal
local available = false

---------------------------------------------------------------------------
-- Synthesis
---------------------------------------------------------------------------

--- Exponential decay. `curve` > 1 tightens the tail, which is what makes a
--- contact read as a click rather than a beep.
local function decay_at(t, dur, curve)
  local x = 1 - t / dur
  if x <= 0 then return 0 end
  return x ^ curve
end

--- A few milliseconds of fade-in. Without it every sample starts on a
--- discontinuity and the speaker clicks on its own.
local function attack_at(t, attack)
  if attack <= 0 or t >= attack then return 1 end
  return t / attack
end

--- A local pseudo-random source for the noise components.
---
--- The kit has to sound the same every run or a voice is not a constant, and
--- the obvious way to get that -- math.randomseed(4242) before synthesis --
--- reseeds the GLOBAL generator from a presentation module. Everything that
--- later calls math.random inherits it, silently: app/fx.lua's spark angles
--- and screen shake do exactly that today, and a future caller would too.
---
--- So: a tiny local LCG instead. Same numbers every run, no global state
--- touched, and nothing else in the program has to know this module exists.
local function noise_source(seed)
  local state = seed
  return function()
    state = (1103515245 * state + 12345) % 2147483648
    return state / 2147483648
  end
end

local function osc(wave, phase)
  if wave == "sine" then
    return math.sin(phase * 2 * math.pi)
  elseif wave == "square" then
    return (phase % 1) < 0.5 and 1 or -1
  elseif wave == "saw" then
    return 2 * (phase % 1) - 1
  elseif wave == "tri" then
    local p = (phase % 1)
    return p < 0.5 and (4 * p - 1) or (3 - 4 * p)
  end
  return 0
end

--- One-pole lowpass, swept. Cheap, and it is what turns white noise into
--- something with a body -- a whoosh rather than a hiss.
local function lowpass(state, x, cutoff)
  local a = 1 - math.exp(-2 * math.pi * cutoff / RATE)
  state.y = state.y + a * (x - state.y)
  return state.y
end

--- Render one voice spec to a SoundData.
--- @param v table dur, f0, f1, wave, noise, cut0, cut1, gain, attack, curve
local function render(v)
  local n    = math.max(2, math.floor(RATE * v.dur))
  local data = love.sound.newSoundData(n, RATE, 16, 1)
  local lp    = { y = 0 }
  local rand  = noise_source(4242)
  local phase = 0
  for i = 0, n - 1 do
    local t  = i / RATE
    local u  = t / v.dur
    local f  = v.f0 + (v.f1 - v.f0) * u
    phase    = phase + f / RATE

    local tone  = osc(v.wave or "sine", phase) * (1 - (v.noise or 0))
    local grain = 0
    if (v.noise or 0) > 0 then
      local cut = (v.cut0 or 4000) + ((v.cut1 or v.cut0 or 4000) - (v.cut0 or 4000)) * u
      grain = lowpass(lp, rand() * 2 - 1, cut) * v.noise
    end

    local amp = decay_at(t, v.dur, v.curve or 3) * attack_at(t, v.attack or 0.002)
    local s   = (tone + grain) * amp * (v.gain or 0.6)
    data:setSample(i, math.max(-1, math.min(1, s)))
  end
  return data
end

---------------------------------------------------------------------------
-- The kit
---------------------------------------------------------------------------

--- Voices, as data. Tune these numbers, not the code above.
local KIT = {
  -- Ball on wall. Very short, dull, and quiet: this is the most frequent
  -- sound in the game by an order of magnitude (measured 7.2 impacts/s), so
  -- it has to sit under everything else or it becomes the whole mix.
  wall    = { dur = 0.045, f0 = 210, f1 = 120, wave = "tri",
              noise = 0.55, cut0 = 2600, cut1 = 700, gain = 0.30, curve = 5 },
  -- Bumpers are board A's whole character. Bright, resonant, cheerful.
  bumper  = { dur = 0.20,  f0 = 720, f1 = 240, wave = "square",
              noise = 0.12, cut0 = 5000, cut1 = 1200, gain = 0.45, curve = 2.4 },
  -- The flipper is the player's own hand. Woody and low, never musical.
  flipper = { dur = 0.075, f0 = 165, f1 = 78,  wave = "tri",
              noise = 0.40, cut0 = 1800, cut1 = 380, gain = 0.42, curve = 4 },
  -- Devices are metal. The ball striking one should say "you hit your
  -- partner's thing", which wants a different material from a wall.
  gate    = { dur = 0.16,  f0 = 900, f1 = 520, wave = "sine",
              noise = 0.22, cut0 = 6000, cut1 = 2200, gain = 0.38, curve = 3 },
  post    = { dur = 0.14,  f0 = 430, f1 = 250, wave = "sine",
              noise = 0.28, cut0 = 3400, cut1 = 900, gain = 0.40, curve = 3 },

  -- §6.1 wants operator state readable across a room. The device is already
  -- visibly travelling for 260-300ms; this is the same information for the
  -- player who is looking at the ball instead.
  arm     = { dur = 0.26,  f0 = 300, f1 = 620, wave = "saw",
              noise = 0.30, cut0 = 900, cut1 = 2600, gain = 0.22, curve = 1.2 },
  disarm  = { dur = 0.24,  f0 = 620, f1 = 280, wave = "saw",
              noise = 0.30, cut0 = 2600, cut1 = 800, gain = 0.20, curve = 1.2 },

  -- §5/§10: the pass. Departure is a rising whoosh, arrival lands on a note.
  -- These two bracket the 800ms of transit and are the beat the design asks
  -- for -- the sender hears the ball go, the receiver hears it coming.
  depart  = { dur = 0.55,  f0 = 150, f1 = 900, wave = "sine",
              noise = 0.80, cut0 = 500, cut1 = 5200, gain = 0.40, curve = 1.1 },
  arrive  = { dur = 0.30,  f0 = 880, f1 = 590, wave = "tri",
              noise = 0.10, cut0 = 4000, cut1 = 1500, gain = 0.45, curve = 2 },
  -- Failure. Descending, and the only long low sound in the kit.
  drain   = { dur = 0.70,  f0 = 320, f1 = 60,  wave = "tri",
              noise = 0.20, cut0 = 1600, cut1 = 260, gain = 0.50, curve = 1.6 },
  -- §8 purgatory. Urgent and unpleasant on purpose: this is the one moment
  -- the game asks a player to do something RIGHT NOW, and §10 wants that
  -- legible without looking.
  peril   = { dur = 0.50,  f0 = 240, f1 = 150, wave = "square",
              noise = 0.18, cut0 = 1400, cut1 = 500, gain = 0.42, curve = 0.9 },
  -- And the payoff. The only rising major interval in the kit, so a rescue
  -- cannot be mistaken for anything else that happens.
  rescue  = { dur = 0.55,  f0 = 420, f1 = 1180, wave = "tri",
              noise = 0.08, cut0 = 3000, cut1 = 6000, gain = 0.55, curve = 1.5 },

  serve   = { dur = 0.18,  f0 = 400, f1 = 760, wave = "tri",
              noise = 0.10, cut0 = 3000, cut1 = 5000, gain = 0.35, curve = 2 },
}

---------------------------------------------------------------------------
-- Source pool
---------------------------------------------------------------------------

local pool = {}     -- name -> { sources, next }

local function build_pool(name, spec)
  local src = love.audio.newSource(render(spec), "static")
  local set = { src }
  for _ = 2, VOICES do set[#set+1] = src:clone() end
  pool[name] = { sources = set, next = 1 }
end

--- Round-robin so a burst of impacts overlaps instead of cutting itself off.
local function play(name, volume, pitch)
  if not available then return end
  local p = pool[name]
  if not p then return end
  local src = p.sources[p.next]
  p.next = p.next % #p.sources + 1
  src:stop()
  src:setVolume(math.max(0, math.min(1, volume or 1)))
  src:setPitch(math.max(0.35, math.min(3.0, pitch or 1)))
  src:play()
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

--- Safe to call when the audio modules are disabled; everything then no-ops.
function A.load()
  if not (love.audio and love.sound) then return false end
  for name, spec in pairs(KIT) do build_pool(name, spec) end
  available = true
  return true
end

function A.available() return available end

--- Impact loudness. Impulses span three orders of magnitude (0.3 to 227
--- measured), so a linear map would make every ordinary contact inaudible
--- next to one bumper hit. Log-scaled against the floor instead, which is
--- roughly how loudness is perceived anyway.
local function impact_gain(impulse)
  local ratio = impulse / C.IMPACT_MIN_IMPULSE
  return math.max(0.12, math.min(1, 0.16 + 0.22 * math.log(ratio)))
end

--- Harder hits ring slightly higher, the way a struck object does.
local function impact_pitch(impulse)
  local ratio = impulse / C.IMPACT_MIN_IMPULSE
  return math.max(0.82, math.min(1.45, 0.86 + 0.055 * math.log(ratio)))
end

--- §9: relay heat rides on every voice, so the table audibly tightens as the
--- rally gets more valuable and more likely to end. Capped, or a long rally
--- ends up in dog-whistle territory.
local function heat_of(state)
  local relay = (state and state.stats and state.stats.relay) or 0
  return 1 + 0.035 * math.min(12, relay)
end

local IMPACT_VOICE = {
  wall = "wall", bumper = "bumper", flipper = "flipper",
  gate = "gate", post = "post", sling = "bumper", guard = "bumper",
  -- The solid part of a ramp is a wall, and has to sound like one: it is the
  -- structure a missed ramp shot comes back off.
  rampwall = "wall",
}

--- Drain one frame's worth of events from sim/ into the speakers.
--- §9's relay heat rides on top: a hotter rally is pitched up, so the table
--- audibly tightens as the risk rises.
---@param events table[] from Match:drain_events()
---@param state table core match state, for relay heat
function A.consume(events, state)
  if not available then return end
  local heat = heat_of(state)
  for _, ev in ipairs(events) do
    if ev.kind == "impact" then
      local voice = IMPACT_VOICE[ev.what]
      if voice then
        play(voice, impact_gain(ev.impulse), impact_pitch(ev.impulse) * heat)
      end
    elseif ev.kind == "award" and ev.value >= 2500 then
      play("rescue", 0.8, 1.2)
    elseif ev.kind == "award" and (ev.what == "rollover" or ev.what == "ramp") then
      play("arrive", 0.45, ev.what == "ramp" and 1.3 or 1.7)
    elseif ev.kind == "tube" then
      play("depart", 0.85, heat)
    elseif ev.kind == "drain" then
      -- Not the drain sound yet: the ball is in purgatory and might come
      -- back. Sounding the loss here would tell the players it is over while
      -- they still have 1.9 seconds to prove otherwise.
      play("peril", 0.9, 1)
    elseif ev.kind == "rescue" then
      play("rescue", 1.0, 1)
    end
  end
end

---------------------------------------------------------------------------
-- Transitions
---------------------------------------------------------------------------
-- Two things worth hearing are not contacts and so cannot come through the
-- event feed: the match changing phase, and an operator commanding a device.
-- Both are edges in core state, so they are found by diffing it frame to
-- frame. Keeping that here rather than in main.lua means the whole audio
-- surface is one call.

local last = { phase = nil, devices = {} }

local function phase_edges(s, heat)
  if last.phase ~= s.phase then
    if s.phase == "play" and last.phase == "transit" then
      play("arrive", 0.9, heat)
    elseif s.phase == "play" and last.phase == "serve" then
      play("serve", 0.7, 1)
    elseif s.phase == "drain" and last.phase == "purgatory" then
      -- Now it is over. The loss lands when the window closes, not when the
      -- ball crossed the line.
      play("drain", 0.9, 1)
    end
    last.phase = s.phase
  end
end

--- §6.1: fired on the commanded edge, not on arrival. The point is to
--- announce the 300ms of travel *while it is happening*, so the flipper
--- player can react to what their partner is doing rather than to what they
--- have already done.
local function device_edges(s)
  for bid, board in pairs(s.boards) do
    local seen = last.devices[bid]
    if not seen then seen = {}; last.devices[bid] = seen end
    for did, dev in pairs(board.devices) do
      if seen[did] ~= dev.commanded then
        -- Only the active board is audible: the dormant one is a side panel,
        -- and sounding it would announce events nobody is looking at.
        if seen[did] ~= nil and bid == s.active then
          play(dev.commanded and "arm" or "disarm",
               dev.commanded and 0.55 or 0.45, 1)
        end
        seen[did] = dev.commanded
      end
    end
  end
end

--- The whole audio surface: one call per frame from main.lua.
--- The event list is drained once by the caller and shared with app/fx.lua,
--- so a hit sounds and looks like one hit rather than two systems each
--- draining half the feed.
---@param match table sim.match
---@param events table[] this frame's events
function A.update(match, events)
  if not available then return end
  local s = match.state
  A.consume(events, s)
  phase_edges(s, heat_of(s))
  device_edges(s)
end

return A
