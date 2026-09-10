local U = require("shared.util")
local A = require("shared.arena")
local M = {
	id = "ricochet-club",
	title = "RICOCHET CLUB",
	fireWithShoulder = true,
	tagline = "Every wall is another angle.",
	controls = "MOVE stick / keys   AIM right stick / movement   FIRE RB / RT   SHIELD B",
}
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
	return { players = players, rng = rng, shots = {}, time = 0, sfx = {} }
end
function M.update(s, dt, inputs)
	s.time = s.time + dt
	for i, p in ipairs(s.players) do
		local c = inputs[i]
		A.move(p, c, 220, dt)
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
