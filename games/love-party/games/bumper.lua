local U = require("shared.util")
local M = {
	title = "BUMPER ROYALE",
	tagline = "Own the ring. Bump your friends out.",
	controls = "MOVE  stick / keys     DASH  A / action",
	id = "bumper-royale",
}
function M.new(players, rng)
	local s = { players = players, radius = 270, time = 0, rng = rng }
	for i, p in ipairs(players) do
		local a = (i - 1) * math.pi * 2 / #players
		p.x, p.y, p.vx, p.vy, p.cool, p.flash = 640 + math.cos(a) * 150, 410 + math.sin(a) * 150, 0, 0, 0, 0
	end
	return s
end
function M.update(s, dt, inputs)
	s.time = s.time + dt
	s.radius = 270 - math.min(s.time * 1.2, 70)
	for i, p in ipairs(s.players) do
		local c = inputs[i]
		p.cool = math.max(0, p.cool - dt)
		p.flash = math.max(0, p.flash - dt)
		local speed = 800
		p.vx = (p.vx + c.x * speed * dt) * math.exp(-2.3 * dt)
		p.vy = (p.vy + c.y * speed * dt) * math.exp(-2.3 * dt)
		if c.action and p.cool == 0 and U.length(c.x, c.y) > 0.1 then
			p.vx, p.vy = p.vx + c.x * 480, p.vy + c.y * 480
			p.cool = 1.1
		end
		p.x, p.y = p.x + p.vx * dt, p.y + p.vy * dt
		if U.length(p.x - 640, p.y - 410) > s.radius + 22 then
			if p.hit and s.time - p.hitTime < 3 then
				p.hit.score = p.hit.score + 3
			end
			p.score = p.score - 1
			p.x, p.y = 640 + (i - 2.5) * 25, 410
			p.vx, p.vy = 0, 0
			p.flash = 0.8
			p.hit = nil
		end
	end
	for i, a in ipairs(s.players) do
		for j = i + 1, #s.players do
			local b = s.players[j]
			local dx, dy = b.x - a.x, b.y - a.y
			local n = U.length(dx, dy)
			if n < 42 and a.flash == 0 and b.flash == 0 then
				if n < 0.001 then
					dx, dy, n = 1, 0, 1
				end
				local nx, ny = dx / n, dy / n
				local overlap = (42 - n) / 2
				a.x, a.y = a.x - nx * overlap, a.y - ny * overlap
				b.x, b.y = b.x + nx * overlap, b.y + ny * overlap
				local relative = (a.vx - b.vx) * nx + (a.vy - b.vy) * ny
				if relative > 0 then
					local impulse = relative * 0.95 + 65
					a.vx, a.vy = a.vx - nx * impulse, a.vy - ny * impulse
					b.vx, b.vy = b.vx + nx * impulse, b.vy + ny * impulse
					a.hit, a.hitTime = b, s.time
					b.hit, b.hitTime = a, s.time
				end
			end
		end
	end
end
function M.bot(s, p)
	local target = s.players[p.slot % #s.players + 1]
	if target == p then
		target = s.players[1]
	end
	local x, y = 640 - p.x, 410 - p.y
	if U.length(x, y) < s.radius * 0.65 and target then
		x, y = target.x - p.x, target.y - p.y
	end
	local n = math.max(1, U.length(x, y))
	local turn = math.sin(s.time * 1.3 + p.slot * 1.8) * 0.6
	return { x = U.clamp(x / n - y / n * turn, -1, 1), y = U.clamp(y / n + x / n * turn, -1, 1), action = n < 160 }
end
return M
