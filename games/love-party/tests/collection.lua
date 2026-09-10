local U = require("shared.util")
local function roster(n)
	local p = {}
	for i = 1, n do
		p[i] = { slot = i, name = "P" .. i, score = 0 }
	end
	return p
end
local idle = { { x = 0, y = 0 }, { x = 0, y = 0 } }
local paint = require("games.paint")
local s = paint.new(roster(2), U.rng(1))
s.players[2].x = s.players[1].x
s.players[2].y = s.players[1].y
paint.update(s, 0.01, idle)
assert(next(s.tiles) == nil, "contested paint must not favour a seat")
s.players[2].x = 1100
paint.update(s, 0.01, { { x = 0, y = 0, action = true }, idle[2] })
assert(s.players[1].score > 1)
local count = s.players[1].score
paint.update(s, 0.01, idle)
assert(s.players[1].score == count)
print("PASS paint contests, burst and ownership")
local tank = require("games.ricochet")
s = tank.new(roster(2), U.rng(1))
local p = s.players[1]
s.shots = { { x = 1200, y = 400, vx = 430, vy = 0, owner = p, ttl = 2, bounces = 0 } }
tank.update(s, 0.02, idle)
assert(s.shots[1].vx < 0 and s.shots[1].bounces == 1)
local target = s.players[2]
target.invul = 0
s.shots = { { x = target.x - 30, y = target.y, vx = 430, vy = 0, owner = p, ttl = 2, bounces = 0 } }
tank.update(s, 0.1, idle)
assert(p.score == 3 and target.score == -1)
target.invul = 0
target.shield = 0.5
s.shots = { { x = target.x - 30, y = target.y, vx = 430, vy = 0, owner = p, ttl = 2, bounces = 0 } }
tank.update(s, 0.1, idle)
assert(p.score == 3)
print("PASS ricochet bounce, hit and shield")
local orbit = require("games.orbit")
s = orbit.new(roster(2), U.rng(1))
s.rocks = { { angle = 0, r = 188, speed = 100 } }
orbit.update(s, 0.2, idle)
assert(s.kills == 1 and s.hp == 5)
s.rocks = { { angle = 1, r = 36, speed = 100 } }
orbit.update(s, 0.02, idle)
assert(s.hp == 4)
s.hp = 1
s.rocks = { { angle = 1, r = 36, speed = 100 } }
orbit.update(s, 0.02, idle)
assert(s.over)
local t = s.time
orbit.update(s, 1, idle)
assert(s.time == t)
print("PASS orbit interception, core damage and end")
for _, m in ipairs({ tank, paint, orbit }) do
	for n = 2, 4 do
		s = m.new(roster(n), U.rng(93))
		for _ = 1, 120 * 95 do
			local inputs = {}
			for i, pilot in ipairs(s.players) do
				inputs[i] = m.bot(s, pilot)
			end
			m.update(s, 1 / 120, inputs)
			for _, pilot in ipairs(s.players) do
				assert(pilot.x == pilot.x and pilot.y == pilot.y and math.abs(pilot.score) < 100000)
			end
			assert(not s.shots or #s.shots <= 80)
			assert(not s.rocks or #s.rocks <= 80)
		end
	end
	print("PASS " .. m.id .. " 2/3/4-player soak")
end

-- Tank fire leaves the aiming thumb free; other games keep their own controls.
do
	local input = require("shared.input")
	local buttons, trigger = {}, 0
	local pad = {
		isConnected = function()
			return true
		end,
		isGamepad = function()
			return true
		end,
		isGamepadDown = function(_, button)
			return buttons[button] or false
		end,
		getGamepadAxis = function(_, axis)
			if axis == "righty" then
				return -1
			end
			if axis == "triggerright" then
				return trigger
			end
			return 0
		end,
	}
	local keyboard = love.keyboard
	love.keyboard = {
		isDown = function()
			return false
		end,
	}
	input.bind({ { slot = 1 } }, { pad })
	buttons.a = true
	assert(not input.sample(1, tank.fireWithShoulder).action, "A is not tank fire")
	assert(input.sample(1).action, "other games retain A")
	buttons.a, buttons.rightshoulder = false, true
	local controls = input.sample(1, tank.fireWithShoulder)
	assert(controls.action and controls.aimY == -1, "RB fires while aiming")
	assert(not input.sample(1).action, "shoulder mapping is tank-only")
	local match = tank.new(roster(2), U.rng(1))
	tank.update(match, 0.01, { controls, idle[2] })
	assert(#match.shots == 1 and match.shots[1].vy < 0, "shot follows right-stick aim")
	buttons.rightshoulder = false
	trigger = 0.2
	assert(not input.sample(1, true).action, "trigger noise does not fire")
	trigger = 0.8
	assert(input.sample(1, true).action, "RT fires")
	trigger = 0
	assert(not input.sample(1, true).action, "release stops firing")
	love.keyboard = {
		isDown = function(key)
			return key == "space"
		end,
	}
	assert(input.sample(1, true).action, "keyboard fire still works")
	love.keyboard = keyboard
	input.bind({}, {})
	print("PASS tank shoulder fire, independent aim, trigger deadzone and keyboard")
end
