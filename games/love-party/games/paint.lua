local U = require("shared.util")
local A = require("shared.arena")
local M = {
	id = "paint-rush",
	title = "PAINT RUSH",
	tagline = "Leave your colour everywhere.",
	controls = "MOVE stick / keys   BURST A (4s cooldown)",
}
function M.new(players, rng)
	A.roster(players)
	for _, p in ipairs(players) do
		p.cool = 0
	end
	return { players = players, rng = rng, tiles = {}, time = 0, sfx = {} }
end
function M.update(s, dt, inputs)
	s.time = s.time + dt
	local claims = {}
	for i, p in ipairs(s.players) do
		A.move(p, inputs[i], 260, dt)
		p.cool = math.max(0, p.cool - dt)
		local radius = 0
		if inputs[i].action and p.cool == 0 then
			radius = 2
			p.cool = 4
			A.event(s, "pickup")
		end
		local cx, cy = math.floor((p.x - 80) / 30), math.floor((p.y - 170) / 30)
		for y = cy - radius, cy + radius do
			for x = cx - radius, cx + radius do
				if x >= 0 and x < 37 and y >= 0 and y < 16 and math.abs(x - cx) + math.abs(y - cy) <= radius then
					local key = y * 37 + x
					-- A contested tile stays unchanged, independent of player iteration order.
					local entry = claims[key]
					if entry == nil then
						claims[key] = p
					elseif entry ~= p then
						claims[key] = false
					end
				end
			end
		end
	end
	for key, p in pairs(claims) do
		if p then
			s.tiles[key] = p
		end
	end
	for _, p in ipairs(s.players) do
		p.score = 0
	end
	for _, p in pairs(s.tiles) do
		p.score = p.score + 1
	end
end
function M.bot(s, p)
	local angle = s.time * 0.65 + p.slot * 1.57
	local tx = 640 + math.sin(angle) * 500
	local ty = 410 + math.sin(angle * 1.7) * 220
	local dx, dy = tx - p.x, ty - p.y
	local n = math.max(1, U.length(dx, dy))
	return { x = dx / n, y = dy / n, action = true }
end
function M.draw(s, g, fonts, color)
	A.field(g)
	for key, p in pairs(s.tiles) do
		local c = color(p)
		g.setColor(c[1], c[2], c[3], 0.4)
		g.rectangle("fill", 80 + key % 37 * 30, 170 + math.floor(key / 37) * 30, 29, 29, 3, 3)
	end
	for _, p in ipairs(s.players) do
		g.setColor(color(p))
		g.circle("fill", p.x, p.y, 12)
		g.setColor(1, 1, 1)
		g.circle("fill", p.x + 3, p.y - 3, 3)
		if p.cool == 0 then
			g.setColor(color(p))
			g.setLineWidth(2)
			g.circle("line", p.x, p.y, 18)
		end
	end
end
return M
