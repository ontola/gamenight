--- Visual feedback: impact rings, bumper flashes, sparks, ball trail, shake.
---
--- Fed by the same event stream as app/audio.lua (see sim/board.lua), so a hit
--- sounds and looks like one hit rather than two systems guessing separately.
--- Owns no gameplay state and never writes back: everything here could be
--- deleted and the simulation would be identical (§5).
---
--- app/ layer. Draws in *board space*, inside the transform app/render.lua has
--- already pushed, so effects scale and move with their board for free -- which
--- is what keeps them attached during the transit pull-back.

local C = require("core.constants")

local FX = {}

-- Caps. A frame can produce a burst of contacts and nothing culls on its own.
local MAX_RINGS, MAX_SPARKS, TRAIL_LEN = 48, 160, 22
local MAX_AWARDS = 24

local rings, sparks, shake = {}, {}, { amp = 0 }
local awards = {}                     -- floating score numbers
-- §7: "the dormant board is shown as a small panel that lights up when
-- cross-board state changes, so you always know what you've built up over
-- there". Diffed here rather than signalled, because the change can come from
-- either board's events and the panel only cares that it happened.
local panel = { a = { flash = 0 }, b = { flash = 0 } }
local award_font
local trail  = { a = {}, b = {} }
-- board -> "<kind>:<index>" -> remaining seconds. Keyed by kind as well as
-- index because bumper 2 and target 2 are different objects in the same board.
local pulses = { a = {}, b = {} }

---------------------------------------------------------------------------
-- Impact strength
---------------------------------------------------------------------------

--- Impulses span three orders of magnitude (0.3 to 227 measured), so every
--- size here is log-scaled against the floor for the same reason the audio
--- gains are: linear scaling makes one bumper hit dwarf everything else.
--- Returns 0..1.
local function strength(impulse)
  local ratio = impulse / C.IMPACT_MIN_IMPULSE
  return math.max(0, math.min(1, math.log(ratio) / math.log(400)))
end

---------------------------------------------------------------------------
-- Emitters
---------------------------------------------------------------------------

local function add_ring(board, x, y, s, r, g, b)
  if #rings >= MAX_RINGS then table.remove(rings, 1) end
  rings[#rings+1] = {
    board = board, x = x, y = y, t = 0,
    life = 0.16 + 0.22 * s,
    r0 = C.BALL_RADIUS * 0.8, r1 = C.BALL_RADIUS * (1.6 + 5.0 * s),
    cr = r, cg = g, cb = b,
  }
end

local function add_sparks(board, x, y, n, speed, r, g, b)
  for _ = 1, n do
    if #sparks >= MAX_SPARKS then table.remove(sparks, 1) end
    local a = math.random() * math.pi * 2
    local v = speed * (0.35 + 0.65 * math.random())
    sparks[#sparks+1] = {
      board = board, x = x, y = y,
      vx = math.cos(a) * v, vy = math.sin(a) * v,
      t = 0, life = 0.22 + 0.35 * math.random(),
      cr = r, cg = g, cb = b,
    }
  end
end

--- A score, floating up from where it was earned. §9's whole point is that
--- the same shot is worth more later, and a number that only ever appears in
--- the corner of the HUD cannot show that -- you have to see 50 become 500 at
--- the bumper you just hit.
local function add_award(board, x, y, value)
  if #awards >= MAX_AWARDS then table.remove(awards, 1) end
  awards[#awards+1] = {
    board = board, x = x, y = y, value = value, t = 0, life = 1.15,
  }
end

--- Screen shake. Deliberately small and rare: a pinball cabinet does not
--- wobble when the ball touches a wall, and constant shake reads as a bug.
--- Only a drain and a genuinely hard hit earn any.
local function add_shake(amount)
  shake.amp = math.min(11, shake.amp + amount)
end

--- Which bumper did this contact land on? The event carries the contact point
--- rather than the fixture, so match by proximity -- close enough is exact
--- here, because bumpers are never within a ball's width of each other (the
--- geometry gate's wedge check guarantees it).
local function bumper_at(def, x, y)
  for i, b in ipairs(def.bumpers or {}) do
    local dx, dy = x - b.x, y - b.y
    if dx * dx + dy * dy <= (b.r + C.BALL_RADIUS * 2.2) ^ 2 then return i end
  end
  return nil
end

---------------------------------------------------------------------------
-- Events in
---------------------------------------------------------------------------

