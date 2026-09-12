local U = require("shared.util")
local Waves = require("games.siege_waves")
local M = {
	id = "neon-siege",
	title = "NEON SIEGE",
	tagline = "One swarm. One team. Keep moving.",
	coop = true,
	duration = 240,
	controls = "MOVE left stick / keys   AIM + FIRE right stick / keyboard auto   DASH A / action   PULSE B / secondary",
	limits = { enemies = 96, shots = 600, hostile = 240, particles = 650, pickups = 36 },
}
local specs = {
	boss = { hp = 180, r = 38, speed = 60, value = 1000 },
	chaser = { hp = 1, r = 11, speed = 115, value = 10 },
	weaver = { hp = 1, r = 10, speed = 145, value = 15 },
	splitter = { hp = 4, r = 21, speed = 65, value = 45 },
	fort = { hp = 4, r = 18, speed = 43, value = 55 },
	shard = { hp = 1, r = 7, speed = 190, value = 8 },
}
M.specs = specs
local function alive(p)
	return p.hp > 0
end
local function nearest(s, x, y)
	local best, distance = nil, math.huge
	for _, p in ipairs(s.players) do
		if alive(p) then
			local d = (p.x - x) ^ 2 + (p.y - y) ^ 2
			if d < distance then
				best, distance = p, d
			end
		end
	end
	return best, distance
end
local function sound(s, name)
	s.sfx[name] = (s.sfx[name] or 0) + 1
