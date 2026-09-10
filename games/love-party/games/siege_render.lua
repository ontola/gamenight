local M = {}
local Siege = require("games.siege")
function M.draw(s, G, fonts, playerColor)
	local function tint(c, a)
		G.setColor(c[1], c[2], c[3], a or 1)
	end
	local function polygon(x, y, r, n, angle)
		local points = {}
		for i = 1, n do
			local a = angle + i * math.pi * 2 / n
			points[#points + 1] = x + math.cos(a) * r
			points[#points + 1] = y + math.sin(a) * r
		end
		G.polygon("line", points)
	end
	local sx, sy = G.transformPoint(0, 0)
	local ex, ey = G.transformPoint(s.width, s.height)
	G.setScissor(sx, sy, ex - sx, ey - sy)
	G.push()
	G.translate(math.sin(s.time * 83) * s.shake, math.cos(s.time * 97) * s.shake * 0.6)
	G.setColor(0.025, 0.043, 0.075)
	G.rectangle("fill", -10, -10, s.width + 20, s.height + 20)
	G.setColor(0.055, 0.095, 0.13)
	G.setLineWidth(1)
	for x = 0, s.width, 40 do
		G.line(x, 0, x, s.height)
	end
	for y = 0, s.height, 40 do
		G.line(0, y, s.width, y)
	end
	for _, r in ipairs(s.rings) do
		tint(r.color, r.ttl / 0.35 * 0.7)
		G.setLineWidth(2)
		G.circle("line", r.x, r.y, r.r * (1 - r.ttl / 0.4))
	end
	for _, q in ipairs(s.pickups) do
		G.setColor(0.4, 1, 0.8, math.min(1, q.ttl))
		G.setLineWidth(2)
		polygon(q.x, q.y, 15, 4, s.time)
		G.setFont(fonts.small)
		G.printf(({ spread = "S", pierce = "P", rapid = "R", repair = "+" })[q.kind], q.x - 12, q.y - 8, 24, "center")
	end
	for _, b in ipairs(s.shots) do
		local c = playerColor(b.owner)
		tint(c, 0.18)
		G.setLineWidth(7)
		G.line(b.x - b.vx * 0.018, b.y - b.vy * 0.018, b.x, b.y)
		tint(c)
		G.setLineWidth(2)
		G.line(b.x - b.vx * 0.014, b.y - b.vy * 0.014, b.x, b.y)
	end
	for _, b in ipairs(s.hostile) do
		G.setColor(1, 0.4, 0.15, 0.2)
		G.circle("fill", b.x, b.y, 9)
		G.setColor(1, 0.7, 0.35)
		G.circle("fill", b.x, b.y, 4)
	end
	for _, e in ipairs(s.enemies) do
		local c = Siege.enemyColors[e.kind]
		local n = e.kind == "splitter" and 6 or (e.kind == "weaver" or e.kind == "shard") and 3 or 4
		local angle = e.kind == "fort" and math.pi / 4 or s.time * 0.7 + e.phase
		if e.warm > 0 then
			tint(c, 0.25)
			G.setLineWidth(1)
			G.circle("line", e.x, e.y, e.r + e.warm * 22)
			tint(c, 0.65)
			G.circle("line", e.x, e.y, 5)
		else
			tint(c, 0.15)
			G.setLineWidth(7)
			polygon(e.x, e.y, e.r, n, angle)
			tint(e.flash > 0 and { 1, 1, 1 } or c)
			G.setLineWidth(2)
			polygon(e.x, e.y, e.r, n, angle)
			if e.kind == "fort" then
				G.circle("line", e.x, e.y, 6)
			end
		end
	end
	for _, p in ipairs(s.particles) do
		tint(p.color, math.min(1, p.ttl * 3))
		G.setLineWidth(2)
		G.line(p.x, p.y, p.x - p.vx * 0.022, p.y - p.vy * 0.022)
	end
	for _, p in ipairs(s.players) do
		local c = playerColor(p)
		tint(c)
		G.setLineWidth(2)
		if p.hp == 0 then
			G.circle("line", p.x, p.y, 20 + math.sin(s.time * 5) * 3)
			G.line(p.x - 7, p.y, p.x + 7, p.y)
			G.line(p.x, p.y - 7, p.x, p.y + 7)
			if p.revive > 0 then
				G.arc(
					"line",
					"open",
					p.x,
					p.y,
					27,
					-math.pi / 2,
					-math.pi / 2 + math.pi * 2 * math.min(1, p.revive / 1.2)
				)
			end
			G.setFont(fonts.small)
			G.printf("REVIVE", p.x - 45, p.y + 30, 90, "center")
		else
			local ax, ay = p.aimX, p.aimY
			local points = {
				p.x + ax * 17,
				p.y + ay * 17,
				p.x - ax * 12 - ay * 11,
				p.y - ay * 12 + ax * 11,
				p.x - ax * 5,
				p.y - ay * 5,
				p.x - ax * 12 + ay * 11,
				p.y - ay * 12 - ax * 11,
			}
			tint(c, 0.18)
			G.setLineWidth(8)
			G.polygon("line", points)
			tint(c)
			G.setLineWidth(2)
			G.polygon("line", points)
			if p.invul > 0 then
				tint(c, 0.35 + 0.2 * math.sin(s.time * 20))
				G.circle("line", p.x, p.y, 23)
			end
			if p.dash > 0 then
				tint(c, 0.45)
				G.setLineWidth(5)
				G.line(p.x, p.y, p.x - p.dashX * 48, p.y - p.dashY * 48)
			end
			tint(c)
			local upgrades = {}
			for _, kind in ipairs({ "spread", "pierce", "rapid" }) do
				if p.powers[kind] then upgrades[#upgrades + 1] = kind:upper() end
			end
			if #upgrades > 0 then
				G.setFont(fonts.small)
				G.setColor(0.85, 1, 0.95)
				G.printf(table.concat(upgrades, " + "), p.x - 110, p.y + 38, 220, "center")
			end
			tint(c)
			for i = 1, p.hp do
				G.circle("fill", p.x + (i - 2) * 7, p.y + 28, 2)
			end
		end
	end
	G.pop()
	G.setScissor()
	G.setFont(fonts.small)
	G.setColor(0.55, 0.7, 0.75, 0.8)
	if s.wavePhase == "rest" then
		G.printf("WAVE " .. (s.wave + 1) .. "  /  " .. math.ceil(s.waveRest), 0, 65, s.width, "center")
	elseif s.waveClock < 2 then
		G.printf("WAVE " .. s.wave .. "  /  " .. s.waveName, 0, 65, s.width, "center")
	end
end
return M
