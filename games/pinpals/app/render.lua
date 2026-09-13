--- Presentation only (§5, §10). Reads sim/core state, draws it, owns nothing.
--- One shared camera on the active board; the dormant board is a live side
--- panel; tube transit pulls the camera out to show both boards at once.

local mission = require("core.mission")
local C       = require("core.constants")
local intents = require("core.intents")
local score   = require("core.score")
local geo     = require("core.geometry")
local ramps   = require("core.ramp")
local objective = require("core.objective")
local inspect = require("app.inspect")

local M = {}

-- Window size, read from the window rather than assumed. Every number below
-- is derived from it, so a board that grows or a display that is bigger than
-- 1000x780 both work without a second set of hardcoded coordinates to keep in
-- sync -- which is what the 384x768 boards were quietly relying on.
local W, H = 1000, 780

-- Each board keeps its own side of the screen for the whole match: A is
-- anchored to the left margin, B to the right. Only the scale animates, so
-- nothing ever slides across the screen or trades places with the other board
-- -- you always know where your board is, and the handover has no jump in it.
local TOP_Y      = 30
local MARGIN     = 24
local FOOTER     = 46     -- room under the boards for the key hints and debug
local LEFT_X     = MARGIN
local RIGHT_EDGE = W - MARGIN

-- Filled in by layout(): the active board is scaled to fill the height it is
-- given, and the other two scales are fixed fractions of it so the pull-back
-- and the side panel keep their proportions whatever the board's size.
local S_ACTIVE, S_DORMANT, S_TRANSIT = 0.93, 0.40, 0.70

--- Recompute the layout for the current window and the current boards.
--- Called from load(); everything else reads the results.
local function layout(defs)
  if love.graphics and love.graphics.getDimensions then
    W, H = love.graphics.getDimensions()
  end
  LEFT_X, RIGHT_EDGE = MARGIN, W - MARGIN
  local tallest = 1
  for _, def in pairs(defs) do tallest = math.max(tallest, def.size.h) end
  -- 0.95 rather than 1.0 so a board that happens to be short does not fill
  -- the window edge to edge and leave the nameplate hanging off the top.
  S_ACTIVE  = math.min(0.95, (H - TOP_Y - FOOTER) / tallest)
  S_DORMANT = S_ACTIVE * 0.43
  S_TRANSIT = S_ACTIVE * 0.75    -- both boards visible for the pass (§10)
end

--- Screen position of a board at a given scale. This is the whole layout.
local function place(id, s, w)
  local x = (id == "a") and LEFT_X or (RIGHT_EDGE - w * s)
  return x, TOP_Y
end

local THEME = {
  a = { wall = {0.98, 0.62, 0.28}, fill = {0.11, 0.075, 0.055} },
  b = { wall = {0.42, 0.85, 0.95}, fill = {0.055, 0.09, 0.105} },
}

local fonts

-- Injected by main.lua rather than required, so the renderer still draws with
-- no effects attached -- which is what `--shot` does, and what makes a "did fx
-- break this?" bisect one line long.
local fx

---@param module table app.fx
function M.attach_fx(module)
  fx = module
  -- render owns every font in the game; fx borrows one rather than creating
  -- its own, which is what keeps fx loadable in the bare interpreter.
  if fonts then fx.set_font(fonts.body) end
end

--- Called again after a hot reload, because the layout is derived from the
--- boards' own size and a board that grows changes every scale on screen. The
--- fonts are kept: they do not depend on the board data, and rebuilding them
--- on every save leaks a texture atlas per edit.
function M.load(defs)
  layout(defs)
  fonts = fonts or {
    tiny  = love.graphics.newFont(9),
    small = love.graphics.newFont(11),
    body  = love.graphics.newFont(14),
    head  = love.graphics.newFont(20),
    huge  = love.graphics.newFont(34),
  }
  M.view = { a = { s = S_ACTIVE }, b = { s = S_DORMANT } }
  M.hud_a = 1
  for id, v in pairs(M.view) do v.x, v.y = place(id, v.s, defs[id].size.w) end
  M.hud_x = LEFT_X + defs.a.size.w * M.view.a.s + MARGIN
  M.size.w, M.size.h = W, H
  if fx then fx.set_font(fonts.body) end
end

M.size = { w = W, h = H }

local function lerp(a, b, t) return a + (b - a) * t end

--- 1234500 -> "1,234,500". Pinball scores are large by design and a bare run
--- of digits cannot be read at a glance from across a room.
local function commas(n)
  local out = tostring(math.floor(n))
  local k
  repeat out, k = out:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
  return out
end

--- §9: relay heat, 0..1. The rally gets visibly hotter as it gets more
--- valuable and more likely to end, which is the whole risk curve made
--- visible. Saturates at 10 crossings so a long rally still has a ceiling.
local function heat_of(state)
  return math.min(1, (state.stats.relay or 0) / 10)
end

--- Interpolate a value between the two most recent sim states (§4.1).
local function ilerp(prev, cur, alpha) return prev and cur and lerp(prev, cur, alpha) or cur end

---------------------------------------------------------------------------
-- Camera
---------------------------------------------------------------------------

--- nil, or the id of the board whose coordinates are on screen (key 2). It moves
--- the camera as well as drawing the overlay, so the board being inspected is
--- the big one whether or not the ball happens to be on it -- otherwise the
--- only way to look at the other board's numbers is to make the pass first.
M.inspect = nil

---@param active string the board to fall back to when switching the mode on
function M.toggle_inspect(active)
  -- Not `M.inspect and nil or active`: that idiom can never yield nil, so the
  -- mode would switch on and then refuse to switch back off.
  if M.inspect then M.inspect = nil else M.inspect = active end
end

function M.swap_inspect()
  if M.inspect then M.inspect = (M.inspect == "a") and "b" or "a" end
end

--- The coordinate the overlay is naming at a screen position, or nil when the
--- mode is off or the position is off the inspected board. The shake is taken
--- out here for the same reason M.draw takes it out: the overlay lives inside
--- that transform, so a click during a bumper hit would otherwise read a
--- couple of pixels off.
---@return table|nil { x, y, tag = string|nil, text = string }
function M.pick_inspect(match, x, y)
  if not M.inspect or not match.defs[M.inspect] then return nil end
  local sx, sy = 0, 0
  if fx then sx, sy = fx.shake_offset() end
  return inspect.pick(match.defs[M.inspect], M.view[M.inspect], x - sx, y - sy)
end

--- Target scale per board. During transit both are pulled back to the same
--- size; otherwise the board with the ball is the big one.
local function target_scale(state, id)
  if M.inspect then return (id == M.inspect) and S_ACTIVE or S_DORMANT end
  if state.phase == "transit" then return S_TRANSIT end
  return (id == state.active) and S_ACTIVE or S_DORMANT
end

function M.update_camera(state, defs, dt)
  local k = 1 - math.exp(-12 * dt)      -- frame-rate independent smoothing
  -- The HUD stays up during transit. It used to fade out for the whole beat,
  -- on the assumption that the pulled-back boards reached into its column --
  -- they do not: at S_TRANSIT the gap between the boards is 390px against
  -- 214px in normal play, so pulling back makes *more* room, not less.
  --
  -- It mattered because prototype.md §4.5 hands the sender the destination
  -- board's devices for exactly these ~800ms. Hiding the operator's panel for
  -- the one window in which they are the operator is what made the transit
  -- read as dead air, and it is a pillar-1 violation ("nobody waits") dressed
  -- up as a camera move.
  M.hud_a = lerp(M.hud_a, 1, k)
  for id, v in pairs(M.view) do
    v.s = lerp(v.s, target_scale(state, id), k)
    v.x, v.y = place(id, v.s, defs[id].size.w)
  end
  -- The HUD lives in the gap between the two boards, wherever that currently
  -- is: derived from the live scale, so it is always in the right place.
  M.hud_x = LEFT_X + defs.a.size.w * M.view.a.s + MARGIN
