local U = require("shared.util")
local M = {
	title = "METEOR DASH",
	tagline = "Chase the stars. Dodge everything else.",
	controls = "MOVE  stick / keys     SHIELD DASH  A / action",
	id = "meteor-dash",
}
function M.new(players, rng)
	local s = { players = players, rng = rng, objects = {}, clock = 0, time = 0 }
	for i, p in ipairs(players) do
		p.x, p.y = 220 + i * 165, 590
		p.cool, p.shield = 0, 0
	end
	return s
end
function M.update(s, dt, inputs)
	s.time = s.time + dt
	s.clock = s.clock + dt
	if s.clock > 0.12 then
		s.clock = s.clock - 0.12
		s.objects[#s.objects + 1] =
			{ x = s.rng(85, 1195), y = 140, r = s.rng(10, 24), speed = s.rng(160, 290) + s.time * 2, star = s.rng()
				< 0.2 }
	end
	for i, p in ipairs(s.players) do
		local c = inputs[i]
		p.cool = math.max(0, p.cool - dt)
		p.shield = math.max(0, p.shield - dt)
		if c.action and p.cool == 0 then
			p.cool = 1.5
			p.shield = 0.3
		end
		local speed = p.shield > 0 and 620 or 280
		p.x = U.clamp(p.x + c.x * speed * dt, 85, 1195)
		p.y = U.clamp(p.y + c.y * speed * dt, 180, 660)
		p.score = p.score + dt
	end
	for i = #s.objects, 1, -1 do
		local o = s.objects[i]
		o.y = o.y + o.speed * dt
		local gone = o.y > 700
		for _, p in ipairs(s.players) do
			if not gone and U.length(o.x - p.x, o.y - p.y) < o.r + 15 then
				if o.star then
					p.score = p.score + 5
					gone = true
				elseif p.shield == 0 then
					p.score = p.score - 10
					p.shield = 0.75
					gone = true
				end
			end
		end
		if gone then
			table.remove(s.objects, i)
		end
	end
end
function M.bot(s, p)
	local x, y = math.sin(s.time + p.slot) * 0.5, 0
	for _, o in ipairs(s.objects) do
		if math.abs(o.x - p.x) < 75 and o.y < p.y and p.y - o.y < 170 then
			x = o.star and (o.x > p.x and 1 or -1) or (o.x > p.x and -1 or 1)
		end
	end
	return { x = x, y = y, action = false }
end
return M
