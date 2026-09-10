local modes = {
	require("games.bumper"),
	require("games.trails"),
	require("games.meteor"),
	require("games.blast"),
	require("games.siege"),
	require("games.ricochet"),
	require("games.paint"),
	require("games.orbit"),
}
local U = require("shared.util")
local Input = require("shared.input")
local Lifecycle = require("shared.lifecycle")
local Render = require("shared.render")
local Screen = require("shared.window")
local Audio = require("shared.audio")
local state, bridge, mode, remaining, finished, accumulator
local selected, count, menu = 1, 2, true
local managed = os.getenv("GAMENIGHT") == "1"
local duration = tonumber(os.getenv("GNLOVE_MATCH_SECONDS"))
if duration then
	duration = U.clamp(duration, 1, 600)
end
local function pads()
	return love.joystick and love.joystick.getJoysticks() or {}
end
local function prepare(seats, players)
	local roster = U.players(seats, players)
	Input.bind(roster, pads())
	state = mode.new(roster, U.rng(tonumber(os.getenv("GNLOVE_SEED")) or os.time()))
	remaining, finished, accumulator = duration or mode.duration or 60, false, 0
	menu = false
end
local function standalone()
	mode = modes[selected]
	local seats, players = {}, {}
	for i = 1, count do
		seats[i] = {
			index = i - 1,
			occupant = {
				kind = os.getenv("GNLOVE_DEMO") == "1" and "ai" or "local",
				player_id = tostring(i),
			},
		}
		players[i] = { id = tostring(i), name = ({ "MINT", "CORAL", "GOLD", "VIOLET" })[i] }
	end
	prepare(seats, players)
	Audio.enabled = true
end
function love.load(args)
	if os.getenv("GNLOVE_TEST") == "1" then
		local ok, err = pcall(function()
			require("tests.run")
		end)
		if not ok then
			print(err)
		end
		love.event.quit(ok and 0 or 1)
		return
	end
	local game = os.getenv("GAMENIGHT_GAME_ID") or os.getenv("GNLOVE_GAME")
	local ok, config = pcall(require, "game")
	if not game and ok then
		game = config.id
	end
	for _, v in ipairs(args or {}) do
		game = v:match("^%-%-game=(.+)$") or game
	end
	for i, m in ipairs(modes) do
		if m.id == game then
			selected = i
		end
	end
	mode = modes[selected]
	if love.graphics then
		Render.load()
	end
	Audio.load()
	if managed then
		bridge = Lifecycle.new(
			require("shared.transport").new(
				os.getenv("GAMENIGHT_ADDR") or "127.0.0.1:7912",
				game,
				os.getenv("GAMENIGHT_TOKEN")
			),
			{
				hide = function()
					Audio.mute()
					Screen.hide()
				end,
				show = function()
					Audio.enabled = true
					Screen.show()
				end,
				prepare = prepare,
				dispose = function()
					state = nil
					Input.bind({}, {})
				end,
				quit = function(err)
					print("GameNight disconnected: " .. tostring(err))
					love.event.quit()
				end,
			},
			game
		)
	elseif game or os.getenv("GNLOVE_DEMO") == "1" then
		standalone()
	end
end
function love.update(dt)
	if os.getenv("GNLOVE_TEST") == "1" then
		return
	end
	if bridge then
		bridge:update()
	end
	if not state or finished or (bridge and bridge.phase ~= "running") then
		return
	end
	accumulator = accumulator + math.min(dt, 0.1)
	while accumulator >= 1 / 120 and not finished do
		local inputs = {}
		for i, p in ipairs(state.players) do
			inputs[i] = p.bot and mode.bot(state, p) or Input.sample(p.slot)
		end
		local before = {}
		for i, p in ipairs(state.players) do
			before[i] = p.score
		end
		local events = {}
		for name, value in pairs(state.sfx or {}) do
			events[name] = value
		end
		local blasts = state.blastCount or 0
		mode.update(state, 1 / 120, inputs)
		if (state.blastCount or 0) > blasts then
			Audio.play("blast")
		end
		for name, value in pairs(state.sfx or {}) do
			if value > (events[name] or 0) then
				Audio.play(name)
			end
		end
		for i, p in ipairs(state.players) do
			if not mode.coop and p.score - before[i] >= 3 then
				Audio.play("point")
			elseif not mode.coop and p.score < before[i] then
				Audio.play("hit")
			end
		end
		remaining = math.max(0, remaining - 1 / 120)
		accumulator = accumulator - 1 / 120
		if remaining == 0 or state.over then
			finished = true
			Audio.play("finish")
			if bridge then
				bridge:finish()
			end
		end
	end
end
function love.draw()
	if os.getenv("GNLOVE_TEST") == "1" then
		return
	end
	if managed and bridge.phase ~= "running" and bridge.phase ~= "finished" then
		return
	end
	if menu then
		Render.menu(modes, selected, count)
	elseif state then
		Render.game(mode, state, remaining, finished, managed)
	end
end
function love.keypressed(key)
	if managed then
		if key == "escape" or key == "backspace" then
			bridge:back()
		end
		return
	end
	if key == "escape" then
		menu = true
		state = nil
	elseif menu then
		if tonumber(key) and tonumber(key) >= 1 and tonumber(key) <= #modes then
			selected = tonumber(key)
		elseif key == "f2" then
			count = count == 4 and 2 or count + 1
		elseif key == "return" then
			standalone()
		end
	elseif finished and key == "return" then
		standalone()
	end
end
function love.gamepadpressed(_, button)
	if managed then
		if button == "back" then
			bridge:back()
		end
	elseif button == "a" and (menu or finished) then
		standalone()
	elseif button == "back" then
		menu = true
		state = nil
	elseif menu and button == "dpright" then
		selected = selected % #modes + 1
	elseif menu and button == "dpleft" then
		selected = (selected + #modes - 2) % #modes + 1
	end
end
function love.joystickadded(pad)
	Input.attach(pad)
end
function love.joystickremoved(pad)
	Input.detach(pad)
end
function love.quit()
	if bridge then
		bridge:dispose()
		bridge.transport:close()
	end
end

function love.focus(focused)
	if focused and bridge and (bridge.phase == "ready" or bridge.phase == "paused") then
		bridge.transport:send({ type = "request_start" })
	end
end
