local U = require("shared.util")
local A = require("shared.arena")
local M = {
	id = "ricochet-club",
	title = "RICOCHET CLUB",
	fireWithShoulder = true,
	tagline = "Every wall is another angle.",
	controls = "MOVE stick / keys   AIM right stick / movement   FIRE RB / RT   SHIELD B",
}
local function overlaps(x, y, radius, block)
	return math.abs(x - block.x) < block.size / 2 + radius and math.abs(y - block.y) < block.size / 2 + radius
end
local function blocked(s, x, y)
	for _, block in ipairs(s.cover) do
		if overlaps(x, y, 18, block) then
			return true
		end
	end
	return false
end
local function moveTank(s, p, c, dt)
	local steps = math.max(1, math.ceil(dt * 220 / 6))
	for _ = 1, steps do
		local x, y = p.x, p.y
		A.move(p, c, 220, dt / steps)
		local nextX, nextY = p.x, p.y
		p.x, p.y = x, y
		if not blocked(s, nextX, y) then
			p.x = nextX
		end
		if not blocked(s, p.x, nextY) then
			p.y = nextY
		end
	end
end
local function hitCover(s, index)
	local block = s.cover[index]
	block.hp = block.hp - 1
	block.flash = 0.1
	A.event(s, block.hp == 0 and "burst" or "hit")
	for _ = 1, block.hp == 0 and 12 or 4 do
		if #s.debris < 160 then
			local angle = s.rng() * math.pi * 2
			local speed = 50 + s.rng() * 120
			s.debris[#s.debris + 1] = {
				x = block.x,
				y = block.y,
				vx = math.cos(angle) * speed,
				vy = math.sin(angle) * speed,
				ttl = 0.5,
			}
		end
	end
	if block.hp == 0 then
		table.remove(s.cover, index)
	end