end

---------------------------------------------------------------------------
-- Board
---------------------------------------------------------------------------

--- The landing, telegraphed on the receiving board. §10 wants the incoming
--- ball legible without looking at it, and this is the visual half of that:
--- rings that tighten onto the entry point as the ball closes, so the
--- operator can see how long they have left to rearrange the floor.
---
--- Drawn in board space, inside the receiving board's transform.
local function draw_incoming(def, incoming)
  local u = incoming.u
  local e = def.entry
  local lg = love.graphics
  -- Entry points sit against a wall by construction -- the ball arrives
  -- through one -- so a fixed ring radius spills over the board edge and gets
  -- scissored into a stray arc. Size the rings to the room actually there.
  local room = math.min(e.x, def.size.w - e.x, e.y, 52)
  local span = math.max(14, room - 12)   -- 10 is the inner radius below
  -- Three rings, staggered, each collapsing onto the entry point. Staggering
  -- them means there is always one mid-collapse, so the countdown reads at a
  -- glance instead of only at the moment a single ring lands.
  for i = 0, 2 do
    local ru = (u + i / 3) % 1
    lg.setColor(0.55, 0.95, 0.7, 0.55 * (1 - ru))
    lg.setLineWidth(2)
    lg.circle("line", e.x, e.y, 10 + span * (1 - ru))
  end
  -- A large arrow previews exactly the direction used by Board:arrive.
  local angle = math.atan2(e.dir.y, e.dir.x) + incoming.aim
  local dx, dy = math.cos(angle), math.sin(angle)
  local tipx, tipy = e.x + dx * 115, e.y + dy * 115
  lg.setColor(0.03, 0.12, 0.09, 0.9)
  lg.setLineWidth(13)
  lg.line(e.x, e.y, tipx, tipy)
  lg.setColor(0.6, 1, 0.75, 1)
  lg.setLineWidth(7)
  lg.line(e.x, e.y, tipx - dx * 18, tipy - dy * 18)
  lg.polygon("fill", tipx, tipy,
    tipx - dx * 28 - dy * 16, tipy - dy * 28 + dx * 16,
    tipx - dx * 28 + dy * 16, tipy - dy * 28 - dx * 16)
  lg.circle("fill", e.x, e.y, 7)
end

---------------------------------------------------------------------------
-- Ramps
---------------------------------------------------------------------------

--- A ramp is drawn as two triangle strips: the lane itself, and the shadow it
--- throws on the playfield below.
---
--- Both carry the gradient in their VERTEX COLOURS rather than in a shader or
--- a stack of translucent polygons, because the thing being drawn genuinely
--- is a value that varies along the strip -- how high the ramp is there.
--- Height is the only cue the player has for which lane the ball is in, so it
--- has to be visible everywhere along the ramp and not just at the ends.
---
--- The shadow is the same strip displaced by z * the light direction, so it
--- shears away from the ramp exactly where the ramp climbs and rejoins it at
--- the feet. That shear is what makes the height read as height rather than
--- as a colour ramp.
---
--- Built once per board definition. Definitions are immutable and a hot
--- reload replaces the whole table, so identity is a sound cache key -- the
--- same reason app/inspect.lua caches its point list that way.
--- Keyed by the definition table itself, and weakly, so a hot reload's new
--- board simply misses and the old one's meshes go with it. A single-slot
--- cache would thrash: both boards are drawn every frame.
local mesh_cache = setmetatable({}, { __mode = "k" })

