local U = require("shared.util")
local A = {}
function A.move(p, c, speed, dt)
	local x, y = c.x or 0, c.y or 0
	local n = math.max(1, U.length(x, y))
	p.x = U.clamp(p.x + x / n * speed * dt, 90, 1190)
	p.y = U.clamp(p.y + y / n * speed * dt, 180, 650)
end
function A.roster(players)
	for i, p in ipairs(players) do
		p.x = 200 + (i - 1) * 280
		p.y = i % 2 == 0 and 580 or 240
		p.score = 0
	end
end
function A.event(s, name)
	s.sfx[name] = (s.sfx[name] or 0) + 1
end
function A.field(g)
	g.setColor(0.055, 0.075, 0.11)
	g.rectangle("fill", 70, 160, 1140, 510, 12, 12)
	g.setColor(0.15, 0.2, 0.27)
	g.setLineWidth(1)
	g.rectangle("line", 70, 160, 1140, 510, 12, 12)
end
return A