end
function M.new(players, rng)
	A.roster(players)
	for _, p in ipairs(players) do
		p.ax = 1
		p.ay = 0
		p.cool = 0
		p.guard = 0
		p.shield = 0
		p.invul = 1
	end
	local cover = {}
	-- Symmetric islands leave wide routes and every spawn clear.
	for _, x in ipairs({ 360, 640, 920 }) do
		for _, y in ipairs({ 320, 490 }) do
			for _, offset in ipairs({ -26, 26 }) do
				cover[#cover + 1] = { x = x + offset, y = y, size = 44, hp = 3, flash = 0 }
			end
		end
	end
	return { players = players, rng = rng, shots = {}, cover = cover, debris = {}, time = 0, sfx = {} }
end
function M.update(s, dt, inputs)
	s.time = s.time + dt
	for _, block in ipairs(s.cover) do
		block.flash = math.max(0, block.flash - dt)
	end
	for i = #s.debris, 1, -1 do
		local d = s.debris[i]
		d.ttl = d.ttl - dt
		d.x, d.y = d.x + d.vx * dt, d.y + d.vy * dt
		if d.ttl <= 0 then
			table.remove(s.debris, i)
		end
	end
	for i, p in ipairs(s.players) do
		local c = inputs[i]
		moveTank(s, p, c, dt)
		for _, k in ipairs({ "cool", "guard", "shield", "invul" }) do
			p[k] = math.max(0, p[k] - dt)
		end
		local ax, ay = c.aimX or 0, c.aimY or 0
		if U.length(ax, ay) < 0.2 then
			ax, ay = c.x, c.y
		end
		local n = U.length(ax, ay)
		if n > 0.2 then
			p.ax, p.ay = ax / n, ay / n
		end
		if c.secondary and p.guard == 0 then
			p.shield = 0.6
			p.guard = 3
		end
		if c.action and p.cool == 0 and #s.shots < 80 then
			p.cool = 0.45
			A.event(s, "shot")
			s.shots[#s.shots + 1] = {
				x = p.x + p.ax * 22,
				y = p.y + p.ay * 22,
				vx = p.ax * 430,
				vy = p.ay * 430,
				owner = p,
				ttl = 4,
				bounces = 0,
			}
		end
	end
	-- Small substeps keep collisions reliable at low frame rates as well as 120 Hz.
	for i = #s.shots, 1, -1 do
		local b = s.shots[i]
		b.ttl = b.ttl - dt
		local steps = math.max(1, math.ceil(dt * 430 / 6))
		for _ = 1, steps do
			if b.ttl <= 0 then
				break
			end
			b.x = b.x + b.vx * dt / steps
			b.y = b.y + b.vy * dt / steps
			if b.x < 78 or b.x > 1202 then
				b.x = U.clamp(b.x, 78, 1202)
				b.vx = -b.vx
				b.bounces = b.bounces + 1
			end
			if b.y < 168 or b.y > 662 then
				b.y = U.clamp(b.y, 168, 662)
				b.vy = -b.vy
				b.bounces = b.bounces + 1
			end
			for index, block in ipairs(s.cover) do
				if overlaps(b.x, b.y, 4, block) then
					hitCover(s, index)
					b.ttl = 0
					break
				end
			end
			if b.ttl <= 0 then
				break
			end
			for _, p in ipairs(s.players) do
				if (p ~= b.owner or b.bounces > 0) and p.invul == 0 and U.length(p.x - b.x, p.y - b.y) < 19 then
					b.ttl = 0
					if p.shield == 0 then
						if p == b.owner then
							p.score = p.score - 1
						else
							b.owner.score = b.owner.score + 3
							p.score = p.score - 1
						end
						p.invul = 1.2
						A.event(s, "burst")
					else
						A.event(s, "hit")
					end
					break
				end
			end
			if b.bounces > 4 then
				b.ttl = 0
			end
		end
		if b.ttl <= 0 then
			table.remove(s.shots, i)
		end
	end
end
function M.bot(s, p)
	local target = s.players[p.slot % #s.players + 1]
	if target == p then
		target = s.players[1]
	end
	local dx, dy = target.x - p.x, target.y - p.y
	local n = math.max(1, U.length(dx, dy))
	return {
		x = math.sin(s.time + p.slot),
		y = math.cos(s.time * 0.7 + p.slot),
		aimX = dx / n,
		aimY = dy / n,
		action = true,
		secondary = p.guard == 0,
	}
end
function M.draw(s, g, fonts, color)
	A.field(g)
	for _, block in ipairs(s.cover) do
		local h = block.size / 2
		g.setColor(0.09, 0.08, 0.07)
		g.rectangle("fill", block.x - h + 3, block.y - h - 3, block.size, block.size, 3, 3)
		g.setColor(0.32 + block.flash * 4, 0.24 + block.flash * 4, 0.13 + block.flash * 4)
		g.rectangle("fill", block.x - h, block.y - h, block.size, block.size, 3, 3)
		g.setColor(0.78, 0.58, 0.31)
		g.setLineWidth(2)
		g.rectangle("line", block.x - h + 3, block.y - h + 3, block.size - 6, block.size - 6, 2, 2)
		g.line(block.x - h + 5, block.y - h + 5, block.x + h - 5, block.y + h - 5)
		g.line(block.x - h + 5, block.y + h - 5, block.x + h - 5, block.y - h + 5)
		if block.hp < 3 then
			g.setColor(0.08, 0.06, 0.04)
			g.line(
				block.x - 5,
				block.y + h,
				block.x + 3,
				block.y + 5,
				block.x - 4,
				block.y - 4,
				block.x + 6,
				block.y - h
			)
			if block.hp == 1 then
				g.line(block.x - h, block.y + 4, block.x, block.y - 5, block.x + h, block.y + 7)
			end
		end
	end
	for _, d in ipairs(s.debris) do
		g.setColor(0.78, 0.58, 0.31, d.ttl * 2)
		g.rectangle("fill", d.x - 2, d.y - 2, 4, 4)
	end
	for _, b in ipairs(s.shots) do
		g.setColor(color(b.owner))
		g.setLineWidth(3)
		g.line(b.x - b.vx * 0.025, b.y - b.vy * 0.025, b.x, b.y)
		g.circle("fill", b.x, b.y, 4)
	end
	for _, p in ipairs(s.players) do
		local c = color(p)
		g.setColor(c[1], c[2], c[3], p.invul > 0 and 0.45 or 1)
		g.push()
		g.translate(p.x, p.y)
		g.rotate(math.atan2(p.ay, p.ax))
		g.rectangle("fill", -13, -12, 26, 24, 4, 4)
		g.setLineWidth(6)
		g.line(0, 0, 24, 0)
		g.pop()
		if p.shield > 0 then
			g.setLineWidth(2)
			g.circle("line", p.x, p.y, 26)
		end
	end
end
return M