local THEME_HIT = {
  wall    = { 1.00, 0.85, 0.55 },
  flipper = { 0.85, 0.92, 1.00 },
  gate    = { 1.00, 0.72, 0.24 },
  post    = { 1.00, 0.60, 0.35 },
  bumper  = { 1.00, 0.90, 0.35 },
  sling   = { 1.00, 0.55, 0.80 },
  guard   = { 0.55, 0.95, 1.00 },
  rampwall = { 1.00, 0.78, 0.45 },
}

local function on_impact(ev, defs)
  local s = strength(ev.impulse)
  local c = THEME_HIT[ev.what]
  if not c then return end

  if ev.what == "bumper" then
    -- Board A's character. Worth more than a ring: light the whole thing up.
    local i = bumper_at(defs[ev.board], ev.x, ev.y)
    if i then pulses[ev.board]["bumper:" .. i] = 0.30 end
    add_sparks(ev.board, ev.x, ev.y, 6 + math.floor(10 * s), 190, c[1], c[2], c[3])
  elseif s > 0.30 then
    -- Below this a contact is a tick, not an event, and drawing it for every
    -- one of the ~7 impacts a second turns the board into television static.
    add_sparks(ev.board, ev.x, ev.y, 1 + math.floor(5 * s), 130, c[1], c[2], c[3])
  end

  add_ring(ev.board, ev.x, ev.y, s, c[1], c[2], c[3])
  if s > 0.62 then add_shake(3.2 * (s - 0.62) / 0.38) end
end

---------------------------------------------------------------------------
-- Update
---------------------------------------------------------------------------

local function advance_list(list, dt, mover)
  for i = #list, 1, -1 do
    local e = list[i]
    e.t = e.t + dt
    if e.t >= e.life then
      table.remove(list, i)
    elseif mover then
      mover(e, dt)
    end
  end
end

local function move_spark(e, dt)
  e.x = e.x + e.vx * dt
  e.y = e.y + e.vy * dt
  e.vy = e.vy + C.GRAVITY_PX * 0.45 * dt      -- sparks fall, but lazily
  e.vx = e.vx * (1 - 2.2 * dt)
end

