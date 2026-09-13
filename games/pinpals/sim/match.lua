--- Owns both board worlds, the fixed-step accumulator, and the wiring between
--- core/ (rules) and sim/ (physics).
---
--- love.physics only.

local C     = require("core.constants")
local core  = require("core.state")
local Board = require("sim.board")

local Match = {}
Match.__index = Match

---@param boards table<string, table> validated definitions
---@param seed number|nil §5.1: a match replays from its intent stream plus a
---  seed, and the serve jitter is the only thing that draws on it. Omitted,
---  the match runs on the fixed seed -- so every gate, probe and screenshot
---  is the same match twice, and only a played session asks for a fresh one.
function Match.new(boards, seed)
  local self = setmetatable({}, Match)
  self.defs   = boards
  self.seed   = seed or C.RNG_SEED
  -- The match's own generator hands each board a seed and, on a restart, the
  -- next match its seed. Boards draw separately so a serve on A cannot shift
  -- the sequence B was going to get.
  self.rng    = love.math.newRandomGenerator(self.seed)
  self.state  = core.new(boards)
  self.boards = { a = Board.new(boards.a, self.rng:random(1, 2 ^ 31 - 1)),
                  b = Board.new(boards.b, self.rng:random(1, 2 ^ 31 - 1)) }
  self.acc    = 0
  self.alpha  = 0
  self.pending = {}
  -- Presentation feed: impacts and flow events for app/ to drain each frame.
  -- Bounded, because a headless run drains nothing and would otherwise grow
  -- one table per contact for the length of the test.
  self.feed    = {}
  self.prev = { a = self:_snapshot("a"), b = self:_snapshot("b") }
  self.cur  = { a = self.prev.a, b = self.prev.b }
  return self
end

--- Queue intents for the next fixed step (§5.1). Local play delivers them with
--- zero delay; a socket would deliver them here too.
function Match:push(intent)
  self.pending[#self.pending+1] = intent
end

function Match:_snapshot(id)
  local b = self.boards[id]
  local snap = { flippers = {}, devices = {}, guards = {} }
  local x, y = b:ball_pos()
  -- z is how high the ball is riding: zero on the playfield, and up to a
  -- ramp's crown height on one. app/ draws the shadow from it; core/ never
  -- sees it, because no rule on either board cares how high the ball is.
  if x then snap.ball = { x = x, y = y, z = b:ball_z() } end
  for side, f in pairs(b.flippers) do snap.flippers[side] = f.body:getAngle() end
  for did, dev in pairs(b.devices) do
    if dev.kind == "gate" then
      snap.devices[did] = { angle = dev.body:getAngle(), p = b:device_progress(did) }
    else
      local dx, dy = dev.body:getPosition()
      snap.devices[did] = { x = dx, y = dy, p = b:device_progress(did) }
    end
  end
  for side, g in pairs(b.guards) do
    local gx, gy = g.body:getPosition()
    snap.guards[side] = { x = gx, y = gy, p = b:guard_progress(side) }
  end
  return snap
end

function Match:_tick()
  local s = self.state

  core.apply_intents(s, self.pending)
  self.pending = {}

  for _, cmd in ipairs(core.update(s)) do
    if cmd.kind == "serve" then
      self.boards[cmd.board]:serve()
    elseif cmd.kind == "arrive" then
      self.boards[cmd.board]:arrive(cmd.speed, cmd.aim)
    end
  end

  -- Step both worlds. The dormant board has no ball but keeps simulating, so
  -- its devices hold and animate the state the operator left them in (§7).
  -- Rules see flow events only. Impacts are presentation and never reach
  -- core/, which has no opinion about how hard the ball hit something.
  local events = {}
  for id, b in pairs(self.boards) do
    local has_ball = b.ball ~= nil
    for _, ev in ipairs(b:step(s.boards[id], has_ball)) do
      if ev.kind ~= "impact" then events[#events+1] = ev end
      self:_feed(ev)
    end
  end

  core.consume(s, events)

  -- A score award is a rule outcome, but app/ wants to float the number where
  -- it happened. Routed through the feed rather than polled off the state,
  -- because several fixed steps run per rendered frame and a poll would see
  -- only the last one -- a hot rally would silently drop most of its awards.
  -- §8: a rescue is a one-frame signal like an award, and for the same
  -- reason it goes on the feed rather than being polled -- several fixed
  -- steps run per rendered frame, and a poll would miss it outright.
  if s.rescue then
    self:_feed({ kind = "rescue", board = s.active, spent = s.rescue.spent })
  end

  local aw = s.last_award
  if aw then
    local def = self.defs[aw.board]
    self:_feed({
      kind = "award", board = aw.board, value = aw.value, what = aw.kind,
      -- A pass has no contact point: it is awarded for the crossing itself,
      -- so it floats where the ball is about to land.
      x = aw.x or def.entry.x, y = aw.y or def.entry.y,
    })
  end

  if s.phase == "transit" and s.transit then
    self.boards[s.transit.from]:despawn()
  elseif s.phase == "purgatory" or s.phase == "drain" then
    -- Purgatory despawns too, not just drain: the ball is already past the
    -- drain line, so leaving it in the world means it re-emits a drain event
    -- every step for the whole window while falling off the bottom of the
    -- playfield. The ball is gone from the table; whether it comes back is
    -- core's decision, not physics'.
    for _, b in pairs(self.boards) do b:despawn() end
  end
end

local FEED_MAX = 96

--- Append to the presentation feed, dropping the oldest once full. A frame
--- that renders drains this; a headless run never does, which is exactly why
--- it is capped.
function Match:_feed(ev)
  local f = self.feed
  f[#f+1] = ev
  if #f > FEED_MAX then table.remove(f, 1) end
end

--- Hand app/ everything that happened since the last call, and clear.
---@return table[] events
function Match:drain_events()
  local f = self.feed
  self.feed = {}
  return f
end

--- §4.1: accumulate real time, consume it in fixed chunks. The simulation
--- never sees a variable dt.
function Match:advance(real_dt)
  self.acc = self.acc + math.min(real_dt, 0.25)
  local steps = 0
  while self.acc >= C.FIXED_DT and steps < C.MAX_CATCHUP do
    self.prev.a, self.prev.b = self.cur.a, self.cur.b
    self:_tick()
    self.cur.a, self.cur.b = self:_snapshot("a"), self:_snapshot("b")
    self.acc = self.acc - C.FIXED_DT
    steps = steps + 1
  end
  if steps == C.MAX_CATCHUP then self.acc = 0 end   -- we are behind; drop it
  self.alpha = self.acc / C.FIXED_DT
  return steps
end

--- Run n fixed steps with no wall-clock involved. For headless tests.
function Match:run(n)
  for _ = 1, n do
    self.prev.a, self.prev.b = self.cur.a, self.cur.b
    self:_tick()
    self.cur.a, self.cur.b = self:_snapshot("a"), self:_snapshot("b")
  end
end

return Match
