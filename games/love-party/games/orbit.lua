local U = require("shared.util")
local A = require("shared.arena")
local M = {
	id = "orbit-guard",
	title = "ANTICONCEPTION",
	tagline = "Protect the egg.",
	controls = "ROTATE left / right   BOOST A   WIDE SHIELD B",
	coop = true,
	duration = 90,
}
function M.new(players, rng)
	A.roster(players)
	for i, p in ipairs(players) do
		p.angle = (i - 1) * math.pi * 2 / #players
		p.hp = 5
		p.cool = 0
		p.wide = 0
		p.x = 640 + math.cos(p.angle) * 180
		p.y = 417 + math.sin(p.angle) * 180
	end
	return {
		players = players,
		rng = rng,
		rocks = {},
		time = 0,
		clock = -3,
		hp = 5,
		teamScore = 0,
		kills = 0,
		wave = 1,
		over = false,
		sfx = {},
	}
end
local function difference(a, b)
	return (a - b + math.pi) % (math.pi * 2) - math.pi
end
M.difference = difference
function M.update(s, dt, inputs)
	if s.over then
		return
	end
	s.time = s.time + dt
	s.wave = 1 + math.floor(s.time / 10)
	for i, p in ipairs(s.players) do
		local c = inputs[i]
		p.angle = (p.angle + (c.x or 0) * (c.action and 3.2 or 1.9) * dt) % (math.pi * 2)
		p.cool = math.max(0, p.cool - dt)
		p.wide = math.max(0, p.wide - dt)
		if c.secondary and p.cool == 0 then
			p.wide = 1
			p.cool = 4
		end
		p.x, p.y = 640 + math.cos(p.angle) * 180, 417 + math.sin(p.angle) * 180
	end
	s.clock = s.clock + dt
	local interval = math.max(0.65, 1.2 - s.time * 0.004) / (1 + (#s.players - 2) * 0.1)
	while s.clock >= interval do
		s.clock = s.clock - interval
		if #s.rocks < 80 then
			s.rocks[#s.rocks + 1] = { angle = s.rng() * math.pi * 2, r = 300, speed = math.min(55, 38 + s.time * 0.18) }
		end
	end
	for i = #s.rocks, 1, -1 do
		local rock = s.rocks[i]
		local before = rock.r
		rock.r = rock.r - rock.speed * dt
		local blocked = false
		if before >= 173 and rock.r <= 187 then
			for _, p in ipairs(s.players) do
				if math.abs(difference(rock.angle, p.angle)) < (p.wide > 0 and 0.55 or 0.25) then
					blocked = true
					break
				end
			end
		end
		if blocked then
			s.kills = s.kills + 1
			s.teamScore = s.teamScore + 10
			A.event(s, "point")
			table.remove(s.rocks, i)
		elseif rock.r < 35 then
			s.hp = math.max(0, s.hp - 1)
			A.event(s, "hurt")
			table.remove(s.rocks, i)
		end
	end
	for _, p in ipairs(s.players) do
		p.hp = s.hp
		p.score = s.teamScore
	end
	s.over = s.hp == 0
end
function M.bot(s, p)
	local best, dist = nil, math.huge
	for _, r in ipairs(s.rocks) do
		local d = math.abs(difference(r.angle, p.angle))
		if r.r > 170 and d < dist then
			best, dist = r, d
		end
	end
	local d = best and difference(best.angle, p.angle) or 0
	return { x = U.clamp(d * 5, -1, 1), y = 0, action = math.abs(d) > 0.5, secondary = dist < 0.3 }
end
function M.draw(s, g, fonts, color)
	g.setLineWidth(1)
	g.setColor(0.12, 0.18, 0.24)
	g.circle("line", 640, 417, 300)
	g.circle("line", 640, 417, 180)
	g.setColor(0.98, 0.9, 0.74)
	g.ellipse("fill", 640, 417, 25, 31)
	g.setColor(1, 0.98, 0.9)
	g.ellipse("fill", 634, 425, 8, 11)
	for i = 1, s.hp do
		local a = i * math.pi * 2 / 5
		g.circle("fill", 640 + math.cos(a) * 38, 417 + math.sin(a) * 38, 3)
	end
	for _, r in ipairs(s.rocks) do
		local x, y = 640 + math.cos(r.angle) * r.r, 417 + math.sin(r.angle) * r.r
		g.setColor(1, 0.43, 0.3)
		g.circle("fill", x, y, 7)
		g.setColor(1, 0.43, 0.3, 0.3)
		g.setLineWidth(3)
		g.line(x, y, x + math.cos(r.angle) * 15, y + math.sin(r.angle) * 15)
	end
	for _, p in ipairs(s.players) do
		g.setColor(color(p))
		g.setLineWidth(9)
		local width = p.wide > 0 and 0.55 or 0.25
		g.arc("line", "open", 640, 417, 180, p.angle - width, p.angle + width)
	end
end
return M