--- The trail is sampled per *frame*, not per sim step: it is a picture of
--- where the ball has been on screen, and 240 samples a second would be a
--- solid line.
local function sample_trail(match)
  for id, board_trail in pairs(trail) do
    local snap = match.cur[id]
    if snap and snap.ball and match.state.phase == "play" then
      board_trail[#board_trail+1] = { x = snap.ball.x, y = snap.ball.y }
      while #board_trail > TRAIL_LEN do table.remove(board_trail, 1) end
    else
      -- Ball gone (transit, drain): let the tail run out rather than blink.
      if #board_trail > 0 then table.remove(board_trail, 1) end
    end
  end
end

local function watch_cross_board(match, dt)
  local boards = match.state.boards or {}
  for id, p in pairs(panel) do
    local b = boards[id]
    if b then
      local sum = (b.lit.bumpers or 0) * 1000
      for _, v in pairs(b.meters) do sum = sum + v end
      if p.seen and sum ~= p.seen then p.flash = 1 end
      p.seen = sum
    end
    p.flash = math.max(0, p.flash - dt / 0.9)
  end
end

local function advance_pulses(dt)
  for _, board_pulses in pairs(pulses) do
    for i, t in pairs(board_pulses) do
      local left = t - dt
      board_pulses[i] = (left > 0) and left or nil
    end
  end
end

--- One frame.
---@param match table sim.match
---@param events table[] already drained by main.lua and shared with audio
---@param dt number real seconds
function FX.update(match, events, dt)
  for _, ev in ipairs(events) do
    if ev.kind == "impact" then
      on_impact(ev, match.defs)
    elseif ev.kind == "drain" then
      -- The only large shake in the game. Losing the ball should land.
      add_shake(9)
      local def = match.defs[ev.board]
      add_sparks(ev.board, def.size.w / 2, def.drain_y, 26, 240, 1.0, 0.35, 0.30)
    elseif ev.kind == "tube" then
      add_shake(2.2)
    elseif ev.kind == "target" then
      pulses[ev.board]["target:" .. ev.index] = 0.30
    elseif ev.kind == "sling" then
      pulses[ev.board]["sling:" .. ev.index] = 0.30
    elseif ev.kind == "guard" then
      -- Keyed by side rather than index: the guards are "left" and "right",
      -- which is also how the two players talk about them.
      pulses[ev.board]["guard:" .. ev.side] = 0.30
    elseif ev.kind == "award" then
      add_award(ev.board, ev.x, ev.y, ev.value)
    end
  end

  advance_list(rings, dt, nil)
  advance_list(awards, dt, function(e, d) e.y = e.y - 26 * d end)
  advance_list(sparks, dt, move_spark)
  advance_pulses(dt)
  watch_cross_board(match, dt)
  sample_trail(match)

  shake.amp = shake.amp * math.exp(-9 * dt)
  if shake.amp < 0.05 then shake.amp = 0 end
end

--- The font for floating scores. Injected by render.lua, which owns every
--- font in the game, so fx never creates a graphics resource of its own and
--- stays loadable in the bare interpreter.
function FX.set_font(f) award_font = f end

--- Counts, for tests and the F1 readout. The caps above exist so a long
--- session cannot grow these without bound, and a cap nobody can observe is a
--- cap nobody can test.
---@return table
function FX.stats()
  return {
    rings = #rings, sparks = #sparks, awards = #awards,
    trail_a = #trail.a, trail_b = #trail.b,
    shake = shake.amp,
  }
end

--- How brightly a board's panel should be flagging a change, 0..1.
function FX.panel_flash(board)
  return panel[board] and panel[board].flash or 0
end

function FX.reset()
  rings, sparks, awards = {}, {}, {}
  panel = { a = { flash = 0 }, b = { flash = 0 } }
  trail  = { a = {}, b = {} }
  pulses = { a = {}, b = {} }
  shake.amp = 0
end

---------------------------------------------------------------------------
-- Draw
---------------------------------------------------------------------------

--- Screen-space offset for the whole frame. Applied once by render.draw.
function FX.shake_offset()
  if shake.amp <= 0 then return 0, 0 end
  return (math.random() * 2 - 1) * shake.amp, (math.random() * 2 - 1) * shake.amp
end

--- How lit a struck thing is right now, 0..1. render.lua asks per object.
---@param board string
---@param kind "bumper"|"sling"|"guard"|"target"
---@param index integer
---@return number
function FX.hit_pulse(board, kind, index)
  local t = pulses[board] and pulses[board][kind .. ":" .. index]
  return t and (t / 0.30) or 0
end

--- Everything that lives in board space. Called by render.lua from inside the
--- board's transform, so coordinates here are board pixels.
---@param board_id string
---@param heat number 0..1 rally heat, tints the trail
function FX.draw_board(board_id, heat)
  local lg = love.graphics

  -- Trail. Oldest first so newer samples draw over older ones.
  local pts = trail[board_id]
  local n = #pts
  for i = 1, n do
    local u = i / n                        -- 1 = newest
    local r = C.BALL_RADIUS * (0.22 + 0.72 * u)
    lg.setColor(1, 0.92 - 0.35 * heat, 0.75 - 0.55 * heat, 0.34 * u * u)
    lg.circle("fill", pts[i].x, pts[i].y, r)
  end

  for _, e in ipairs(rings) do
    if e.board == board_id then
      local u = e.t / e.life
      lg.setColor(e.cr, e.cg, e.cb, (1 - u) * 0.75)
      lg.setLineWidth(1 + 2.2 * (1 - u))
      lg.circle("line", e.x, e.y, e.r0 + (e.r1 - e.r0) * u)
    end
  end

  for _, e in ipairs(sparks) do
    if e.board == board_id then
      local u = e.t / e.life
      lg.setColor(e.cr, e.cg, e.cb, (1 - u) * 0.9)
      lg.circle("fill", e.x, e.y, 1.6 * (1 - u) + 0.5)
    end
  end

  if award_font then
    local prev = lg.getFont()
    lg.setFont(award_font)
    for _, e in ipairs(awards) do
      if e.board == board_id then
        local u = e.t / e.life
        local text = tostring(e.value)
        -- Fades late rather than linearly, so the number is readable for most
        -- of its life instead of being half-transparent the whole way up.
        lg.setColor(1, 0.95, 0.6, math.min(1, 2.4 * (1 - u)))
        lg.print(text, e.x - award_font:getWidth(text) / 2, e.y)
      end
    end
    lg.setFont(prev)
  end
end

return FX
