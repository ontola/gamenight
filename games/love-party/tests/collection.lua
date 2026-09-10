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

for count = 3, 4 do
	local seats, identities, controls = {}, {}, {}
	for i = 1, count do
		identities[i] = { id = tostring(i), name = "Player " .. i }
		seats[i] = { index = i - 1, occupant = { kind = "local", player_id = tostring(i) } }
		controls[i] = { x = 0, y = 0, aimX = 1, aimY = 0, action = true }
	end
	local match = tank.new(U.players(seats, identities), U.rng(1))
	assert(#match.players == count)
	tank.update(match, 0.01, controls)
	assert(#match.shots == count)
	for i, shot in ipairs(match.shots) do
		assert(shot.owner == match.players[i] and shot.owner.slot == i)
	end
end
print("PASS all three/four managed tank seats fire independently")

do
	local match = tank.new(roster(2), U.rng(1))
	match.cover = { { x = 400, y = 400, size = 44, hp = 3, flash = 0 } }
	local shooter, target = match.players[1], match.players[2]
	shooter.x, shooter.y = 330, 400
	target.x, target.y, target.invul = 450, 400, 0
	tank.update(match, 0.5, { { x = 1, y = 0 }, idle[2] })
	assert(shooter.x <= 360, "cover blocks tanks even at low frame rates")
	for hit = 1, 3 do
		match.shots = { { x = 350, y = 400, vx = 430, vy = 0, owner = shooter, ttl = 4, bounces = 0 } }
		tank.update(match, 0.3, idle)
		assert(#match.shots == 0 and target.score == 0, "cover absorbs the entire shot")
		if hit < 3 then
			assert(match.cover[1].hp == 3 - hit)
		end
	end
	assert(#match.cover == 0 and #match.debris > 0, "third hit destroys cover")
	tank.update(match, 0.5, { { x = 1, y = 0 }, idle[2] })
	assert(shooter.x > 400, "destroyed cover opens a route")
	assert(#tank.new(roster(4), U.rng(1)).cover == 12, "fresh rounds rebuild cover")
end
print("PASS destructible tank cover blocks movement, absorbs shots and opens routes")
