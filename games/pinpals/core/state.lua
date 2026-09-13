--- §5.2 The authoritative match state.
--- One serializable object. No gameplay state lives in the renderer, in
--- closures, or in module-level locals. Written as if there were a server, so
--- that "online" later means "one player hosts", not a rewrite.
---
--- Pure Lua. No love.* here, so this whole file is testable in bare `lua`.

local C       = require("core.constants")
local intents = require("core.intents")
local score   = require("core.score")

local mission = require("core.mission")

local M = {}

local OTHER = { a = "b", b = "a" }

--- Which device each operator action drives.
local DEVICE_OF = { operator_gate = "gate", operator_paddle = "post" }

---@param boards table<string, table>
---@return table state
function M.new(boards)
  local s = {
    tick   = 0,
    time   = 0,
    phase  = "serve",   -- "serve" | "play" | "transit" | "drain"
    timer  = C.SERVE_DELAY,
    active = "a",
    transit = nil,
    boards = {},
    -- Not scoring (§14 puts scoring out of scope). These are the instruments
    -- for the one question the prototype exists to answer: does the rally
    -- feel good? Relay length is the readout.
    stats = {
      passes = 0, drains = 0, relay = 0, best_relay = 0,
      -- §9. `score` is the session record; `rally_score` is what the current
      -- rally has been worth and dies with it, so `best_rally_score` is the
      -- one that says how good these two got together.
      score = 0, rally_score = 0, best_rally_score = 0, rescues = 0,
    },
    -- Which board each player's held operator key was pressed on, so its
    -- release can follow it across a role swap. Plain data (§5.2).
    held = { [1] = {}, [2] = {} },
  }
  for id, def in pairs(boards) do
    local b = {
      mission = mission.new(), lane_count = #(def.rollovers or {}),
      id = id, flippers = { left = false, right = false },
      devices = {}, targets = {}, banks = {},
      -- §7 cross-board state. `meters` is what the OTHER board has been
      -- filling up here and this board can cash; `lit` is what the other
      -- board has switched on here. Both are plain numbers so the whole
      -- state stays serializable (§5.2), and both survive the ball leaving
      -- -- that is the point: the dormant board keeps what you built.
      meters = {}, lit = {}, links = def.links or {},
      -- §6.2 The outlane guard: which side the barrier is currently across.
      -- One value, not two booleans, because the whole point is that it can
      -- only ever be on one side and choosing is the cost.
      guard = def.guards and def.guards.start or nil,
      -- Seconds until the bar can deploy again. It is a number rather than a
      -- boolean because the operator has to be able to see it coming back:
      -- "eight seconds" is a thing you can plan around, "not yet" is not.
      guard_cooldown = 0,
    }
    for _, d in ipairs(def.devices) do
      -- `commanded` is a rule-level fact: what the operator has asked for.
      -- Where the device physically *is* belongs to sim/, not here.
      b.devices[d.id] = { commanded = false }
    end
    -- Which targets make up which bank, resolved once here rather than
    -- rediscovered from the definitions on every hit. Plain data, so the
    -- whole state stays serializable (§5.2).
    for i, t in ipairs(def.targets or {}) do
      b.targets[i] = { lit = false, bank = t.bank }
      local bank = b.banks[t.bank]
      if not bank then bank = { members = {}, cleared = 0 }; b.banks[t.bank] = bank end
      bank.members[#bank.members+1] = i
      b.meters[t.bank] = b.meters[t.bank] or 0
    end
    b.lit.bumpers = 0
    s.boards[id] = b
  end
  return s
end

--- Roles are implicit in ball position; there is no role-select UI (§4).
--- The owner of the active board flips; the other player operates that board.
---@param s table
---@param it Intent
function M.apply_intent(s, it)
  local role  = intents.role_of(it.player, s.active)
  local board = s.boards[s.active]
  if not board then return end

  -- During flight the sender aims the receiver's launch instead of toggling
  -- the guard. Keep held aiming input local to this pass.
  if s.phase == "transit" and s.transit and role == "operator"
     and intents.FLIPPER_ACTIONS[it.action] then
    s.transit[it.action] = it.pressed
    return
  end

  -- §6.2 The outlane guard. The operator's flipper buttons are the two
  -- controls their role otherwise leaves them nothing to do with, so they
  -- move the barrier: either button switches it to the other outlane.
  --
  -- Either button rather than "left button, left lane" on purpose. The
  -- operator is looking at a board that is not theirs, being shouted at, and
  -- the only question they have to answer is "the other side?" -- which is
  -- one bit, and deserves one control, not a mapping to get backwards.
  --
  -- Presses only. A toggle that also fired on release would flip twice per
  -- tap and land back where it started.
  --
  -- Switching sides is allowed while the guard is spent, and that is not an
  -- oversight: a recharging guard is still a decision, because the operator
  -- is choosing where it comes back. The renderer draws the empty outline on
  -- the chosen side filling up, so the choice is visible before it matters.
  if role == "operator" and intents.FLIPPER_ACTIONS[it.action] then
    if it.pressed and board.guard then
      board.guard = (board.guard == "left") and "right" or "left"
    end
    return
  end

  if role == "flipper" then
    if it.action == "flip_left" or it.action == "flip_right" then
      if s.phase ~= "play" then return end
      if it.action == "flip_left"  then board.flippers.left  = it.pressed end
      if it.action == "flip_right" then board.flippers.right = it.pressed end
      return
    end
    -- A flipper still has to be able to LET GO of a device they were holding
    -- as operator. Falling through here instead discards the release, which
    -- is the bug below.
    if it.pressed or not s.held[it.player][it.action] then return end
  end

  -- The operator acts on the active board at all times, including during
  -- transit: that 800ms is the sender's chance to prepare the landing.
  --
  -- A release, though, belongs to the board the PRESS went to. Roles swap on
  -- every crossing, so a player can press the gate as operator on board A and
  -- still be holding it when the ball lands on B and makes them the flipper.
  -- Routing that release to the active board would close a gate on the wrong
  -- table; discarding it -- which is what this did -- left board A's gate
  -- commanded open forever with the player's finger off the key, and §6.2
  -- makes an open gate close the safe return loop. It righted itself only
  -- after a full press-and-release once that player was the operator again.
  --
  -- §7 still holds: a press-and-release BEFORE passing leaves the board set
  -- up the way the operator left it, because the release lands on the board
  -- that was prepared.
  local target = it.pressed and s.active or s.held[it.player][it.action]
  s.held[it.player][it.action] = it.pressed and s.active or nil
  local tboard = target and s.boards[target]
  if not tboard then return end

  local id = DEVICE_OF[it.action]
  local d  = id and tboard.devices[id]
  if d then d.commanded = it.pressed end
end

---@param s table
---@param list Intent[]
function M.apply_intents(s, list)
  for _, it in ipairs(list) do M.apply_intent(s, it) end
end

--- Release every flipper on every board. Used when the ball leaves, so a held
--- key doesn't leave a flipper stuck up on a board nobody is looking at.
local function release_flippers(s)
  for _, b in pairs(s.boards) do
    b.flippers.left, b.flippers.right = false, false
  end
end

--- Advance non-physics match flow by one fixed step.
--- Pure: returns the commands sim/ should carry out. Never touches physics.
---@param s table
---@return table[] commands
function M.update(s)
  local dt = C.FIXED_DT
  s.tick = s.tick + 1
  s.time = s.time + dt
  s.shot_notice_time = math.max(0, (s.shot_notice_time or 0) - dt)
  -- One-frame signal for app/: what was just scored and where. Cleared here
  -- rather than by the reader, so nothing depends on someone remembering to.
  s.last_award = nil
  s.rescue     = nil
  local cmds = {}

  -- §6.2 The outlane guard recharges on wall-clock time, on BOTH boards and
  -- in every phase. A cooldown that only ran on the active board would mean a
  -- guard spent on Foundry is still spent when you come back to it ten passes
  -- later, which turns a per-ball cost into a permanent one.
  for id, b in pairs(s.boards) do
    mission.update(b.mission, dt, s.phase == "play" and s.active == id)
    if (b.guard_cooldown or 0) > 0 then
      b.guard_cooldown = math.max(0, b.guard_cooldown - dt)
    end
  end

  if s.phase == "serve" then
    s.timer = s.timer - dt
    if s.timer <= 0 then
      s.phase = "play"
      cmds[#cmds+1] = { kind = "serve", board = s.active }
    end

  elseif s.phase == "purgatory" then
    -- §8. The ball is falling but not yet gone. The partner can pull it back
    -- by raising the post on the board that lost it -- which they could not
    -- already have been holding, because a raised post is why the ball would
    -- not have drained in the first place.
    s.timer = s.timer - dt
    local board = s.boards[s.active]
    local post  = board and board.devices.post
    -- Releasing a post that was up at the moment of the drain arms the
    -- rescue: the operator can still make the save, but they have to do
    -- something to make it.
    if post and not post.commanded then s.rescue_armed = true end
    if post and post.commanded and s.rescue_armed then
      -- Rescued. The rally survives, which is the whole point: what the two
      -- of them built together is not thrown away by one bad bounce.
      --
      -- The cost is §6.2's rule applied to the biggest save in the game:
      -- every vault charge on both boards is spent. You can keep the rally
      -- or keep the preparation, not both, and the operator has to decide
      -- that in well under two seconds while being shouted at.
      local spent = 0
      for _, b in pairs(s.boards) do
        for name, level in pairs(b.meters) do
          spent = spent + level
          b.meters[name] = 0
        end
      end
      s.stats.rescues = s.stats.rescues + 1
      s.rescue_armed  = nil
      s.rescue = { spent = spent }
      s.phase  = "serve"
      s.timer  = C.SERVE_DELAY
    elseif s.timer <= 0 then
      -- Gone. Now the rally and everything it was worth go with it.
      s.phase = "drain"
      s.timer = C.DRAIN_DELAY
      s.stats.drains = s.stats.drains + 1
      s.stats.relay  = 0
      score.end_rally(s.stats)
      -- §6.2: and the guard comes back with the new ball, on BOTH boards.
      --
      -- The cooldown is what makes the save scarce WITHIN a ball; charging
      -- it against the next one as well is a different and much worse thing,
      -- because the player who spends it is not the player who pays. 30s is
      -- longer than a ball lives, so without this a save near the end of one
      -- ball silently disarms the start of the next two.
      --
      -- Both boards, because a drain ends the rally for both of them -- the
      -- same reason score.end_rally above takes the whole rally score and not
      -- the half of it earned on the board that dropped it.
      --
      -- Note this is the DRAIN branch, not purgatory: a rescue (§8) means the
      -- ball was never lost, so it keeps the rally AND keeps the guard spent.
      -- You do not get a fresh save for nearly dropping it.
      for _, b in pairs(s.boards) do b.guard_cooldown = 0 end
    end

  elseif s.phase == "drain" then
    s.timer = s.timer - dt
    if s.timer <= 0 then
      s.phase = "serve"
      s.timer = C.SERVE_DELAY
    end

  elseif s.phase == "transit" then
    local t = s.transit
    local steer = (t.flip_left and 1 or 0) - (t.flip_right and 1 or 0)
    t.aim = math.max(-C.TRANSIT_AIM_LIMIT, math.min(C.TRANSIT_AIM_LIMIT,
      (t.aim or 0) + steer * C.TRANSIT_AIM_RATE * dt))
    t.t = t.t + dt
    if t.t >= t.duration then
      s.phase = "play"
      s.transit = nil
      cmds[#cmds+1] = { kind = "arrive", board = t.to, speed = t.speed, aim = t.aim }
    end
  end

  return cmds
end

--- Fire every link on `from` whose trigger matches, against the whole state.
--- Links are board data (§5.3), so adding a new cross-board relationship is a
--- table entry rather than a branch in here.
---@param s table
---@param from string board id the trigger happened on
---@param trigger string "bumper" | "bank:<name>"
local function fire_links(s, from, trigger)
  for _, l in ipairs(s.boards[from].links or {}) do
    if l.when == trigger then
      if l.charges then
        local dest = s.boards[l.charges.board]
        local m = l.charges.meter
        if dest and dest.meters[m] then
          dest.meters[m] = math.min(C.CHARGE_MAX, dest.meters[m] + 1)
        end
      elseif l.lights then
        local dest = s.boards[l.lights.board]
        if dest then dest.lit[l.lights.what] = C.LIT_HITS end
      end
    end
  end
end

--- Fold events reported by sim/ back into the rules.
---@param s table
---@param events table[]
function M.consume(s, events)
  for _, ev in ipairs(events) do
    if ev.kind == "tube" and s.phase == "play" then
      local from = ev.board
      local to   = OTHER[from]
      -- §5: the pass carries state. Exit speed survives the trip, clamped so a
      -- desperate flail still arrives fast and a dribble still arrives moving.
      -- §9 "worth more, and moving faster": heat scales the arrival before
      -- the clamp, so a hot rally lands harder and is genuinely harder to
      -- hold. The clamp still has the last word, so this can never outrun the
      -- ball's own ceiling or the tunneling budget behind it.
      local scaled = ev.speed * score.speed_scale(s.stats.relay)
      local speed = math.max(C.TRANSIT_MIN_SP, math.min(C.TRANSIT_MAX_SP, scaled))
      release_flippers(s)
      s.phase   = "transit"
      s.transit = { from = from, to = to, t = 0, duration = C.TRANSIT_TIME, speed = speed, aim = 0 }
      -- The destination board becomes active immediately: for the ~800ms of
      -- flight the sender is already the operator over there, rearranging the
      -- floor the ball is about to land on.
      s.active  = to
      s.stats.passes = s.stats.passes + 1
      s.stats.relay  = s.stats.relay + 1
      if s.stats.relay > s.stats.best_relay then s.stats.best_relay = s.stats.relay end
      -- Awarded at the NEW heat: the crossing that makes the rally hotter is
      -- itself worth the hotter rate, so the escalation is visible on the
      -- pass that earned it rather than one pass late.
      s.last_award = { kind = "pass", value = score.award(s.stats, "pass") + mission.shot(s, ev), board = to }

    elseif ev.kind == "target" and s.phase == "play" then
      local board = s.boards[ev.board]
      local t = board and board.targets[ev.index]
      if t then
        -- A standup scores every time it is struck, the way a real one does,
        -- but only counts once toward its bank. Otherwise the cheapest way to
        -- clear a bank is to rattle against a single target.
        local total = score.award(s.stats, "target")
        if not t.lit then
          t.lit = true
          mission.charge(board.mission, 1)
          local bank = board.banks[t.bank]
          if bank and M.bank_complete(board, bank) then
            -- §7's payoff. The bonus is scaled by everything the partner
            -- board charged into this meter, so clearing a vault Foundry has
            -- been filling is worth many times clearing a cold one -- which
            -- is what makes "play A to prepare B" a real sentence rather
            -- than a description of nothing.
            local charge = board.meters[t.bank] or 0
            total = total + score.award(s.stats, "bank", 1 + charge)
            board.meters[t.bank] = 0
            bank.cleared = bank.cleared + 1
            mission.charge(board.mission, 3)
            for _, mi in ipairs(bank.members) do board.targets[mi].lit = false end
            fire_links(s, ev.board, "bank:" .. t.bank)
          end
        end
        s.last_award = {
          kind = "target", value = total, board = ev.board, x = ev.x, y = ev.y,
        }
      end

    elseif ev.kind == "sling" and s.phase == "play" then
      -- Cheap, unaimed, and constant: the slingshots are what keep a ball that
      -- came down the side in play at all. They deliberately do NOT feed the
      -- §7 cross-board links -- a charge you get for free is a charge that
      -- stops being something you went and did.
      s.last_award = {
        kind = "sling", value = score.award(s.stats, "sling"),
        board = ev.board, x = ev.x, y = ev.y,
      }

    elseif ev.kind == "guard" and s.phase == "play" then
      -- §6.2's trade, paying out, ONCE. The contact spends the guard: it
      -- retracts on the next step and cannot come back for GUARD_COOLDOWN
      -- seconds, so this is a save the two of them have to decide to spend
      -- rather than a lane they closed.
      --
      -- The cooldown check is also what makes "once" exact. The bar takes
      -- 300ms to retract and can catch the ball again on its way down; that
      -- second contact is the same save and must not score twice or re-arm
      -- the timer a fresh one would have started.
      local board = s.boards[ev.board]
      if board and (board.guard_cooldown or 0) <= 0 then
        board.guard_cooldown = C.GUARD_COOLDOWN
        s.last_award = {
          kind = "guard", value = score.award(s.stats, "guard"),
          board = ev.board, x = ev.x, y = ev.y,
        }
      end

    elseif ev.kind == "bumper" and s.phase == "play" then
      local board = s.boards[ev.board]
      -- A lit bumper is the payoff coming home: Glasshouse cleared its vault,
      -- and Foundry's cheap chaos is briefly worth LIT_MULT times as much.
      local boost = 1
      if (board.lit.bumpers or 0) > 0 then
        boost = C.LIT_MULT
        board.lit.bumpers = board.lit.bumpers - 1
      end
      s.last_award = {
        kind = "bumper", value = score.award(s.stats, "bumper", boost),
        board = ev.board, x = ev.x, y = ev.y, boosted = boost > 1,
      }
      fire_links(s, ev.board, "bumper")
      mission.charge(board.mission, 1)

    elseif (ev.kind == "rollover" or ev.kind == "ramp") and s.phase == "play" then
      local value = mission.shot(s, ev)
      if value > 0 then
        s.last_award = { kind = ev.kind, value = value, board = ev.board, x = ev.x, y = ev.y }
      end

    elseif ev.kind == "drain" and s.phase == "play" then
      s.boards[ev.board].mission.combo = 0
      -- Not dead yet (§8). The rally, the score it has earned and the drain
      -- count all stay untouched until purgatory actually expires, so a
      -- rescue costs the team nothing it had already earned.
      release_flippers(s)
      s.phase = "purgatory"
      s.timer = C.PURGATORY_TIME
      -- The rescue has to be an ACTION taken inside the window, not a state
      -- that happens to be true. A post already commanded when the ball
      -- drained -- still travelling, or simply left up -- would otherwise
      -- rescue for free, and a 10-minute soak of random play produced 29
      -- rescues against 1 drain: the ball essentially never died. So arm on
      -- the post being DOWN, and require a fresh raise.
      local post = s.boards[s.active].devices.post
      s.rescue_armed = not (post and post.commanded)
    end
  end
end

--- Is every target in this bank lit?
---@param board table per-board state
---@param bank table
---@return boolean
function M.bank_complete(board, bank)
  for _, i in ipairs(bank.members) do
    if not board.targets[i].lit then return false end
  end
  return true
end

--- Convenience for the renderer and for tests: what is each player doing?
---@param s table
---@return table<1|2, "flipper"|"operator">
function M.roles(s)
  return { [1] = intents.role_of(1, s.active), [2] = intents.role_of(2, s.active) }
end

M.OTHER = OTHER

return M
