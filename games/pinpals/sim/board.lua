--- Builds one Box2D world from a declarative board definition (§5.3) and
--- exposes the handful of operations core/ can command.
---
--- love.physics ONLY. No love.graphics / love.window / love.keyboard in this
--- file or anywhere else in sim/ -- that boundary is what keeps the headless
--- test harness working (§5, §7).

local C    = require("core.constants")
local geo  = require("core.geometry")
local ramp = require("core.ramp")

local Board = {}
Board.__index = Board

-- Collision layers. A ramp runs ABOVE the playfield, so "over" and "under"
-- have to be a real physical distinction rather than a drawing trick: the
-- ball belongs to one of two layers at any moment and simply does not see the
-- other one's geometry.
--
-- FIELD keeps BALL *and* FIELD in its mask so nothing about how the existing
-- furniture interacts changes -- the raised post and the left flipper tip
-- overlap by design, and dropping FIELD from that mask would silently let
-- them pass through each other.
local CAT_BALL  = 0x0001
local CAT_FIELD = 0x0002
local CAT_RAMP  = 0x0004

local function ud(fixture, kind, id)
  fixture:setUserData({ kind = kind, id = id })
  fixture:setFilterData(CAT_FIELD, CAT_FIELD + CAT_BALL, 0)
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

local function build_walls(self, def)
  for _, poly in ipairs(def.walls) do
    for i = 1, #poly - 3, 2 do
      local shape = love.physics.newEdgeShape(poly[i], poly[i+1], poly[i+2], poly[i+3])
      local f = love.physics.newFixture(self.ground, shape, 0)
      f:setRestitution(0.22)
      f:setFriction(0.10)
      ud(f, "wall")
    end
  end
end

local function build_bumpers(self, def)
  for i, b in ipairs(def.bumpers or {}) do
    local f = love.physics.newFixture(self.ground, love.physics.newCircleShape(b.x, b.y, b.r), 0)
    f:setRestitution(b.restitution or 1.2)
    f:setFriction(0.02)
    ud(f, "bumper", i)
  end
end

--- Slingshots. Static like a wall, energetic like a bumper: the whole triangle
--- carries the restitution, because the ball only ever meets the face that
--- points into the playfield -- the other two sides are buried against the
--- inlane and the lane divider.
---
--- design.md §6.1 forbids impulses, and this is not one: the rule is about
--- what the OPERATOR can do, and a slingshot is table furniture nobody fires.
--- It is built exactly the way bumpers already are, so it inherits their
--- measured no-debounce-needed behaviour rather than inventing new machinery.
local function build_slingshots(self, def)
  for i, sl in ipairs(def.slingshots or {}) do
    local f = love.physics.newFixture(self.ground, love.physics.newPolygonShape(sl.p), 0)
    f:setRestitution(sl.kick or 1.35)
    f:setFriction(0.04)
    ud(f, "sling", i)
  end
end

--- Standup targets. Static like walls, but they report being hit, which is
--- what makes them content rather than scenery. Corners come from core/ so
--- the fixture, the geometry checks and the drawing cannot disagree.
local function build_targets(self, def)
  for i, t in ipairs(def.targets or {}) do
    local shape = love.physics.newPolygonShape(geo.rect_corners(t))
    local f = love.physics.newFixture(self.ground, shape, 0)
    f:setRestitution(t.restitution or 0.45)
    f:setFriction(0.10)
    ud(f, "target", i)
  end
end

local function build_rollovers(self, def)
  for i, lane in ipairs(def.rollovers or {}) do
    local shape = love.physics.newRectangleShape(lane.x, lane.y, lane.w, lane.h)
    local f = love.physics.newFixture(self.ground, shape, 0)
    f:setSensor(true)
    ud(f, "rollover", i)
  end
end

local function build_mouth(self, def)
  local m = def.tube.mouth
  local f = love.physics.newFixture(self.ground, love.physics.newCircleShape(m.x, m.y, m.r), 0)
  f:setSensor(true)
  ud(f, "mouth")
end