local function ramp_meshes(def, th)
  local out = {}
  for _, r in ipairs(def.ramps or {}) do
    local g = r.geom
    local surface, shadow = {}, {}

    --- One rung of the ladder: the two rail points at arclength `s`, coloured
    --- and displaced by how high the ramp is there.
    local function rung(s, lx, ly, rx, ry)
      local z = ramps.height_at(g, s)
      local u = (g.height > 0) and (z / g.height) or 0
      local sx, sy = z * C.RAMP_SHADOW_X, z * C.RAMP_SHADOW_Y
      local lift = 0.40 + 0.60 * u
      -- Keep the elevated lane legible without hiding targets beneath it.
      local a = 0.15 + 0.15 * u
      for _, p in ipairs({ { lx, ly }, { rx, ry } }) do
        surface[#surface+1] = {
          p[1], p[2], 0, 0,
          th.wall[1] * lift, th.wall[2] * lift, th.wall[3] * lift, a,
        }
        shadow[#shadow+1] = { p[1] + sx, p[2] + sy, 0, 0, 0, 0, 0, 0.04 + 0.16 * u }
      end
    end

    -- Cut across the lane every RAMP_MESH_STEP pixels of ramp rather than at
    -- the path's own vertices. The rungs stay exactly on the rails -- they
    -- are linear interpolations along one rail segment -- so the drawn edge
    -- still matches the physics edge, but the gradient and the shadow's
    -- shear now follow the height profile instead of a straight blend across
    -- whatever the tessellation happened to produce.
    local last_k = #g.path / 2 - 1
    for k = 1, last_k do
      local s0, s1 = g.cum[k], g.cum[k+1]
      local n = math.max(1, math.ceil((s1 - s0) / C.RAMP_MESH_STEP))
      local stop = (k == last_k) and n or (n - 1)
      for i = 0, stop do
        local t = i / n
        rung(s0 + (s1 - s0) * t,
             lerp(g.left[k*2-1],  g.left[k*2+1],  t),
             lerp(g.left[k*2],    g.left[k*2+2],  t),
             lerp(g.right[k*2-1], g.right[k*2+1], t),
             lerp(g.right[k*2],   g.right[k*2+2], t))
      end
    end

    out[#out+1] = {
      ramp    = r,
      surface = love.graphics.newMesh(surface, "strip", "static"),
      shadow  = love.graphics.newMesh(shadow,  "strip", "static"),
    }
  end
  return out
end

local function meshes_for(def, th)
  local m = mesh_cache[def]
  if not m then
    m = ramp_meshes(def, th)
    mesh_cache[def] = m
  end
  return m
end

--- Everything that is cast on the playfield floor, drawn before the geometry
--- that casts it. The ball's own shadow is here too rather than next to the
--- ball: a shadow drawn after the ramp would lie ON the ramp, which is the one
--- place it certainly is not.
local function draw_shadows(ctx, th)
  for _, m in ipairs(meshes_for(ctx.def, th)) do
    love.graphics.setColor(1, 1, 1, ctx.dim)
    love.graphics.draw(m.shadow)
  end
  local ball = ctx.snap.ball
  if ball and (ball.z or 0) > 0.5 then
    local bx = ilerp(ctx.prev and ctx.prev.ball and ctx.prev.ball.x, ball.x, ctx.alpha)
    local by = ilerp(ctx.prev and ctx.prev.ball and ctx.prev.ball.y, ball.y, ctx.alpha)
    local z  = ilerp(ctx.prev and ctx.prev.ball and ctx.prev.ball.z, ball.z, ctx.alpha)
    love.graphics.setColor(0, 0, 0, 0.45 * ctx.dim)
    love.graphics.circle("fill", bx + z * C.RAMP_SHADOW_X, by + z * C.RAMP_SHADOW_Y,
                         C.BALL_RADIUS * 0.92)
  end
end

--- The lanes themselves, over the playfield they cross. Translucent on
--- purpose: a ball running underneath a ramp has to stay visible, or the
--- space a ramp frees up is space the player cannot see into.
local function draw_ramps(ctx, th)
  for _, m in ipairs(meshes_for(ctx.def, th)) do
    love.graphics.setColor(ctx.dim, ctx.dim, ctx.dim, 1)
    love.graphics.draw(m.surface)
    local g = m.ramp.geom
    love.graphics.setLineWidth(2)
    love.graphics.setColor(th.wall[1] * ctx.dim, th.wall[2] * ctx.dim,
                           th.wall[3] * ctx.dim, 0.75)
    for _, rail in ipairs({ g.left, g.right }) do love.graphics.line(rail) end
    -- The skirt: where the ramp is too low to duck under, its sides and the
    -- wall across its lane are solid to a ball on the playfield. Drawn at
    -- full wall weight because that is exactly what they are -- a ball can
    -- come off them, and anything it can come off has to look like it can.
    love.graphics.setLineWidth(3)
    love.graphics.setColor(th.wall[1] * ctx.dim, th.wall[2] * ctx.dim,
                           th.wall[3] * ctx.dim, 1)
    for _, poly in ipairs(g.skirt) do love.graphics.line(poly) end
  end
end

--- One board, drawn in its own space. Split out of a 181-line draw_board
--- with nine parameters: each of these is one layer of the picture, in the
--- order they stack, and `ctx` carries the per-frame facts they share.
---
--- @class BoardCtx
--- @field def table      board definition
--- @field snap table     this tick's sim snapshot
--- @field prev table     the previous one, for interpolation (§4.1)
--- @field alpha number   interpolation factor
--- @field view table     screen placement and scale
--- @field active boolean is this the board being played
--- @field dim number     1.0 active, 0.45 dormant
--- @field heat number    relay heat, 0..1
--- @field bstate table   core per-board state (devices, meters, lit)

--- The only drain on either board (prototype.md §4.6).
local function draw_drain_line(ctx)
  -- Drain line
  love.graphics.setColor(0.6, 0.15, 0.15, 0.55 * ctx.dim)
  love.graphics.setLineWidth(1)
  love.graphics.line(0, ctx.def.drain_y, ctx.def.size.w, ctx.def.drain_y)
end

--- Static geometry.
local function draw_walls(ctx, th)
  love.graphics.setColor(th.wall[1] * ctx.dim, th.wall[2] * ctx.dim, th.wall[3] * ctx.dim, 1)
  love.graphics.setLineWidth(3)
  for _, poly in ipairs(ctx.def.walls) do love.graphics.line(poly) end
end

--- Foundry's character, and its cross-board payoff when lit (§7.1).
local function draw_bumpers(ctx)
  -- Bumpers. A struck bumper lights and swells for ~300ms: they are board A's
  -- declared character (prototype.md §4.1) and were previously indistinguishable
  -- from scenery whether or not the ball had just hit them.
  local bumpers_lit = ctx.bstate and (ctx.bstate.lit.bumpers or 0) > 0
  for i, b in ipairs(ctx.def.bumpers or {}) do
    local pulse = fx and fx.hit_pulse(ctx.def.id, "bumper", i) or 0
    local r = b.r * (1 + 0.18 * pulse)
    -- Lit means Glasshouse cleared its vault and these are briefly worth
    -- LIT_MULT times as much. It has to be unmistakable from across a room,
    -- so lit bumpers change colour rather than just brightening.
    local cr, cg, cb = 0.95, 0.85, 0.30
    if bumpers_lit then cr, cg, cb = 1.0, 0.45, 0.72 end
    love.graphics.setColor(cr * ctx.dim, cg * ctx.dim, cb * ctx.dim, 0.85 + 0.15 * pulse)
    love.graphics.setLineWidth((bumpers_lit and 3 or 2) + 3 * pulse)
    love.graphics.circle("line", b.x, b.y, r)
    love.graphics.setColor(cr * ctx.dim, cg * ctx.dim, cb * ctx.dim,
                           (bumpers_lit and 0.34 or 0.18) + 0.62 * pulse)
    love.graphics.circle("fill", b.x, b.y, r)
    love.graphics.setLineWidth(3)
  end
  if bumpers_lit then
    love.graphics.setFont(fonts.small)
    love.graphics.setColor(1, 0.45, 0.72, 0.9)
    love.graphics.printf(("BUMPERS LIT x%d  (%d)"):format(C.LIT_MULT, ctx.bstate.lit.bumpers),
                         0, 108, ctx.def.size.w, "center")
  end
end

--- What the partner board has built up here, on the board it belongs to.
local function draw_cross_board(ctx)
  -- §7 cross-board state, drawn on the board it belongs to so it is visible
  -- on the dormant panel too -- the whole point being that what you built
  -- over there is still there when you arrive.
  if ctx.bstate then
    -- The vault charge, above the bank it will multiply.
    for name, level in pairs(ctx.bstate.meters or {}) do
      if level > 0 then
        local bank = ctx.bstate.banks[name]
        local first = bank and ctx.def.targets[bank.members[1]]
        if first then
          local u = level / C.CHARGE_MAX
          local w = 96
          local bx, by = first.x - 8, first.y - 34
          love.graphics.setColor(1, 1, 1, 0.12)
          love.graphics.rectangle("fill", bx, by, w, 7, 3)
          love.graphics.setColor(lerp(0.5, 1, u), lerp(0.9, 0.55, u), lerp(0.7, 0.15, u), 0.95)
          love.graphics.rectangle("fill", bx, by, w * u, 7, 3)
          love.graphics.setFont(fonts.small)
          love.graphics.setColor(1, 1, 1, 0.55)
          love.graphics.print(("%s x%d"):format(name:upper(), 1 + level), bx, by - 15)
        end
      end
    end
  end
end

--- The two slingshots above the flippers. Drawn filled, because they are the
--- one piece of furniture the player has to read as SOLID at a glance -- a
--- shot that clips one is going somewhere the player did not aim.
local function draw_slingshots(ctx)
  for i, sl in ipairs(ctx.def.slingshots or {}) do
    local pulse = fx and fx.hit_pulse(ctx.def.id, "sling", i) or 0
    love.graphics.setColor(0.85 * ctx.dim, 0.42 * ctx.dim, 0.62 * ctx.dim,
                           0.30 + 0.55 * pulse)
    love.graphics.polygon("fill", sl.p)
    love.graphics.setColor(1.0 * ctx.dim, 0.55 * ctx.dim, 0.80 * ctx.dim,
                           0.65 + 0.35 * pulse)
    love.graphics.setLineWidth(2 + 3 * pulse)
    love.graphics.polygon("line", sl.p)
    love.graphics.setLineWidth(3)
  end
end

--- Glasshouse's character. Lit means struck and waiting for its bank.
local function draw_targets(ctx)
  -- Targets. A lit one has been hit and is waiting for the rest of its bank;
  -- the difference has to be visible at a glance or the bank is a mechanic
  -- only the scoreboard knows about.
  for i, t in ipairs(ctx.def.targets or {}) do
    local tstate = ctx.bstate and ctx.bstate.targets[i]
    local lit    = tstate and tstate.lit
    local pulse  = fx and fx.hit_pulse(ctx.def.id, "target", i) or 0
    local corners = geo.rect_corners(t)
    if lit then
      love.graphics.setColor(0.55 * ctx.dim, 0.98 * ctx.dim, 0.70 * ctx.dim, 0.85 + 0.15 * pulse)
    else
      love.graphics.setColor(0.80 * ctx.dim, 0.82 * ctx.dim, 0.90 * ctx.dim, 0.45 + 0.55 * pulse)
    end
    love.graphics.polygon("fill", corners)
    love.graphics.setColor(1, 1, 1, (lit and 0.5 or 0.22) + 0.5 * pulse)
    love.graphics.setLineWidth(1.5)
    love.graphics.polygon("line", corners)
  end
end

--- §5: the tube mouth and the arrival point, always visible.
local function draw_link(ctx)
  -- Tube mouth and arrival point (§5: the link, always visible)
  local m = ctx.def.tube.mouth
  love.graphics.setColor(0.55 * ctx.dim, 0.95 * ctx.dim, 0.65 * ctx.dim, 0.9)
  love.graphics.setLineWidth(2)
  love.graphics.circle("line", m.x, m.y, m.r)
  love.graphics.circle("line", m.x, m.y, m.r * 0.55)
  local e = ctx.def.entry
  love.graphics.setColor(0.55 * ctx.dim, 0.95 * ctx.dim, 0.65 * ctx.dim, 0.35)
  love.graphics.circle("line", e.x, e.y, 13)
  love.graphics.line(e.x, e.y, e.x + e.dir.x * 26, e.y + e.dir.y * 26)
end

--- §6.1: operator devices, amber as they travel and while engaged.
local function draw_devices(ctx)
  for _, d in ipairs(ctx.def.devices) do
    local ds, dp = ctx.snap.devices[d.id], ctx.prev and ctx.prev.devices[d.id]
    local p = ilerp(dp and dp.p, ds.p, ctx.alpha) or ds.p
    -- Amber when moving or engaged; this is the operator's tell (§6.1).
    love.graphics.setColor(lerp(0.35, 1.0, p) * ctx.dim,
                           lerp(0.45, 0.72, p) * ctx.dim,
                           lerp(0.55, 0.20, p) * ctx.dim, 1)
    love.graphics.setLineWidth(7)
    if d.kind == "gate" then
      local ang = ilerp(dp and dp.angle, ds.angle, ctx.alpha) or ds.angle
      love.graphics.line(d.pivot.x, d.pivot.y,
                         d.pivot.x + math.cos(ang) * d.length,
                         d.pivot.y + math.sin(ang) * d.length)
      love.graphics.circle("fill", d.pivot.x, d.pivot.y, 4)
    else
      local x = ilerp(dp and dp.x, ds.x, ctx.alpha) or ds.x
      local y = ilerp(dp and dp.y, ds.y, ctx.alpha) or ds.y
      love.graphics.rectangle("fill", x - d.w / 2, y - d.h / 2, d.w, d.h, 4)
    end
  end
end

--- §6.2: the outlane guard. The one on the guarded side is across the mouth
--- of its lane and bright; the other is on its way down out of the board.
---
--- Drawn in the bumper's own colour family rather than the amber the gate and
--- post use, because it does the bumper's job on contact -- and because the
--- flipper player has to be able to read WHICH SIDE IS SAFE out of the corner
--- of their eye, from a board they are not looking directly at.
---
--- While it is spent, the lane it will come back to carries an empty outline
--- that fills as the cooldown runs down. Without it a recharging guard is
--- invisible on the board, and the operator's only remaining decision --
--- which side gets the next save -- would exist solely in the side panel.
local function draw_guard_recharge(ctx)
  local bs = ctx.bstate
  local left = bs and (bs.guard_cooldown or 0) or 0
  if left <= 0 or not bs.guard then return end
  local g
  for _, spec in ipairs(ctx.def.guards or {}) do
    if spec.side == bs.guard then g = spec end
  end
  if not g then return end
  local ready = 1 - left / C.GUARD_COOLDOWN
  love.graphics.push()
  love.graphics.translate(g.up.x, g.up.y)
  love.graphics.rotate(g.angle or 0)
  love.graphics.setColor(0.45 * ctx.dim, 0.95 * ctx.dim, 1.0 * ctx.dim, 0.16)
  love.graphics.setLineWidth(1)
  love.graphics.rectangle("line", -g.w / 2, -g.h / 2, g.w, g.h, 4)
  -- Filling from the outer end inward, the direction the bar itself arrives
  -- from, so the animation and the mechanism point the same way.
  local sign = (g.side == "left") and -1 or 1
  love.graphics.setColor(0.45 * ctx.dim, 0.95 * ctx.dim, 1.0 * ctx.dim, 0.30)
  love.graphics.rectangle("fill", sign < 0 and -g.w / 2 or (g.w / 2 - g.w * ready),
                          -g.h / 2, g.w * ready, g.h, 4)
  love.graphics.setLineWidth(3)
  love.graphics.pop()
end

local function draw_guards(ctx)
  draw_guard_recharge(ctx)
  for _, g in ipairs(ctx.def.guards or {}) do
    local gs = ctx.snap.guards and ctx.snap.guards[g.side]
    if gs then
      local gp = ctx.prev and ctx.prev.guards and ctx.prev.guards[g.side]
      local p = ilerp(gp and gp.p, gs.p, ctx.alpha) or gs.p
      local x = ilerp(gp and gp.x, gs.x, ctx.alpha) or gs.x
      local y = ilerp(gp and gp.y, gs.y, ctx.alpha) or gs.y
      local pulse = fx and fx.hit_pulse(ctx.def.id, "guard", g.side) or 0
      love.graphics.push()
      love.graphics.translate(x, y)
      love.graphics.rotate(g.angle or 0)
      -- Deployed it is a lit bar; retracting it fades toward the board.
      love.graphics.setColor(lerp(0.30, 0.45, p) * ctx.dim,
                             lerp(0.55, 0.95, p) * ctx.dim,
                             lerp(0.60, 1.00, p) * ctx.dim,
                             (0.30 + 0.60 * p) + 0.40 * pulse)
      love.graphics.rectangle("fill", -g.w / 2, -g.h / 2, g.w, g.h, 4)
      love.graphics.setColor(0.70 * ctx.dim, 1.0 * ctx.dim, 1.0 * ctx.dim,
                             (0.25 + 0.65 * p) + 0.35 * pulse)
      love.graphics.setLineWidth(2 + 3 * pulse)
      love.graphics.rectangle("line", -g.w / 2, -g.h / 2, g.w, g.h, 4)
      love.graphics.setLineWidth(3)
      love.graphics.pop()
    end
  end
end

--- The player's own hands.
local function draw_flippers(ctx)
  love.graphics.setColor(0.92 * ctx.dim, 0.92 * ctx.dim, 0.96 * ctx.dim, 1)
  love.graphics.setLineWidth(C.FLIPPER_THICK)
  for _, f in ipairs(ctx.def.flippers) do
    local ang = ilerp(ctx.prev and ctx.prev.flippers[f.side], ctx.snap.flippers[f.side], ctx.alpha)
    local sign = (f.side == "left") and 1 or -1
    local tx = f.x + math.cos(ang) * C.FLIPPER_LEN * sign
    local ty = f.y + math.sin(ang) * C.FLIPPER_LEN * sign
    love.graphics.line(f.x, f.y, tx, ty)
    love.graphics.circle("fill", f.x, f.y, C.FLIPPER_THICK * 0.62)
  end
end

--- Effects under the ball, over the geometry; then the ball itself.
local function draw_effects_and_ball(ctx)
  -- Effects sit under the ball and over the geometry, in board space.
  if fx then fx.draw_board(ctx.def.id, ctx.heat) end

  -- Incoming ball, on the board that is about to receive it.
  if ctx.incoming then draw_incoming(ctx.def, ctx.incoming) end

  -- Ball. Its halo takes the rally heat: at rally 0 it is a plain white ball,
  -- and by rally 10 it is visibly running hot (§9).
  if ctx.snap.ball then
    local bx = ilerp(ctx.prev and ctx.prev.ball and ctx.prev.ball.x, ctx.snap.ball.x, ctx.alpha)
    local by = ilerp(ctx.prev and ctx.prev.ball and ctx.prev.ball.y, ctx.snap.ball.y, ctx.alpha)
    love.graphics.setColor(1, 0.95 - 0.35 * ctx.heat, 0.85 - 0.65 * ctx.heat, 0.25 + 0.22 * ctx.heat)
    love.graphics.circle("fill", bx, by, C.BALL_RADIUS * (2.1 + 0.9 * ctx.heat))
    love.graphics.setColor(1, 1 - 0.10 * ctx.heat, 1 - 0.22 * ctx.heat, 1)
    love.graphics.circle("fill", bx, by, C.BALL_RADIUS)
  end
end

--- The label, and the §7 flag when this board's cross-board state moved.
local function draw_shot_inserts(ctx)
  local m = ctx.bstate and ctx.bstate.mission
  if not m then return end
  love.graphics.setFont(fonts.small)
  for i, lane in ipairs(ctx.def.rollovers or {}) do
    local lit = m.lanes[i]
    love.graphics.setColor(0.4, 0.95, 0.85, (lit and 0.8 or 0.22) * ctx.dim)
    love.graphics.ellipse("fill", lane.x, lane.y, lane.w / 2, lane.h / 2)
    love.graphics.setColor(0.6, 1, 0.9, 0.8 * ctx.dim)
    love.graphics.printf(lane.label, lane.x - 20, lane.y - 7, 40, "center")
  end
  for _, t in ipairs(ctx.def.targets or {}) do
    love.graphics.setColor(0.9, 0.85, 0.65, 0.75 * ctx.dim)
    love.graphics.printf(t.bank:upper(), t.x - 32, t.y + 13, 64, "center")
  end
  local ready = m.charge >= mission.GOAL
  love.graphics.setColor(1, 0.78, 0.28, (ready and 1 or 0.6) * ctx.dim)
  love.graphics.printf(ready and "SHOOT PASS - JACKPOT" or "BUILD THE RELAY", 84, 608, 280, "center")
  for i = 1, mission.GOAL do
    love.graphics.setColor(1, 0.78, 0.28, (i <= m.charge and 0.95 or 0.12) * ctx.dim)
    love.graphics.circle("fill", 154 + (i - 1) * 20, 638, 6)
  end
  love.graphics.setColor(0.6, 0.95, 1, 0.8 * ctx.dim)
  for _, r in ipairs(ctx.def.ramps or {}) do
    for _, k in ipairs({ 1, #r.path - 1 }) do
      love.graphics.printf("SKYWAY", r.path[k] - 36, r.path[k + 1] + 8, 72, "center")
    end
  end
end

local function draw_nameplate(ctx, th)
  -- §7: the panel flags cross-board changes, so what you built on the board
  -- you are not looking at is never something you have to remember.
  local flash = fx and fx.panel_flash(ctx.def.id) or 0
  if flash > 0 then
    love.graphics.setColor(1, 0.78, 0.35, 0.75 * flash)
    love.graphics.setLineWidth(2 + 3 * flash)
    love.graphics.rectangle("line", ctx.view.x - 3, ctx.view.y - 3,
                            ctx.def.size.w * ctx.view.s + 6, ctx.def.size.h * ctx.view.s + 6, 10)
  end

  -- Board nameplate
  love.graphics.setFont(fonts.small)
  love.graphics.setColor(th.wall[1], th.wall[2], th.wall[3], ctx.active and 0.95 or 0.5)
  love.graphics.print(ctx.def.name:upper(), ctx.view.x, ctx.view.y - 15)
end

--- Draw one board: background, geometry, content, devices, ball, label.
local function draw_board(def, snap, prev, alpha, view, active, heat, incoming, bstate)
  local th  = THEME[def.id]
  local ctx = {
    def = def, snap = snap, prev = prev, alpha = alpha, view = view,
    active = active, dim = active and 1.0 or 0.45,
    heat = heat, incoming = incoming, bstate = bstate,
  }

  love.graphics.push()
  love.graphics.translate(view.x, view.y)
  love.graphics.scale(view.s)

  love.graphics.setColor(th.fill[1], th.fill[2], th.fill[3], active and 1 or 0.8)
  love.graphics.rectangle("fill", 0, 0, def.size.w, def.size.h, 8)

  -- The post parks below the playfield when retracted (that is what "sinks
  -- into the floor" means in the data), so clip to the board -- widened to
  -- the left, right and top by however far the ramps hang off the edge,
  -- because a ramp is above the playfield rather than on it and the board's
  -- rectangle is not its boundary.
  --
  -- The BOTTOM edge is deliberately not widened. That clip is the only thing
  -- hiding the parked post and guards, and a ramp reaching below the drain
  -- line would take them with it. A ramp under the flippers is not a shape
  -- any board wants; the parked furniture staying parked is.
  local sx0, sy0, sx1 = 0, 0, def.size.w
  local rx0, ry0, rx1 = ramps.board_bounds(def)
  if rx0 then
    sx0, sy0, sx1 = math.min(0, rx0), math.min(0, ry0), math.max(def.size.w, rx1)
  end
  love.graphics.setScissor(view.x + sx0 * view.s, view.y + sy0 * view.s,
                           (sx1 - sx0) * view.s, (def.size.h - sy0) * view.s)

  draw_shot_inserts(ctx)
  draw_drain_line(ctx)
  draw_shadows(ctx, th)
  draw_walls(ctx, th)
  draw_bumpers(ctx)
  draw_slingshots(ctx)
  draw_cross_board(ctx)
  draw_targets(ctx)
  draw_link(ctx)
  draw_devices(ctx)
  draw_guards(ctx)
  draw_flippers(ctx)
  -- The ramps go over everything they cross, and the ball goes over them:
  -- a ball underneath one still has to be findable, which is what the
  -- translucent lane is for.
  draw_ramps(ctx, th)
  draw_effects_and_ball(ctx)

  love.graphics.setScissor()
  love.graphics.pop()

  draw_nameplate(ctx, th)
end

---------------------------------------------------------------------------
-- Transit
---------------------------------------------------------------------------

--- The ball in flight, drawn between the two boards. §10: this beat gets its
--- own moment, and it doubles as the handoff telegraph.
local function draw_transit(state, defs)
  local t = state.transit
  if not t then return end
  local vf, vt = M.view[t.from], M.view[t.to]
  local mf = defs[t.from].tube.mouth
  local et = defs[t.to].entry

  local x0, y0 = vf.x + mf.x * vf.s, vf.y + mf.y * vf.s
  local x1, y1 = vt.x + et.x * vt.s, vt.y + et.y * vt.s
  local cx, cy = (x0 + x1) / 2, math.min(y0, y1) - 90   -- arc up over the gap

  local function at(u)
    local iu = 1 - u
    return iu*iu*x0 + 2*iu*u*cx + u*u*x1, iu*iu*y0 + 2*iu*u*cy + u*u*y1
  end

  local u = math.min(1, t.t / t.duration)

  love.graphics.setColor(0.45, 0.95, 0.6, 0.30)
  love.graphics.setLineWidth(3)
  local pts = {}
  for i = 0, 24 do
    local px, py = at(i / 24)
    pts[#pts+1], pts[#pts+2] = px, py
  end
  love.graphics.line(pts)

  -- The travelled part of the arc, brightened: the ball leaves a wake, so the
  -- direction of the pass is readable from a still frame.
  love.graphics.setColor(0.6, 1, 0.75, 0.55)
  love.graphics.setLineWidth(3)
  local wake = {}
  for i = 0, 16 do
    local px, py = at(u * i / 16)
    wake[#wake+1], wake[#wake+2] = px, py
  end
  if #wake >= 4 then love.graphics.line(wake) end

  local bx, by = at(u)
  love.graphics.setColor(0.6, 1, 0.75, 0.25)
  love.graphics.circle("fill", bx, by, 20)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.circle("fill", bx, by, 9)

  love.graphics.setFont(fonts.body)
  love.graphics.setColor(0.55, 0.95, 0.7, 0.9)
  local msg = ("SENDER: FLIPPERS AIM   |   IN TRANSIT %.2fs   %.0f px/s   RALLY %d")
    :format(t.duration - t.t, t.speed, state.stats.relay)
  love.graphics.printf(msg, 0, H - 74, W, "center")

  -- A bar under the readout, because "0.43s" is a number you have to read and
  -- a shrinking bar is one you can see while watching the board instead.
  local bw = 260
  love.graphics.setColor(1, 1, 1, 0.12)
  love.graphics.rectangle("fill", (W - bw) / 2, H - 52, bw, 5, 2)
  love.graphics.setColor(0.55, 0.95, 0.7, 0.85)
  love.graphics.rectangle("fill", (W - bw) / 2, H - 52, bw * (1 - u), 5, 2)
end

---------------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------------

local HA = 1     -- HUD opacity, set per frame by draw()
local function col(r, g, b, a) love.graphics.setColor(r, g, b, (a or 1) * HA) end

local function bar(x, y, w, h, p, r, g, b)
  col(1, 1, 1, 0.10)
  love.graphics.rectangle("fill", x, y, w, h, 3)
  col(r, g, b, 1)
  love.graphics.rectangle("fill", x, y, w * math.max(0, math.min(1, p)), h, 3)
end

--- Which board the panel is describing, and -- mid-pass -- how long
--- until the ball lands on it.
---@return number y
local function hud_header(state, def, x, y)
  love.graphics.setFont(fonts.head)
  local transit = state.phase == "transit"
  col(1, 1, 1, 0.92)
  -- "PREPARING" rather than "ON": during the pass nobody is standing on this
  -- board yet, and the sender needs to know the devices they are reaching for
  -- are the ones under the ball's landing point (prototype.md §4.5).
  local head = (transit and "PREPARING " or "ON ") .. def.name:upper()
  love.graphics.print(head, x, y)
  if transit then
    -- Measured, not offset by a guess: "GLASSHOUSE" is long enough that a
    -- fixed x+210 printed the countdown straight through the board name.
    love.graphics.setFont(fonts.small)
    col(0.55, 0.95, 0.7, 0.85)
    love.graphics.print(("BALL INCOMING  %.2fs"):format(state.transit.duration - state.transit.t),
                        x + fonts.head:getWidth(head) + 14, y + 9)
  end
  y = y + 30
  return y
end

--- §4: roles are implicit in ball position, so the panel only reports
--- them. Naming each player's actual keys matters because those keys
--- change meaning every time the ball crosses.
---@return number y
local function hud_roles(x, y, legend, active, transit)
  -- Roles: implicit in ball position, so just report them (§4).
  local roles = { [1] = intents.role_of(1, active), [2] = intents.role_of(2, active) }
  love.graphics.setFont(fonts.body)
  for p = 1, 2 do
    local flip = roles[p] == "flipper"
    col(flip and 1 or 0.45, flip and 0.78 or 0.6, flip and 0.25 or 0.85, 1)
    -- Mid-pass the receiver is not flipping yet, they are waiting to catch.
    local label = flip and (transit and "RECEIVING" or "FLIPPER") or "OPERATOR"
    local L = legend[p]
    love.graphics.print(("P%d  %s"):format(p, L.empty and "EMPTY" or label), x, y)
    if L.name then
      love.graphics.setFont(fonts.small)
      love.graphics.printf(L.name, x + 120, y - 12, 240, "left")
    end
    col(1, 1, 1, 0.35)
    love.graphics.setFont(fonts.small)
    love.graphics.print(flip
      and ("%s / %s"):format(L.flip_left, L.flip_right)
      or  (transit and "%s post  %s/%s AIM" or "%s post  %s/%s guard"):format(L.operator_paddle,
                                                   L.flip_left, L.flip_right), x + 120, y + 3)
    love.graphics.setFont(fonts.body)
    y = y + (L.name and 38 or 22)
  end
  return y
end

--- §7: what the cross-board loop wants next. Amber means act on this
--- board, blue means it wants a pass.
---@return number y
local function hud_objective(state, defs, x, y)
  -- What to do. The cross-board loop is the whole game and was previously
  -- visible only as two numbers moving; this says it in words (§7).
  y = y + 12
  local names = {}
  for id, d in pairs(defs) do names[id] = d.name end
  local obj = objective.current(state, names)
  local pulse = obj.urgent and (0.72 + 0.28 * math.abs(math.sin(state.time * 6))) or 1
  if obj.here then
    col(1, 0.86, 0.42, pulse)                       -- act on this board
  else
    col(0.55, 0.92, 1.0, pulse)                     -- it wants a pass
  end
  love.graphics.setFont(fonts.body)
  love.graphics.print(obj.text, x, y)
  if not obj.here then
    col(1, 1, 1, 0.35)
    love.graphics.setFont(fonts.small)
    love.graphics.print("on " .. (names[obj.board] or obj.board), x, y + 19)
  end
  y = y + 40
  return y
end

--- §6.1/§6.2: each operator device, its travel, and what it costs.
---@return number y
local function hud_devices(state, def, snaps, x, y, active)
  col(1, 1, 1, 0.5)
  love.graphics.setFont(fonts.small)
  love.graphics.print("OPERATOR DEVICES  (on " .. def.name .. ")", x, y)
  y = y + 18

  for _, d in ipairs(def.devices) do
    local p = snaps[active].devices[d.id].p
    local cmd = state.boards[active].devices[d.id].commanded
    love.graphics.setFont(fonts.body)
    col(1, 1, 1, 0.9)
    love.graphics.print(cmd and d.label_open or d.label_closed, x, y)
    bar(x + 92, y + 5, 150, 8, p, lerp(0.35, 1.0, p), lerp(0.45, 0.72, p), lerp(0.55, 0.20, p))
    love.graphics.setFont(fonts.small)
    col(1, 1, 1, 0.42)
    love.graphics.print(d.tradeoff, x, y + 19)
    y = y + 42
  end

  -- §6.2 The outlane guard. Which side it is on is the whole readout, so it
  -- is printed as a word rather than shown as a bar: "LEFT" and "RIGHT" are
  -- what the two of them are going to shout at each other.
  local ab   = state.boards[active]
  local side = ab.guard
  if side then
    local cool = ab.guard_cooldown or 0
    local gs   = snaps[active].guards[side]
    love.graphics.setFont(fonts.body)
    -- Spent, recharging, and armed have to be three visibly different things.
    -- The bar is the guard's own travel while it is armed and the cooldown
    -- filling while it is not, because those are the two waits that exist and
    -- only one of them is ever happening.
    if cool > 0 then
      col(0.55, 0.95, 1.0, 0.45)
      love.graphics.print(("GUARD %s in %.0fs"):format(side:upper(), math.ceil(cool)),
                          x, y)
      bar(x + 160, y + 5, 82, 8, 1 - cool / C.GUARD_COOLDOWN, 0.30, 0.55, 0.62)
    else
      col(0.55, 0.95, 1.0, 0.9)
      love.graphics.print(("GUARD %s"):format(side:upper()), x, y)
      bar(x + 92, y + 5, 150, 8, gs and gs.p or 0, 0.45, 0.95, 1.0)
    end
    love.graphics.setFont(fonts.small)
    col(1, 1, 1, 0.42)
    love.graphics.print(cool > 0
      and "Spent. Either button picks the lane it comes back to."
      or  "One save, then 30s gone. The other outlane is open either way.",
      x, y + 19)
    y = y + 42
  end
  return y
end

--- The prototype's instrument panel (§14). The multiplier is the biggest
--- thing on it because §9 puts the whole risk curve on relay heat.
---@return number y
local function hud_score(state, x, y)
  -- The prototype's instrument panel (§14: does the rally feel good?).
  -- The multiplier is the biggest thing on it on purpose: §9 puts the entire
  -- risk curve on relay heat, so it is the one number both players are
  -- deciding against every time they choose whether to pass.
  local st   = state.stats
  local heat = score.heat(st.relay)
  local hot  = math.min(1, (heat - 1) / (C.HEAT_MAX - 1))

  y = y + 8
  col(1, 1, 1, 0.45)
  love.graphics.setFont(fonts.small)
  love.graphics.print("SCORE", x, y)
  love.graphics.setFont(fonts.head)
  col(1, 1, 1, 0.92)
  love.graphics.print(commas(st.score), x + 60, y - 6)
  y = y + 30

  col(1, 1, 1, 0.45)
  love.graphics.setFont(fonts.small)
  love.graphics.print("RALLY", x, y + 12)
  love.graphics.setFont(fonts.huge)
  -- Green when cold, amber-hot as the multiplier climbs.
  col(lerp(0.55, 1.0, hot), lerp(0.95, 0.66, hot), lerp(0.70, 0.20, hot), 1)
  love.graphics.print(("x%d"):format(heat), x + 60, y)
  love.graphics.setFont(fonts.small)
  col(1, 1, 1, 0.5)
  love.graphics.print(("%d crossing%s"):format(st.relay, st.relay == 1 and "" or "s"),
                      x + 130, y + 6)
  col(1, 1, 1, 0.42)
  love.graphics.print(("worth %s   best rally %s")
    :format(commas(st.rally_score), commas(st.best_rally_score)), x + 130, y + 22)
  y = y + 48

  col(1, 1, 1, 0.35)
  love.graphics.print(("best run %d crossings    passes %d    drains %d")
    :format(st.best_relay, st.passes, st.drains), x, y)
  return y
end

--- Whatever the match is doing that is not play: serving, drained, or
--- the §8 rescue window, which is the most urgent thing the game ever
--- puts on screen.
local function hud_banner(state, defs, legend, active)
  -- Phase banner. Every offset below is a fraction of the board as drawn, not
  -- a pixel count: the board's own size and the window's are both variable now
  -- (see layout()), and a banner pinned at y+300 lands in a different part of
  -- a 960px board than of a 768px one.
  local vx, vy = M.view[active].x, M.view[active].y
  local vw = defs[active].size.w * M.view[active].s
  local bh = defs[active].size.h * M.view[active].s
  if state.phase == "serve" or state.phase == "drain" then
    love.graphics.setFont(fonts.head)
    col(1, 1, 1, 0.75)
    love.graphics.printf(state.phase == "drain" and "DRAINED" or "SERVING",
                         vx, vy + bh * 0.42, vw, "center")

  elseif state.phase == "purgatory" then
    -- §8. The single most urgent thing on screen, and it is addressed to the
    -- player who is NOT holding the ball -- naming their actual key, because
    -- roles swap constantly and "press post" is useless if you have to work
    -- out whose post it is with 1.9 seconds on the clock.
    local u = math.max(0, state.timer / C.PURGATORY_TIME)
    local partner = (intents.role_of(1, active) == "operator") and 1 or 2
    local key = legend[partner].operator_paddle
    local flash = 0.55 + 0.45 * math.abs(math.sin(state.time * 14))

    love.graphics.setColor(1, 0.30, 0.34, 0.16 * flash)
    love.graphics.rectangle("fill", vx, vy, vw, bh, 8)

    love.graphics.setFont(fonts.huge)
    love.graphics.setColor(1, 0.42, 0.46, flash)
    love.graphics.printf("SAVE IT", vx, vy + bh * 0.40, vw, "center")
    love.graphics.setFont(fonts.body)
    love.graphics.setColor(1, 1, 1, 0.92)
    love.graphics.printf(("P%d  press  %s"):format(partner, key:upper()),
                         vx, vy + bh * 0.462, vw, "center")

    -- What it will cost, so the decision is informed rather than reflexive.
    local charge = 0
    for _, b in pairs(state.boards) do
      for _, level in pairs(b.meters) do charge = charge + level end
    end
    if charge > 0 then
      love.graphics.setFont(fonts.small)
      love.graphics.setColor(1, 0.75, 0.45, 0.85)
      love.graphics.printf(("costs the vault charge  (x%d)"):format(charge),
                           vx, vy + bh * 0.493, vw, "center")
    end

    local bw = vw * 0.6
    love.graphics.setColor(1, 1, 1, 0.15)
    love.graphics.rectangle("fill", vx + (vw - bw) / 2, vy + bh * 0.527, bw, 8, 4)
    love.graphics.setColor(1, 0.42, 0.46, 0.95)
    love.graphics.rectangle("fill", vx + (vw - bw) / 2, vy + bh * 0.527, bw * u, 8, 4)
  end
end

--- The panel between the two boards. Split out of a 174-line function; each
--- helper draws one block and returns the y cursor for the next.
local function hud_mission(state, x, y)
  local m = state.boards[state.active].mission
  local ready = m.charge >= mission.GOAL
  love.graphics.setFont(fonts.small)
  col(0.6, 0.95, 0.9, 0.8)
  love.graphics.print("RELAY RUN  /  BUILD - PASS - CASH", x, y)
  love.graphics.setFont(fonts.head)
  col(1, 0.8, 0.35)
  love.graphics.print(ready and "JACKPOT READY" or ("CHARGE  %d / 8"):format(m.charge), x, y + 25)
  bar(x, y + 63, 310, 8, m.charge / mission.GOAL, 1, 0.78, 0.28)
  love.graphics.setFont(fonts.body)
  col(1, 1, 1, 0.8)
  love.graphics.print(ready and "Link open. Flipper: shoot PASS."
    or "Light lanes, hit targets, or ride the skyway.", x, y + 88)
  love.graphics.setFont(fonts.small)
  col(1, 1, 1, 0.5)
  love.graphics.print("Bumpers / new targets / new lanes +1   Bank / skyway +3", x, y + 114)
  love.graphics.print("8 charge lights a 2,500 jackpot. Pass to collect; repeat to grow it.", x, y + 134)
  love.graphics.print("All 3 lanes: +500   Skyway: +750   Skyway then pass: +1,500", x, y + 154)
  col(0.55, 0.95, 1)
  if (state.shot_notice_time or 0) > 0 then
    love.graphics.print(state.shot_notice, x, y + 185)
  elseif m.combo > 0 then
    love.graphics.print(("PASS COMBO LIT  %.1fs"):format(m.combo), x, y + 185)
  elseif m.notice_time > 0 then
    love.graphics.print(m.notice, x, y + 185)
  else
    love.graphics.print(("%d jackpots collected   %d skyway rides"):format(m.jackpots, m.rides), x, y + 185)
  end
end

local function draw_hud(state, defs, snaps, legend)
  local x, y   = M.hud_x, math.floor(H * 0.49)
  hud_mission(state, x, 52)
  local active = state.active
  local def    = defs[active]
  local transit = state.phase == "transit"

  y = hud_header(state, def, x, y)
  y = hud_roles(x, y, legend, active, transit)
  y = hud_objective(state, defs, x, y)
  y = hud_devices(state, def, snaps, x, y, active)
  hud_score(state, x, y)
  hud_banner(state, defs, legend, active)

  love.graphics.setFont(fonts.small)
  col(1, 1, 1, 0.28)
  love.graphics.print(legend[1].name and "GameNight: open the party to pause, replay or skip"
    or "R restart   P pause   1 debug   2 coords   3 reload   ESC quit",
                      M.hud_x, H - 26)
end

--- A paused game is one frame short of a hung one, and the difference has to
--- be legible instantly. It sits on the nameplate line, opposite the board's
--- name and clear of the playfield: pause is mostly used *with* the coordinate
--- overlay -- hold the ball still, read where it is against the geometry --
--- and a banner across the board would cover the thing being read.
local function draw_paused(defs, id)
  local v = M.view[id]
  local text = "|| PAUSED"
  local w = fonts.small:getWidth(text)
  local x = v.x + defs[id].size.w * v.s - w - 10
  local y = v.y - 17

  love.graphics.setColor(0.03, 0.03, 0.04, 0.85)
  love.graphics.rectangle("fill", x - 6, y - 1, w + 12, 15, 3)
  love.graphics.setFont(fonts.small)
  love.graphics.setColor(1, 0.86, 0.35, 1)
  love.graphics.print(text, x, y)
end

---------------------------------------------------------------------------
-- Notices
---------------------------------------------------------------------------

--- A hot reload has something to say and nowhere to say it: the terminal is
--- behind the game window, and a board file that fails to compile has to be
--- readable without alt-tabbing or the edit loop is still a two-window job.
---
--- Good news fades; bad news does not. A validation error or a geometry defect
--- stays on screen until the next reload clears it, because it is a to-do list
--- and the next save is exactly when you want to know whether it worked.
---@class Notice
---@field head string
---@field lines string[]
---@field kind string
---@field born number

---@type Notice|nil
local notice = nil

local NOTICE_FADE = 3.0
local NOTICE_MAX  = 8

local NOTICE_INK = {
  ok    = { 0.55, 1.00, 0.70 },
  warn  = { 1.00, 0.82, 0.35 },
  error = { 1.00, 0.45, 0.42 },
}

---@param head string one-line headline
---@param lines string[]|nil detail, e.g. validation errors
---@param kind "ok"|"warn"|"error"
function M.set_notice(head, lines, kind)
  notice = { head = head, lines = lines or {}, kind = kind or "ok",
             born = love.timer.getTime() }
end

function M.clear_notice() notice = nil end

local function notice_alpha()
  if not notice then return 0 end
  if notice.kind ~= "ok" then return 1 end
  local age = love.timer.getTime() - notice.born
  if age > NOTICE_FADE then return 0 end
  return math.min(1, (NOTICE_FADE - age) / 0.6)
end

local function draw_notice()
  local a = notice_alpha()
  if not notice or a <= 0.01 then return end
  local ink = NOTICE_INK[notice.kind] or NOTICE_INK.ok

  love.graphics.setFont(fonts.small)
  local shown = math.min(#notice.lines, NOTICE_MAX)
  local extra = #notice.lines - shown
  local rows  = shown + (extra > 0 and 1 or 0)
  local w, h  = math.min(760, W - 48), 26 + rows * 13
  local x, y  = (W - w) / 2, 12

  love.graphics.setColor(0.03, 0.03, 0.04, 0.93 * a)
  love.graphics.rectangle("fill", x, y, w, h, 5)
  love.graphics.setColor(ink[1], ink[2], ink[3], 0.85 * a)
  love.graphics.rectangle("line", x, y, w, h, 5)

  love.graphics.setFont(fonts.body)
  love.graphics.setColor(ink[1], ink[2], ink[3], a)
  love.graphics.print(notice.head, x + 10, y + 5)

  love.graphics.setFont(fonts.small)
  love.graphics.setColor(1, 1, 1, 0.75 * a)
  for i = 1, shown do
    love.graphics.printf(notice.lines[i], x + 10, y + 22 + (i - 1) * 13, w - 20, "left")
  end
  if extra > 0 then
    love.graphics.setColor(1, 1, 1, 0.45 * a)
    love.graphics.print(("... and %d more (full list in the terminal)"):format(extra),
                        x + 10, y + 22 + shown * 13)
  end
end


---------------------------------------------------------------------------

---@param flags table|nil { debug = boolean, paused = boolean }; the
---       coordinate overlay is a mode rather than a frame flag: M.inspect
function M.draw(match, legend, flags)
  flags = flags or {}
  love.graphics.clear(0.045, 0.045, 0.058)
  local state = match.state
  local heat  = heat_of(state)

  -- One shake for the whole frame, including the HUD: shaking the boards but
  -- not the panel next to them reads as a rendering fault rather than impact.
  local sx, sy = 0, 0
  if fx then sx, sy = fx.shake_offset() end
  love.graphics.push()
  love.graphics.translate(sx, sy)
  -- During transit the destination board counts as active: it is the one the
  -- operator is working on, and the one the ball is about to land on.
  local t = state.transit
  local incoming_u = t and math.min(1, t.t / t.duration) or nil
  for _, id in ipairs({ "a", "b" }) do
    draw_board(match.defs[id], match.cur[id], match.prev[id], match.alpha,
               M.view[id], id == state.active, heat,
               (t and id == t.to) and { u = incoming_u, aim = t.aim or 0 } or nil, state.boards[id])
  end
  if state.phase == "transit" then draw_transit(state, match.defs) end
  HA = M.hud_a
  if HA > 0.02 then draw_hud(state, match.defs, match.cur, legend) end
  HA = 1

  -- Inside the shake transform so the dots stay on the geometry they name,
  -- and after the HUD so nothing is drawn over the labels. The cursor is
  -- moved into the same frame rather than the overlay out of it -- one
  -- subtraction against re-deriving every point.
  if M.inspect and match.defs[M.inspect] then
    local mx, my
    if love.mouse and love.mouse.getPosition then
      mx, my = love.mouse.getPosition()
      mx, my = mx - sx, my - sy
    end
    inspect.draw(match.defs[M.inspect], M.view[M.inspect], fonts, mx, my, W)
  end
  love.graphics.pop()

  -- Outside the shake, which is frozen along with everything else that drives
  -- it, and drawn on the board the eye is on: the inspected one when there is
  -- one, otherwise the one with the ball.
  if flags.paused then draw_paused(match.defs, M.inspect or state.active) end
  draw_notice()

  if flags.debug then
    love.graphics.setFont(fonts.small)
    love.graphics.setColor(0.5, 1, 0.5, 0.8)
    local b = match.boards[state.active]
    -- Right-aligned: the HUD column moves from side to side, and a bottom-left
    -- readout collides with it when the HUD is on the left.
    love.graphics.printf(("tick %d  phase %s  fps %d  ball %.0f px/s  acc %.4f")
      :format(state.tick, state.phase, love.timer.getFPS(), b:ball_speed(), match.acc),
      0, H - 18, RIGHT_EDGE, "right")
  end
end

return M
