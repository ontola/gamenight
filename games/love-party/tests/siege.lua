local M = require("games.siege")
local U = require("shared.util")
local function fresh(n)
	local p = {}
	for i = 1, n or 2 do
		p[i] = { slot = i, name = "P" .. i, score = 0 }
	end
	local s = M.new(p, U.rng(42))
	s.enemies = {}
	return s
end
local function tick(s, dt)
	local inputs = {}
	for i in ipairs(s.players) do
		inputs[i] = { x = 0, y = 0 }
	end
	M.update(s, dt or 1 / 120, inputs)
end
local tests = {}
function tests.swept_hits_and_piercing()
	assert(M.segmentHit(0, 0, 100, 0, 50, 0, 2) == 0.48)
	assert(not M.segmentHit(0, 0, 100, 0, 50, 10, 2))
	local s = fresh()
	local a = M.spawn(s, "chaser", 350, 300, 0)
	local b = M.spawn(s, "chaser", 390, 300, 0)
	s.shots = { { x = 300, y = 300, vx = 14000, vy = 0, ttl = 1, hits = 3, hit = {}, owner = s.players[1] } }
	tick(s)
	assert(a.dead and b.dead and s.kills == 2)
	assert(s.players[1].score == s.teamScore and s.players[2].score == s.teamScore)
end
function tests.invulnerability_dash_and_team_wipe()
	local s = fresh()
	local p = s.players[1]
	assert(not M.hurt(s, p))
	p.invul = 0
	p.dash = 0.1
	assert(not M.hurt(s, p))
	p.dash = 0
	assert(M.hurt(s, p) and p.hp == 2)
	assert(not M.hurt(s, p))
	for _, v in ipairs(s.players) do
		v.hp = 0
		v.downTime = 0
	end
	for _ = 1, 250 do
		tick(s)
	end
	assert(s.over)
	local t = s.time
	tick(s)
	assert(s.time == t)
end
function tests.revive_requires_surviving_teammate()
	local s = fresh()
	local a, b = s.players[1], s.players[2]
	a.hp = 0
	a.downTime = 0
	b.x = a.x + 30
	for _ = 1, 150 do
		s.enemies = {}
		tick(s)
	end
	assert(a.hp == 3 and a.invul > 0)
end
function tests.pulse_splitters_caps_and_cooldown()
	local s = fresh()
	local p = s.players[1]
	local e = M.spawn(s, "splitter", p.x + 60, p.y, 0)
	s.hostile = { { x = p.x, y = p.y, vx = 0, vy = 0, ttl = 1 } }
	assert(M.pulse(s, p))
	assert(e.dead and #s.enemies == 4 and #s.hostile == 0)
	assert(not M.pulse(s, p))
	for _ = 1, 300 do
		M.spawn(s, "chaser", 100, 200, 0)
	end
	assert(#s.enemies == M.limits.enemies)
end
function tests.powerups_expire_and_shots_do_not_hurt_friends()
	local s = fresh()
	local p = s.players[1]
	s.pickups = { { x = p.x, y = p.y, kind = "spread", ttl = 2 } }
	tick(s)
	assert(p.power == "spread")
	s.shots = {}
	p.fireClock = 0
	tick(s)
	assert(#s.shots == 3)
	p.powerTime = 0.001
	tick(s)
	assert(p.power == nil)
	p.invul = 0
	s.shots = { { x = p.x - 25, y = p.y, vx = 6000, vy = 0, ttl = 1, hits = 1, hit = {}, owner = s.players[2] } }
	tick(s)
	assert(p.hp == 3)
end
function tests.right_stick_is_independent_and_has_deadzone()
	local input = require("shared.input")
	local right = 0.7
	local pad = {
		isConnected = function()
			return true
		end,
		isGamepad = function()
			return true
		end,
		isGamepadDown = function()
			return false
		end,
		getGamepadAxis = function(_, axis)
			return axis == "rightx" and right or 0
		end,
	}
	input.bind({ { slot = 1 } }, { pad })
	local c = input.sample(1)
	assert(c.x == 0 and c.aimX == 0.7)
	right = 0.1
	assert(input.sample(1).aimX == 0)
	input.bind({}, {})
end
function tests.bounded_four_player_stress()
	local started = love.timer.getTime()
	local peak = 0
	for n = 2, 4 do
		local s = fresh(n)
		for frame = 1, 120 * 90 do
			local inputs = {}
			for i, p in ipairs(s.players) do
				p.invul = 1
				inputs[i] = M.bot(s, p)
			end
			M.update(s, 1 / 120, inputs)
			peak = math.max(peak, #s.enemies)
			for key, limit in pairs(M.limits) do
				assert(#s[key] <= limit, key .. " exceeded budget")
			end
			for _, p in ipairs(s.players) do
				assert(p.x == p.x and p.y == p.y and p.hp == 3)
			end
		end
		assert(s.kills > 100 and s.wave >= 9)
	end
	print(
		string.format(
			"Neon Siege: 270 simulated seconds in %.2fs; peak %d enemies",
			love.timer.getTime() - started,
			peak
		)
	)
end
for name, test in pairs(tests) do
	test()
	print("PASS siege " .. name)
end