local function build_flipper(self, _def, spec)
  local left  = spec.side == "left"
  local sign  = left and 1 or -1
  local rest  = left and  C.FLIPPER_REST or -C.FLIPPER_REST
  local up    = left and  C.FLIPPER_UP   or -C.FLIPPER_UP

  -- Created at angle 0 on purpose: Box2D takes the joint's reference angle
  -- from the bodies' angles at construction, so building the flipper already
  -- rotated would make the limits below mean something else entirely.
  local body = love.physics.newBody(self.world, spec.x, spec.y, "dynamic")
  body:setBullet(true)
  local shape = love.physics.newRectangleShape(sign * C.FLIPPER_LEN / 2, 0,
                                               C.FLIPPER_LEN, C.FLIPPER_THICK)
  local f = love.physics.newFixture(body, shape, C.FLIPPER_DENSITY)
  f:setRestitution(0.06)
  f:setFriction(0.35)
  ud(f, "flipper", spec.side)

  local joint = love.physics.newRevoluteJoint(self.ground, body, spec.x, spec.y, false)
  joint:setLimitsEnabled(true)
  joint:setLimits(math.min(rest, up), math.max(rest, up))
  joint:setMotorEnabled(true)
  joint:setMaxMotorTorque(C.FLIPPER_TORQUE)
  joint:setMotorSpeed(0)
  body:setAngle(rest)                    -- drop it into the rest position

  self.flippers[spec.side] = {
    body = body, joint = joint, rest = rest, up = up,
    dir_up = (up > rest) and 1 or -1,
  }
end

local function build_devices(self, def)
  for _, d in ipairs(def.devices) do
    if d.kind == "gate" then
      local body = love.physics.newBody(self.world, d.pivot.x, d.pivot.y, "kinematic")
      body:setAngle(d.closed)
      local shape = love.physics.newRectangleShape(d.length / 2, 0, d.length, C.GATE_THICK)
      local f = love.physics.newFixture(body, shape, 1)
      f:setRestitution(0.18)
      ud(f, "gate", d.id)
      self.devices[d.id] = {
        def = d, kind = "gate", body = body,
        rate = math.abs(d.open - d.closed) / d.travel,
      }
    elseif d.kind == "paddle" then
      local body = love.physics.newBody(self.world, d.down.x, d.down.y, "kinematic")
      local shape = love.physics.newRectangleShape(0, 0, d.w, d.h)
      local f = love.physics.newFixture(body, shape, 1)
      f:setRestitution(0.30)
      ud(f, "post", d.id)
      local dx, dy = d.up.x - d.down.x, d.up.y - d.down.y
      self.devices[d.id] = {
        def = d, kind = "paddle", body = body,
        rate = math.sqrt(dx * dx + dy * dy) / d.travel,
      }
    end
  end
end

--- §6.2 The outlane guards. One bar per side, and only ever one of them
--- deployed: WHICH one is a rule, so it lives in core/ state, and this file
--- only drives the two bodies toward whatever core/ decided.
---
--- Kinematic and velocity-driven like the post, energetic like a bumper. The
--- kick is not the impulse §6.1 forbids -- the operator moves a bar, and the
--- bar is either across the lane or it is not, which is exactly the
--- persistent state that rule asks for. What the ball does on contact is the
--- table's business, the same way a slingshot's is.
---
--- Built at the home `start` names rather than always retracted, so a fresh
--- board is not spending its first 300ms sliding a guard into place while the
--- ball is already loose.
local function build_guards(self, def)
  local spec_set = def.guards
  if not spec_set then return end
  for _, g in ipairs(spec_set) do
    local home = (g.side == spec_set.start) and g.up or g.down
    local body = love.physics.newBody(self.world, home.x, home.y, "kinematic")
    local shape = love.physics.newRectangleShape(0, 0, g.w, g.h, g.angle or 0)
    local f = love.physics.newFixture(body, shape, 1)
    f:setRestitution(spec_set.kick or 1.30)
    f:setFriction(0.04)
    ud(f, "guard", g.side)
    local dx, dy = g.up.x - g.down.x, g.up.y - g.down.y
    self.guards[g.side] = {
      def = g, body = body,
      rate = math.sqrt(dx * dx + dy * dy) / C.GUARD_TRAVEL,
    }
  end
end

