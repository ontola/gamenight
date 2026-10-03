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
function tests.bots_patrol_but_do_not_fire_without_targets()
	local s=fresh(1)
	s.waveRest=10
	local p=s.players[1]
	local x,y=p.x,p.y
	for _=1,60 do M.update(s,1/60,{M.bot(s,p)}) end
	assert(#s.shots==0 and ((p.x-x)^2+(p.y-y)^2)>100)
end
function tests.boss_is_not_killed_by_one_pulse()
	local s=fresh(1)
	local p=s.players[1]
	local boss=M.spawn(s,"boss",p.x+100,p.y,0)
	M.pulse(s,p)
	assert(not boss.dead and boss.hp==boss.maxHp-12)
	local plan,name=require("games.siege_waves").plan(5,2,1280,800)
	assert(name=="OVERSEER" and plan[#plan].kind=="boss")
end
function tests.releasing_aim_stops_fire_even_while_moving()
	local s = fresh(1)
	local function step(aimX, aimY)
		M.update(s, 0.1, { { x = 1, y = 0, aimX = aimX, aimY = aimY } })
	end
	step(0, 0)
	assert((s.sfx.shot or 0) == 0, "movement alone must not fire")
	step(0, -1)
	local count = s.sfx.shot
	assert(count == 1 and s.shots[1].vy < 0, "aim fires in stick direction")
	step(0, 0)
	step(0.1, 0.1)
	assert(s.sfx.shot == count, "release and stick drift must not fire")
	step(1, 0)
	assert(s.sfx.shot == count + 1, "aiming again resumes fire")
end

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
function tests.powerups_stack_for_round_and_shots_do_not_hurt_friends()
	local s = fresh()
	local p = s.players[1]
	s.pickups = { { x = p.x, y = p.y, kind = "spread", ttl = 2 } }
	tick(s)
	assert(p.powers.spread)
	s.shots = {}
	p.fireClock = 0
	M.update(s, 1 / 120, { { x = 0, y = 0, aimX = 1, aimY = 0 }, { x = 0, y = 0 } })
	assert(#s.shots == 3)
	for _, kind in ipairs({ "pierce", "rapid", "spread" }) do
		s.pickups = { { x = p.x, y = p.y, kind = kind, ttl = 2 } }
		tick(s)
	end
	assert(p.powers.spread and p.powers.pierce and p.powers.rapid)
	-- More than the former nine-second expiry; keep the arena empty for isolation.
	for _ = 1, 1200 do s.enemies = {}; s.hostile = {}; tick(s) end
	assert(p.powers.spread and p.powers.pierce and p.powers.rapid)
	s.shots = {}; p.fireClock = 0
	M.update(s, 1 / 120, { { x = 0, y = 0, aimX = 1, aimY = 0 }, { x = 0, y = 0 } })
	assert(#s.shots == 3 and s.shots[1].hits == 3 and p.fireClock == 0.045)
	p.invul = 0
	s.shots = { { x = p.x - 25, y = p.y, vx = 6000, vy = 0, ttl = 1, hits = 1, hit = {}, owner = s.players[2] } }
	tick(s)
	assert(p.hp == 3)
	M.new(s.players, U.rng(42))
	assert(next(p.powers) == nil)
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
	assert(c.x == 0 and c.aimX == 0.7 and not c.autoAim)
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
		assert(s.kills > 20 and s.wave >= 3)
	end
	print(
		string.format(
			"Neon Siege: 270 simulated seconds in %.2fs; peak %d enemies",
			love.timer.getTime() - started,
			peak
		)
	)
end
function tests.waves_warn_clear_and_rest_before_advancing()
	local W = require("games.siege_waves")
	local s = fresh()
	local spawn = function(state, kind, x, y, delay)
		M.spawn(state, kind, x, y, delay)
	end
	W.update(s, 2, spawn)
	assert(s.wave == 1 and #s.enemies == 0)
	W.update(s, 0.01, spawn)
	assert(#s.enemies > 0)
	for _, e in ipairs(s.enemies) do
		assert(e.warm >= 1.4)
	end
	for _ = 1, 100 do
		W.update(s, 1, spawn)
	end
	assert(s.wave == 1 and #s.waveQueue == 0, "uncleared wave must not snowball")
	s.enemies = {}
	W.update(s, 0.01, spawn)
	assert(s.wavePhase == "rest")
	W.update(s, W.rest-0.1, spawn)
	assert(s.wave == 1 and #s.enemies == 0)
	W.update(s, 0.11, spawn)
	assert(s.wave == 2)
	for number = 1, 12 do
		local plan, name = W.plan(number, 4, 1422, 800)
		assert(#plan <= 61 and name == (number%5==0 and "OVERSEER" or W.names[(number - 1) % 4 + 1]))
		for _, e in ipairs(plan) do
			assert(e.x >= 0 and e.x <= 1422 and e.y >= 0 and e.y <= 800)
			if number < 2 then
				assert(e.kind == "chaser")
			end
			if number < 3 then
				assert(e.kind ~= "splitter")
			end
			if number < 4 then
				assert(e.kind ~= "fort")
			end
		end
	end
end
function tests.fullscreen_bounds_resize_and_spawn_safety()
	local s = fresh()
	M.resize(s, 1920, 1080)
	assert(math.abs(s.width - 1422.222) < 0.01)
	local p = s.players[1]
	p.x = 19
	p.y = 19
	M.update(s, 0.1, { { x = -1, y = -1 }, { x = 0, y = 0 } })
	assert(p.x == 18 and p.y == 18)
	local e = M.spawn(s, "chaser", p.x, p.y, 0.001)
	p.invul = 0
	tick(s)
	assert(e.warm > 0 and p.hp == 3, "warning must not activate on a player")
end
for name, test in pairs(tests) do
	test()
	print("PASS siege " .. name)
end
