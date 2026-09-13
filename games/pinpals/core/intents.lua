--- §5.1 The intent layer.
--- Game logic never reads a keyboard. Everything downstream of here sees only
--- tick-stamped intents, so local play and (later) online play share one path.
--- Pure Lua. No love.* here.

---@class Intent
---@field player  1|2
---@field action  string
---@field pressed boolean
---@field tick    integer

local M = {}

--- The complete action vocabulary. Bindings map devices onto these; nothing
--- downstream knows whether an intent came from a key or a gamepad (§9).
M.ACTIONS = {
  flip_left      = true,  -- flipper role: left flipper on the active board
  flip_right     = true,  -- flipper role: right flipper on the active board
  operator_gate  = true,  -- operator role: gate on the active board
  operator_paddle= true,  -- operator role: paddle on the active board
}

M.FLIPPER_ACTIONS  = { flip_left = true, flip_right = true }
M.OPERATOR_ACTIONS = { operator_gate = true, operator_paddle = true }

---@param player 1|2
---@param action string
---@param pressed boolean
---@param tick integer
---@return Intent
function M.new(player, action, pressed, tick)
  assert(player == 1 or player == 2, "intent: bad player")
  assert(M.ACTIONS[action], "intent: unknown action " .. tostring(action))
  return { player = player, action = action, pressed = pressed and true or false, tick = tick }
end

--- Which board a player calls home. Board ownership decides roles: the owner of
--- the board holding the ball is the FLIPPER, the other player is the OPERATOR
--- acting on that same board (design.md §4).
M.HOME = { [1] = "a", [2] = "b" }

---@param player 1|2
---@param active_board "a"|"b"
---@return "flipper"|"operator"
function M.role_of(player, active_board)
  return M.HOME[player] == active_board and "flipper" or "operator"
end

return M