--- The rails of every ramp, on the ramp layer.
---
--- Static edges exactly like walls, and deliberately duller than them: a ramp
--- is a plastic lane, so it eats the speed a ball scrapes off against it
--- rather than handing it back. A ramp that bounced like the shell would make
--- a shot that clips a rail faster than one that does not.
local function build_ramps(self, def)
  for _, r in ipairs(def.ramps or {}) do
    for _, rail in ipairs({ r.geom.left, r.geom.right }) do
      for i = 1, #rail - 3, 2 do
        local shape = love.physics.newEdgeShape(rail[i], rail[i+1], rail[i+2], rail[i+3])
        local f = love.physics.newFixture(self.ground, shape, 0)
        f:setRestitution(0.14)
        f:setFriction(0.12)
        f:setUserData({ kind = "rail", id = r.id })
        f:setFilterData(CAT_RAMP, CAT_BALL, 0)
      end
    end

    -- ...and the part of the ramp that is solid to a ball on the PLAYFIELD.
    -- Near its feet the lane is inches off the floor, so a ball cannot go
    -- under it and must go around; only where it has climbed clear does the
    -- space beneath open up. Without these the rails existed on the ramp
    -- layer alone and a playfield ball walked through the side of a ramp
    -- lying on the ground, which is what made it read as a drawing.
    --
    -- Ordinary field walls, so they wedge, jam a flipper and sound exactly as
    -- any other wall does. core/ramp.lua decides where they are.
    for _, poly in ipairs(r.geom.skirt) do
      for i = 1, #poly - 3, 2 do
        local shape = love.physics.newEdgeShape(poly[i], poly[i+1], poly[i+2], poly[i+3])
        local f = love.physics.newFixture(self.ground, shape, 0)
        f:setRestitution(0.20)
        f:setFriction(0.10)
        ud(f, "rampwall", r.id)
      end
    end
    self.ramps[#self.ramps+1] = r
  end
end

---@param def table validated board definition
---@param seed number|nil seeds the board's own generator, which currently only
---  the serve draws on. A Match derives one per board from the match seed, so
---  §5.1's "intents plus a seed" still reproduces a whole match. A board built
---  on its own -- a probe, a spec -- gets the fixed seed and stays as
---  repeatable as it was before serves had any jitter in them; a harness that
---  sweeps seeds should pass its own, or every one of its runs gets the same
---  serve and it is measuring one trajectory rather than the board.
---@return table board
function Board.new(def, seed)
  local self = setmetatable({}, Board)
  self.def      = def
  self.id       = def.id
  self.rng      = love.math.newRandomGenerator(seed or C.RNG_SEED)
  self.world    = love.physics.newWorld(0, C.GRAVITY_PX, true)
  self.ground   = love.physics.newBody(self.world, 0, 0, "static")
  self.flippers = {}
  self.devices  = {}
  self.guards   = {}
  self.ramps    = {}
  self.ball     = nil
  -- Which ramp the ball is on, and how far along it. nil means the playfield,
  -- which is where a ball starts and where it always ends up.
  self.on_ramp  = nil
  self.ball_s   = 0
  self.events   = {}

  build_walls(self, def)
  build_bumpers(self, def)
  build_slingshots(self, def)
  build_targets(self, def)
  build_rollovers(self, def)
  build_mouth(self, def)
  build_devices(self, def)
  build_guards(self, def)
  build_ramps(self, def)
  for _, spec in ipairs(def.flippers) do build_flipper(self, def, spec) end

  self.world:setCallbacks(
    function(fa, fb, coll) self:_begin(fa, fb, coll) end,
    nil, nil,
    function(fa, fb, coll, ni) self:_postsolve(fa, fb, coll, ni) end)
  return self
end

---------------------------------------------------------------------------
-- Ball
---------------------------------------------------------------------------

function Board:spawn(x, y, vx, vy)
  self:despawn()
  local body = love.physics.newBody(self.world, x, y, "dynamic")
  body:setBullet(true)                       -- §4.1: CCD on the ball, always
  body:setLinearDamping(C.BALL_DAMPING)
  local f = love.physics.newFixture(body, love.physics.newCircleShape(C.BALL_RADIUS), C.BALL_DENSITY)
  f:setRestitution(C.BALL_RESTIT)
  f:setFriction(C.BALL_FRICTION)
  ud(f, "ball")
  body:setLinearVelocity(vx or 0, vy or 0)
  self.ball    = body
  self.ball_fx = f
  self.on_ramp = nil
  self.ball_s  = 0
  self:_see("field")
  return body
end

function Board:despawn()
  if self.ball then
    if not self.ball:isDestroyed() then self.ball:destroy() end
    self.ball = nil
  end
  self.ball_fx = nil
  self.on_ramp = nil
  self.ball_s  = 0
end

function Board:ball_pos()
  if not self.ball or self.ball:isDestroyed() then return nil end
  return self.ball:getX(), self.ball:getY()
end

function Board:ball_speed()
  if not self.ball or self.ball:isDestroyed() then return 0 end
  local vx, vy = self.ball:getLinearVelocity()
  return math.sqrt(vx * vx + vy * vy)
end

--- Velocity components. Anything predicting where the ball is going -- a
--- timing probe, and later an AI opponent or a replay scrubber -- needs the
--- direction, which the scalar speed above throws away.
---@return number vx, number vy
function Board:ball_velocity()
  if not self.ball or self.ball:isDestroyed() then return 0, 0 end
  return self.ball:getLinearVelocity()
end

--- A symmetric draw in [-amount, +amount] from this board's generator.
function Board:_jitter(amount)
  return (self.rng:random() * 2 - 1) * amount
end

--- Serve from the plunger lane (§ board data `serve`).
---
--- A plunger is pulled by a hand, and no two pulls are the same, so the serve
--- carries a little jitter in both strength and direction -- enough that the
--- first bounce is not the same bounce every ball, and small enough that the
--- serve still does its job (C.SERVE_SPEED_VAR, C.SERVE_ANGLE_VAR).
---
--- The angle is taken from the authored direction rather than applied to its
--- components, so a board is free to write `dir` unnormalised; the speed is
--- the whole magnitude either way.
function Board:serve()
  local s = self.def.serve
  local speed = C.SERVE_SPEED * (1 + self:_jitter(C.SERVE_SPEED_VAR))
  local a = math.atan2(s.dir.y, s.dir.x) + self:_jitter(C.SERVE_ANGLE_VAR)
  self:spawn(s.x, s.y, math.cos(a) * speed, math.sin(a) * speed)
end

--- A ball arriving out of the tube. §5: exit velocity survives the trip; the
--- entry point decides the direction it arrives from.
function Board:arrive(speed, aim)
  local e = self.def.entry
  local len = math.sqrt(e.dir.x * e.dir.x + e.dir.y * e.dir.y)
  local vx, vy = e.dir.x / len * speed, e.dir.y / len * speed
  local c, s = math.cos(aim or 0), math.sin(aim or 0)
  self:spawn(e.x, e.y, vx * c - vy * s, vx * s + vy * c)
end

---------------------------------------------------------------------------
-- Ramps
---------------------------------------------------------------------------

--- Point the ball's collision mask at one layer's geometry.
---@param layer "field"|"ramp"
function Board:_see(layer)
  if not self.ball_fx then return end
  self.ball_fx:setFilterData(CAT_BALL, (layer == "ramp") and CAT_RAMP or CAT_FIELD, 0)
end

--- Put the ball on a ramp, or take it off the one it is on. Both halves
--- report, because app/ wants to sound the difference and because "the ball
--- got onto the ramp and never came off" is the failure this whole layer has
--- to be watched for.
function Board:_mount(r, s)
  self.ramp_start = s
  self.on_ramp, self.ball_s = r, s
  self:_see("ramp")
  local x, y = self:ball_pos()
  self.events[#self.events+1] =
    { kind = "ramp", board = self.id, id = r.id, at = "enter", x = x, y = y }
end

function Board:_dismount(complete)
  local id = self.on_ramp and self.on_ramp.id
  self.on_ramp, self.ball_s = nil, 0
  self:_see("field")
  local x, y = self:ball_pos()
  self.events[#self.events+1] =
    { kind = "ramp", board = self.id, id = id, at = "exit", complete = complete or false, x = x, y = y }
end

--- Is the ball about to commit to a ramp? Only from inside the lane, only
--- through a mouth that admits it, and only when it is actually travelling
--- into the climb rather than drifting across the entrance.
---
--- The lateral test is tighter than the lane by a full ball radius on purpose:
--- the instant the mask flips, the rails become solid to a ball that was
--- passing straight through them, and a ball already overlapping one would be
--- shoved sideways out of the mouth by the solver.
---@return table|nil ramp, number|nil s
function Board:_boarding(x, y, vx, vy)
  for _, r in ipairs(self.ramps) do
    local g = r.geom
    local s, lat, tx, ty = ramp.project(g, x, y)
    if math.abs(lat) <= g.width / 2 - C.BALL_RADIUS then
      local along = vx * tx + vy * ty
      -- The window is INSIDE the ramp, never before it. A ball that mounts
      -- while its projection is still short of the mouth is, by the very
      -- next step, a ball whose projection has run off the end -- which is
      -- exactly what the safety net in _step_ramps takes it off the ramp
      -- for. It mounted and dismounted in two ticks and never climbed a
      -- pixel: nineteen of nineteen shots on Foundry, all of them reported
      -- as "reached the mouth" and none of them as a ride.
      --
      -- Nothing is missed by waiting: the window is RAMP_MOUTH long and the
      -- ball covers at most 9.1px in a step at its speed ceiling, so it
      -- cannot cross the mouth without landing inside it at least twice.
      if ramp.admits(g, "start") and s >= 0 and s < C.RAMP_MOUTH
         and along >= g.enter_speed.start then
        return r, s
      end
      if ramp.admits(g, "end") and s > g.length - C.RAMP_MOUTH and s <= g.length
         and -along >= g.enter_speed["end"] then
        return r, s
      end
    end
  end
  return nil, nil
end

--- One step of the ramp layer, run before the world solves.
---
--- The projection is the authority, not the entry test: a ball whose
--- centreline position has run off either end, or that is somehow outside the
--- rails, goes back on the playfield immediately. Without that a ball could
--- be stranded on the ramp layer standing on open playfield, seeing none of
--- the geometry and falling through the whole board.
function Board:_step_ramps()
  if #self.ramps == 0 then return end
  if not self.ball or self.ball:isDestroyed() then
    if self.on_ramp then self.on_ramp, self.ball_s = nil, 0 end
    return
  end
  local x, y   = self.ball:getPosition()
  local vx, vy = self.ball:getLinearVelocity()

  if self.on_ramp then
    local g = self.on_ramp.geom
    local s, lat, tx, ty = ramp.project(g, x, y)
    if s < 0 or s > g.length or math.abs(lat) > g.width / 2 + C.BALL_RADIUS then
      local crossed = (self.ramp_start < g.length / 2 and s > g.length)
                   or (self.ramp_start >= g.length / 2 and s < 0)
      self:_dismount(crossed and math.abs(lat) <= g.width / 2 + C.BALL_RADIUS)
      return
    end
    self.ball_s = s
    -- What the climb costs. GRAVITY_PX is only the component of gravity that
    -- runs DOWN a playfield tilted 6.5deg; the component pressing the ball
    -- into that playfield is cot(6.5deg) times larger, and a rising lane
    -- turns a slice of that much larger force against the ball. See
    -- C.RAMP_CLIMB_G. The force is down-slope whichever way the ball is
    -- going, which is what lets a shot that runs out of speed roll back out
    -- of the mouth it came in through.
    local slope = ramp.slope_at(g, s)
    if slope ~= 0 then
      local a = C.RAMP_CLIMB_G * slope * self.ball:getMass()
      self.ball:applyForce(-tx * a, -ty * a)
    end
    return
  end

  local r, s = self:_boarding(x, y, vx, vy)
  if r then self:_mount(r, s) end
end

--- How high the ball is above the playfield, in board pixels. Zero unless it
--- is on a ramp. app/ draws the shadow from this and core/ has no opinion
--- about it at all.
---@return number
function Board:ball_z()
  if not self.on_ramp then return 0 end
  return ramp.height_at(self.on_ramp.geom, self.ball_s)
end

---------------------------------------------------------------------------
-- Collision
---------------------------------------------------------------------------

function Board:_begin(fa, fb, _)
  local a, b = fa:getUserData(), fb:getUserData()
  if not (a and b) then return end
  local other
  if a.kind == "ball" then other = b elseif b.kind == "ball" then other = a else return end
  if other.kind == "mouth" then
    self.events[#self.events+1] = { kind = "tube", board = self.id, speed = self:ball_speed() }

  elseif other.kind == "rollover" then
    local lane = self.def.rollovers[other.id]
    self.events[#self.events+1] = { kind = "rollover", board = self.id,
      index = other.id, x = lane.x, y = lane.y }

  elseif other.kind == "bumper" then
    -- A scoring hit, which is a rule and not a contact: it goes to core/,
    -- where the presentation `impact` below deliberately does not.
    --
    -- No debounce here, and that is a measured decision rather than an
    -- oversight. The worry was that a ball leaving a bumper with restitution
    -- > 1 would register several begin-contacts on the way out and score for
    -- each. tests/probe_scoring.lua says it does not: a 0.02s cooldown
    -- suppresses exactly as many repeats as no cooldown at all (21 of 120
    -- approaches either way), so there is no solver jitter to filter. The
    -- repeats that do exist are spread over 50-400ms -- the ball genuinely
    -- coming back for a second hit, which is a thing pinball rewards.
    local hit = self.def.bumpers[other.id]
    self.events[#self.events+1] = {
      kind = "bumper", board = self.id, index = other.id, x = hit.x, y = hit.y,
    }

  elseif other.kind == "sling" then
    local sl = self.def.slingshots[other.id]
    local c = sl.p
    self.events[#self.events+1] = {
      kind = "sling", board = self.id, index = other.id,
      x = (c[1] + c[3] + c[5]) / 3, y = (c[2] + c[4] + c[6]) / 3,
    }

  elseif other.kind == "guard" then
    -- A save, and a scoring one: the operator picked this side in advance and
    -- the ball found it. It deliberately does NOT feed the §7 cross-board
    -- links, for the same reason the slingshots do not -- a charge that
    -- arrives because you were standing in the right place is a charge that
    -- stops being something you went and did.
    local g = self.guards[other.id]
    local gx, gy = g.body:getPosition()
    self.events[#self.events+1] = {
      kind = "guard", board = self.id, side = other.id, x = gx, y = gy,
    }

  elseif other.kind == "target" then
    local t = self.def.targets[other.id]
    self.events[#self.events+1] = {
      kind = "target", board = self.id, index = other.id, x = t.x, y = t.y,
    }
  end
end

--- Impacts, for presentation only: app/ turns these into sound and light.
--- Reported from postSolve rather than beginContact because the solver's
--- normal impulse is the actual strength of the hit, where a begin-contact
--- event only says that one happened -- a ball resting on the post and a ball
--- slammed into it are the same event and wildly different sounds.
---
--- A resting ball generates a small impulse every step, so the threshold is
--- what separates a hit from a lean. It is measured, not guessed: see
--- `tests/probe_impulses.lua`.
function Board:_postsolve(fa, fb, coll, normal_impulse)
  if normal_impulse < C.IMPACT_MIN_IMPULSE then return end
  if #self.events >= C.IMPACT_MAX_PER_STEP then return end
  local a, b = fa:getUserData(), fb:getUserData()
  if not (a and b) then return end
  local other
  if a.kind == "ball" then other = b elseif b.kind == "ball" then other = a else return end
  if other.kind == "mouth" then return end
  local x, y = coll:getPositions()
  if not x then x, y = self:ball_pos() end
  self.events[#self.events+1] = {
    kind = "impact", board = self.id, what = other.kind,
    x = x, y = y, impulse = normal_impulse,
  }
end

---------------------------------------------------------------------------
-- Step
---------------------------------------------------------------------------

--- Held: drive at the "up" limit and let the joint limit hold it there.
--- Released: drive back to the rest limit. Deliberately NOT a per-step
--- comparison against the current angle -- that chatters, because Box2D lets
--- a limit overshoot slightly and the motor then reverses every other step.
local function drive_flipper(f, held)
  f.joint:setMotorSpeed((held and f.dir_up or -f.dir_up) * C.FLIPPER_SPEED)
end

--- Move a kinematic device toward its commanded state. Velocity-driven, never
--- teleported, so Box2D sees the motion and the ball gets a real contact
--- response -- which is also what makes §6.1's "persistent state" readable.
--- Slide a kinematic body toward a point at a fixed speed, arriving exactly.
--- Velocity-driven and never teleported, so Box2D sees the motion and a ball
--- in the way gets a real contact response.
local function move_body_to(body, tx, ty, rate, dt)
  local cx, cy = body:getPosition()
  local dx, dy = tx - cx, ty - cy
  local dist   = math.sqrt(dx * dx + dy * dy)
  if dist < 1e-3 then
    body:setLinearVelocity(0, 0)
    body:setPosition(tx, ty)
  else
    local step = rate * dt
    local v    = (dist <= step) and (dist / dt) or rate
    body:setLinearVelocity(dx / dist * v, dy / dist * v)
  end
end

local function drive_device(dev, commanded, dt)
  if dev.kind == "gate" then
    local d      = dev.def
    local target = commanded and d.open or d.closed
    local cur    = dev.body:getAngle()
    local delta  = target - cur
    if math.abs(delta) < 1e-4 then
      dev.body:setAngularVelocity(0)
      dev.body:setAngle(target)
    else
      local step = dev.rate * dt
      if math.abs(delta) <= step then
        dev.body:setAngularVelocity(delta / dt)
      else
        dev.body:setAngularVelocity(dev.rate * (delta > 0 and 1 or -1))
      end
    end
  else
    local target = commanded and dev.def.up or dev.def.down
    move_body_to(dev.body, target.x, target.y, dev.rate, dt)
  end
end

--- One fixed step. Never called with a variable dt (§4.1).
---@param bstate table core state for this board (flippers + device commands)
---@param has_ball boolean
---@return table[] events
function Board:step(bstate, has_ball)
  local dt = C.FIXED_DT
  self.events = {}

  for side, f in pairs(self.flippers) do
    drive_flipper(f, has_ball and bstate.flippers[side] or false)
  end
  for id, dev in pairs(self.devices) do
    drive_device(dev, bstate.devices[id].commanded, dt)
  end
  -- Both guards travel on every switch: one leaves as the other arrives, so
  -- for GUARD_TRAVEL seconds neither lane is sealed. That gap is the trade
  -- (§6.2) and it is why the bars move rather than teleporting.
  --
  -- A guard on cooldown is simply a guard with no deployed side: it has been
  -- spent, so both bars go home and both outlanes are live until it recharges.
  -- Which side core/ has SELECTED still matters while it is gone -- that is
  -- where it comes back -- but nothing here is across a lane.
  local armed = (bstate.guard_cooldown or 0) <= 0
  for side, g in pairs(self.guards) do
    local home = (armed and bstate.guard == side) and g.def.up or g.def.down
    move_body_to(g.body, home.x, home.y, g.rate, dt)
  end

  -- Before the solve: the layer the ball is on decides what it can hit this
  -- step, and the climb's force has to be in the same solve as the contacts
  -- it is fighting.
  self:_step_ramps()

  self.world:update(dt)

  if self.ball and not self.ball:isDestroyed() then
    -- Clamp: past this speed CCD starts losing thin geometry (§11 tunneling).
    local vx, vy = self.ball:getLinearVelocity()
    local sp = math.sqrt(vx * vx + vy * vy)
    if sp > C.BALL_MAX_SPEED then
      local k = C.BALL_MAX_SPEED / sp
      self.ball:setLinearVelocity(vx * k, vy * k)
    end
    -- A ball on a ramp is above the playfield, so the drain line is not
    -- under it however far down the board the ramp happens to run.
    local _, y = self.ball:getPosition()
    if y > self.def.drain_y and not self.on_ramp then
      self.events[#self.events+1] = { kind = "drain", board = self.id }
    end
  end

  return self.events
end

--- Guard travel as 0..1, for the renderer and for tests. 0 = retracted below
--- the drain line, 1 = across the mouth of its outlane.
---@param side "left"|"right"
---@return number
function Board:guard_progress(side)
  local g = self.guards[side]
  if not g then return 0 end
  local d = g.def
  local span = math.sqrt((d.up.x - d.down.x)^2 + (d.up.y - d.down.y)^2)
  if span == 0 then return 0 end
  local x, y = g.body:getPosition()
  return math.sqrt((x - d.down.x)^2 + (y - d.down.y)^2) / span
end

--- Device travel as 0..1, for the renderer and for tests. 0 = closed/down.
function Board:device_progress(id)
  local dev = self.devices[id]
  if not dev then return 0 end
  local d = dev.def
  if dev.kind == "gate" then
    return (dev.body:getAngle() - d.closed) / (d.open - d.closed)
  end
  local _, y = dev.body:getPosition()
  return (y - d.down.y) / (d.up.y - d.down.y)
end

return Board