end
local function ring(s, x, y, r, color)
	if #s.rings < 40 then
		s.rings[#s.rings + 1] = { x = x, y = y, r = r, ttl = 0.35, color = color }
	end
end
local function burst(s, x, y, color, count)
	for _ = 1, math.min(count, M.limits.particles - #s.particles) do
		local a = s.rng() * math.pi * 2
		local speed = 60 + s.rng() * 220
		s.particles[#s.particles + 1] = {
			x = x,
			y = y,
			vx = math.cos(a) * speed,
			vy = math.sin(a) * speed,
			ttl = 0.2 + s.rng() * 0.35,
			color = color,
		}
	end
end
function M.spawn(s, kind, x, y, delay)
	if #s.enemies >= M.limits.enemies then
		return nil
	end
	local def = specs[kind]
	local e = {
		kind = kind,
		x = x,
		y = y,
		hp = def.hp,
		r = def.r,
		phase = s.rng() * 6.28,
		warm = delay or 0.6,
		fire = 1.0 + s.rng(),
		flash = 0,
	}
	if kind == "boss" then e.hp=def.hp + math.max(0,#s.players-1)*60 end
	e.maxHp=e.hp
	s.enemies[#s.enemies + 1] = e
	return e
end
function M.new(players, rng)
	local s = {
		players = players,
		rng = rng,
		enemies = {},
		shots = {},
		hostile = {},
		particles = {},
		pickups = {},
		rings = {},
		sfx = {},
		time = 0,
		wave = 0,
		width = 1280,
		height = 800,
		wavePhase = "rest",
		waveRest = 2,
		waveClock = 0,
		waveQueue = {},
		waveName = "SWEEP",
		teamScore = 0,
		chain = 0,
		comboTime = 0,
		kills = 0,
		shake = 0,
		wipe = 0,
		over = false,
	}
	for i, p in ipairs(players) do
		p.x, p.y = 640 + (i - (#players + 1) / 2) * 65, 415
		p.hp = 3
		p.invul = 1.5
		p.fireClock = 0
		p.dash = 0
		p.dashClock = 0
		p.pulseClock = 0
		p.aimX, p.aimY = 1, 0
		p.powers = {}
		p.revive = 0
		p.score = 0
	end
	return s
end
-- Instant join uses a fresh pilot only; the arena, wave and team score survive.
function M.join(s, player)
	local pilot = M.new({ player }, s.rng).players[1]
	pilot.x, pilot.y = s.width / 2, s.height / 2
	pilot.invul = 3
end
-- Keep world units uniform while using the actual display aspect ratio.
function M.resize(s, width, height)
	local newWidth = 800 * width / math.max(1, height)
	if math.abs(newWidth - s.width) < 0.01 then
		return
	end
	local ratio = newWidth / s.width
	for _, list in ipairs({ s.players, s.enemies, s.shots, s.hostile, s.pickups, s.particles, s.rings, s.waveQueue }) do
		for _, v in ipairs(list) do
			v.x = v.x * ratio
		end
	end
	s.width = newWidth
end
function M.multiplier(s)
	return math.min(5, 1 + math.floor(s.chain / 12))
end
local enemyColors = {
	boss = { 0.85, 0.35, 1 },
	chaser = { 1, 0.27, 0.57 },
	weaver = { 0.4, 1, 0.5 },
	splitter = { 1, 0.76, 0.23 },
	fort = { 1, 0.42, 0.19 },
	shard = { 1, 0.9, 0.5 },
}
M.enemyColors = enemyColors
function M.kill(s, e)
	if e.dead then
		return
	end
	e.dead = true
	s.kills = s.kills + 1
	s.chain = s.chain + 1
	s.comboTime = 2.5
	s.teamScore = s.teamScore + specs[e.kind].value * M.multiplier(s)
	local color = enemyColors[e.kind]
	burst(s, e.x, e.y, color, e.kind == "splitter" and 22 or 10)
	ring(s, e.x, e.y, e.r * 2, color)
	s.shake = math.min(5, s.shake + 0.7)
	sound(s, "burst")
	if e.kind == "splitter" then
		for i = 1, 3 do
			local a = i * 2.094
			M.spawn(s, "shard", e.x + math.cos(a) * 18, e.y + math.sin(a) * 18, 0.3)
		end
	end
	if #s.pickups < M.limits.pickups and s.rng() < 0.09 then
		s.pickups[#s.pickups + 1] =
			{ x = e.x, y = e.y, kind = ({ "spread", "pierce", "rapid", "repair" })[s.rng(1, 4)], ttl = 12 }
	end
end
function M.hurt(s, p)
	if not alive(p) or p.invul > 0 or p.dash > 0 then
		return false
	end
	p.hp = p.hp - 1
	p.invul = 1.0
	s.chain = 0
	s.comboTime = 0
	s.shake = 5
	sound(s, "hurt")
	burst(s, p.x, p.y, { 0.75, 0.85, 1 }, 20)
	if p.hp == 0 then
		p.downTime = 0
		p.revive = 0
		ring(s, p.x, p.y, 70, { 1, 0.25, 0.3 })
	end
	return true
end
function M.pulse(s, p)
	if not alive(p) or p.pulseClock > 0 then
		return false
	end
	p.pulseClock = 10
	p.invul = math.max(p.invul, 0.5)
	ring(s, p.x, p.y, 190, { 0.4, 0.85, 1 })
	s.shake = 5
	sound(s, "pulse")
	local count = #s.enemies
	for i = 1, count do
		local e = s.enemies[i]
		if not e.dead and (e.x - p.x) ^ 2 + (e.y - p.y) ^ 2 < 190 ^ 2 then
			if e.kind=="boss" then
				e.hp=e.hp-12;e.flash=0.2
				if e.hp<=0 then M.kill(s,e) end
			else M.kill(s, e) end
		end
	end
	for i = #s.hostile, 1, -1 do
		local b = s.hostile[i]
		if (b.x - p.x) ^ 2 + (b.y - p.y) ^ 2 < 220 ^ 2 then
			table.remove(s.hostile, i)
		end
	end
	return true
end
-- Earliest intersection along the segment: even very fast bullets cannot tunnel.
function M.segmentHit(ax, ay, bx, by, cx, cy, r)
	local dx, dy = bx - ax, by - ay
	local fx, fy = ax - cx, ay - cy
	local c = fx * fx + fy * fy - r * r
	if c <= 0 then
		return 0
	end
	local a = dx * dx + dy * dy
	if a < 1e-12 then
		return nil
	end
	local b = 2 * (fx * dx + fy * dy)
	local discriminant = b * b - 4 * a * c
	if discriminant < 0 then
		return nil
	end
	local t = (-b - math.sqrt(discriminant)) / (2 * a)
	if t >= 0 and t <= 1 then
		return t
	end
end
local function shoot(s, p, dx, dy)
	local angles = p.powers.spread and { -0.19, 0, 0.19 } or { 0 }
	for _, a in ipairs(angles) do
		if #s.shots >= M.limits.shots then
			break
		end
		local x, y = dx * math.cos(a) - dy * math.sin(a), dx * math.sin(a) + dy * math.cos(a)
		s.shots[#s.shots + 1] = {
			x = p.x + x * 15,
			y = p.y + y * 15,
			vx = x * 860,
			vy = y * 860,
			ttl = 1.35,
			owner = p,
			hits = p.powers.pierce and 3 or 1,
			hit = {},
		}
	end
	sound(s, "shot")
end
local function playerStep(s, p, c, dt)
	p.invul = math.max(0, p.invul - dt)
	p.dashClock = math.max(0, p.dashClock - dt)
	p.pulseClock = math.max(0, p.pulseClock - dt)
	if not alive(p) then
		p.downTime = p.downTime + dt
		local helper = nearest(s, p.x, p.y)
		if helper and (helper.x - p.x) ^ 2 + (helper.y - p.y) ^ 2 < 65 ^ 2 then
			p.revive = p.revive + dt
		else
			p.revive = math.max(0, p.revive - dt * 0.5)
		end
		if helper and (p.revive >= 1.2 or p.downTime >= 6) then
			p.hp = 3
			p.invul = 2
			p.revive = 0
			sound(s, "pickup")
			ring(s, p.x, p.y, 55, { 0.3, 1, 0.8 })
		end
		return
	end
	local dx, dy = c.x, c.y
	local length = U.length(dx, dy)
	if length > 1 then
		dx, dy = dx / length, dy / length
	end
	if c.action and p.dashClock == 0 and length > 0.1 then
		p.dash = 0.16
		p.dashClock = 1.2
		p.dashX, p.dashY = dx, dy
		ring(s, p.x, p.y, 32, { 0.3, 0.8, 1 })
	end
	p.dash = math.max(0, p.dash - dt)
	local speed = 310
	if p.dash > 0 then
		dx, dy = p.dashX, p.dashY
		speed = 920
	end
	p.x = U.clamp(p.x + dx * speed * dt, 18, s.width - 18)
	p.y = U.clamp(p.y + dy * speed * dt, 18, s.height - 18)
	if c.secondary then
		M.pulse(s, p)
	end
	local ax, ay = c.aimX or 0, c.aimY or 0
	local aim = U.length(ax, ay)
	p.fireClock = math.max(0, p.fireClock - dt)
	if aim > 0.2 then
		ax, ay = ax / aim, ay / aim
	elseif c.autoAim then
		local best, d = nil, math.huge
		for _, e in ipairs(s.enemies) do
			if not e.dead and e.warm <= 0 then
				local q = (e.x - p.x) ^ 2 + (e.y - p.y) ^ 2
				if q < d then
					best, d = e, q
				end
			end
		end
		if best then
			ax, ay = best.x - p.x, best.y - p.y
			local n = math.max(0.001, U.length(ax, ay))
			ax, ay = ax / n, ay / n
		else
			return -- Auto aim must not keep firing into an empty arena.
		end
	else
		return
	end
	p.aimX, p.aimY = ax, ay
	if p.fireClock <= 0 then
		shoot(s, p, ax, ay)
		p.fireClock = p.powers.rapid and 0.045 or 0.095
	end
end
local function enemiesStep(s, dt)
	for _, e in ipairs(s.enemies) do
		if not e.dead then
			if e.warm > 0 then
				e.warm = math.max(0, e.warm - dt)
				if e.warm == 0 then
					local _, distance = nearest(s, e.x, e.y)
					if distance < 80 ^ 2 then
						e.warm = 0.15
					end
				end
			end
			e.flash = math.max(0, e.flash - dt)
			local p = nearest(s, e.x, e.y)
			if p and e.warm == 0 then
				local dx, dy = p.x - e.x, p.y - e.y
				local length = math.max(1, U.length(dx, dy))
				dx, dy = dx / length, dy / length
				local speed = specs[e.kind].speed * (1 + math.min(0.30, math.max(0, s.wave - 1) * 0.035))
				if e.kind == "weaver" then
					local wave = math.sin(s.time * 5 + e.phase) * 0.85
					dx, dy = dx - dy * wave, dy + dx * wave
				end
				if e.kind == "boss" then
					e.fire=e.fire-dt
					if length<260 then speed=0 end
					if e.fire<=0 then
						e.fire=e.hp<e.maxHp/2 and 1.1 or 1.8
						for i=1,12 do
							if #s.hostile>=M.limits.hostile then break end
							local a=i*math.pi/6+s.time*0.4
							-- A rotating radial volley has visible lanes to dodge.
							s.hostile[#s.hostile+1]={x=e.x,y=e.y,vx=math.cos(a)*190,vy=math.sin(a)*190,ttl=6}
						end
					end
				end
				if e.kind == "fort" then
					if length < 300 then
						speed = 0
					end
					e.fire = e.fire - dt
					if e.fire <= 0 and #s.hostile < M.limits.hostile then
						e.fire = 1.5
						s.hostile[#s.hostile + 1] = { x = e.x, y = e.y, vx = dx * 230, vy = dy * 230, ttl = 5 }
					end
				end
				e.x, e.y = e.x + dx * speed * dt, e.y + dy * speed * dt
				for _, pilot in ipairs(s.players) do
					if not e.dead and alive(pilot) and (pilot.x - e.x) ^ 2 + (pilot.y - e.y) ^ 2 < (e.r + 11) ^ 2 then
						M.hurt(s, pilot)
						if pilot.dash > 0 and e.kind~="boss" then
							M.kill(s, e)
						end
					end
				end
			end
		end
	end
end
local function shotsStep(s, dt)
	local grid = {}
	for _, e in ipairs(s.enemies) do
		if not e.dead and e.warm == 0 then
			local k = math.floor(e.y / 64) * 32 + math.floor(e.x / 64)
			grid[k] = grid[k] or {}
			grid[k][#grid[k] + 1] = e
		end
	end
	for i = #s.shots, 1, -1 do
		local b = s.shots[i]
		local x, y = b.x + b.vx * dt, b.y + b.vy * dt
		b.ttl = b.ttl - dt
		while b.hits > 0 do
			local best, t = nil, math.huge
			for gy = math.floor((math.min(b.y, y) - 45) / 64), math.floor((math.max(b.y, y) + 45) / 64) do
				for gx = math.floor((math.min(b.x, x) - 45) / 64), math.floor((math.max(b.x, x) + 45) / 64) do
					for _, e in ipairs(grid[gy * 32 + gx] or {}) do
						if not e.dead and not b.hit[e] then
							local hit = M.segmentHit(b.x, b.y, x, y, e.x, e.y, e.r + 3)
							if hit and hit < t then
								best, t = e, hit
							end
						end
					end
				end
			end
			if not best then
				break
			end
			b.hit[best] = true
			b.hits = b.hits - 1
			best.hp = best.hp - 1
			best.flash = 0.09
			burst(s, b.x + (x - b.x) * t, b.y + (y - b.y) * t, { 0.8, 0.9, 1 }, 3)
			if best.hp <= 0 then
				M.kill(s, best)
			end
		end
		b.x, b.y = x, y
		if b.ttl <= 0 or b.hits == 0 or x < -20 or x > s.width + 20 or y < -20 or y > s.height + 20 then
			s.shots[i] = s.shots[#s.shots]
			s.shots[#s.shots] = nil
		end
	end
	for i = #s.hostile, 1, -1 do
		local b = s.hostile[i]
		local x, y = b.x + b.vx * dt, b.y + b.vy * dt
		b.ttl = b.ttl - dt
		for _, p in ipairs(s.players) do
			if alive(p) and M.segmentHit(b.x, b.y, x, y, p.x, p.y, 14) then
				M.hurt(s, p)
				b.ttl = 0
				break
			end
		end
		b.x, b.y = x, y
		if b.ttl <= 0 or x < -20 or x > s.width + 20 or y < -20 or y > s.height + 20 then
			s.hostile[i] = s.hostile[#s.hostile]
			s.hostile[#s.hostile] = nil
		end
	end
end
local function effectsStep(s, dt)
	for i = #s.particles, 1, -1 do
		local p = s.particles[i]
		p.ttl = p.ttl - dt
		p.x, p.y = p.x + p.vx * dt, p.y + p.vy * dt
		if p.ttl <= 0 then
			s.particles[i] = s.particles[#s.particles]
			s.particles[#s.particles] = nil
		end
	end
	for i = #s.rings, 1, -1 do
		local r = s.rings[i]
		r.ttl = r.ttl - dt
		if r.ttl <= 0 then
			table.remove(s.rings, i)
		end
	end
	for i = #s.pickups, 1, -1 do
		local q = s.pickups[i]
		q.ttl = q.ttl - dt
		local p, d = nearest(s, q.x, q.y)
		if p and d < 80 ^ 2 then
			q.x = q.x + (p.x - q.x) * dt * 8
			q.y = q.y + (p.y - q.y) * dt * 8
		end
		if p and d < 22 ^ 2 then
			if q.kind == "repair" then
				p.hp = math.min(3, p.hp + 1)
			else
				p.powers[q.kind] = true
			end
			q.ttl = 0
			sound(s, "pickup")
			ring(s, p.x, p.y, 40, { 0.5, 1, 0.7 })
		end
		if q.ttl <= 0 then
			table.remove(s.pickups, i)
		end
	end
end
function M.update(s, dt, inputs)
	if s.over then
		return
	end
	s.time = s.time + dt
	s.shake = math.max(0, s.shake - dt * 20)
	s.comboTime = math.max(0, s.comboTime - dt)
	if s.comboTime == 0 then
		s.chain = 0
	end
	Waves.update(s, dt, M.spawn)
	for i, p in ipairs(s.players) do
		playerStep(s, p, inputs[i], dt)
	end
	enemiesStep(s, dt)
	shotsStep(s, dt)
	effectsStep(s, dt)
	for i = #s.enemies, 1, -1 do
		if s.enemies[i].dead then
			s.enemies[i] = s.enemies[#s.enemies]
			s.enemies[#s.enemies] = nil
		end
	end
	local live = 0
	for _, p in ipairs(s.players) do
		p.score = s.teamScore
		if alive(p) then
			live = live + 1
		end
	end
	if live == 0 and #s.players > 0 then
		s.wipe = s.wipe + dt
	else
		s.wipe = 0
	end
	if s.wipe >= 2 then
		s.over = true
	end
end
function M.describe(p)
	if p.hp == 0 then
		return "DOWN / REVIVING"
	end
	local active = {}
	for _, kind in ipairs({ "spread", "pierce", "rapid" }) do
		if p.powers[kind] then active[#active + 1] = kind:upper() end
	end
	return (#active > 0 and table.concat(active, " + ") or "UNLIMITED FIRE")
		.. " / B "
		.. (p.pulseClock == 0 and "READY" or math.ceil(p.pulseClock) .. "s")
end
function M.bot(s, p)
	local angle=s.time*0.45+p.slot*1.7
	local dx, dy = (s.width/2+math.cos(angle)*s.width*0.25-p.x)*0.008, (s.height/2+math.sin(angle)*s.height*0.25-p.y)*0.008
	for _,b in ipairs(s.hostile) do
		local x,y=p.x-b.x,p.y-b.y
		local d=x*x+y*y
		if d<110^2 then dx=dx+x/math.max(100,d)*150;dy=dy+y/math.max(100,d)*150 end
	end
	local nearby = 0
	for _, e in ipairs(s.enemies) do
		if not e.dead then
			local x, y = p.x - e.x, p.y - e.y
			local d = x * x + y * y
			if d < 180 ^ 2 then
				dx = dx + x / math.max(100, d) * 110
				dy = dy + y / math.max(100, d) * 110
				nearby = nearby + 1
			end
		end
	end
	local n = math.max(1, U.length(dx, dy))
	return { x = dx / n, y = dy / n, action = nearby > 5, secondary = nearby > 8, autoAim = true }
end
return M
