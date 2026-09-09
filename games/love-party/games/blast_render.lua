local B = require("games.blast")
local M = {}
local glyphs = {
	remote = "R",
	kick = "K",
	diagonal = "X",
	beam = "I",
	star = "*",
	range = "+",
	capacity = "2",
	speed = "S",
	cross = "C",
}
local colors = {
	remote = { 0.35, 0.9, 1 },
	kick = { 0.5, 1, 0.6 },
	diagonal = { 1, 0.5, 0.8 },
	beam = { 0.8, 0.6, 1 },
	star = { 1, 0.85, 0.35 },
	range = { 1, 0.5, 0.35 },
	capacity = { 0.4, 0.8, 1 },
	speed = { 0.7, 1, 0.4 },
	cross = { 0.8, 0.8, 0.9 },
}
local function icon(g, fonts, power, x, y, size)
	g.setColor(colors[power])
	g.rectangle("fill", x - size / 2, y - size / 2, size, size, 6, 6)
	g.setColor(0.04, 0.065, 0.10)
	g.setFont(fonts.body)
	g.printf(glyphs[power], x - size / 2, y - 11, size, "center")
end
function M.draw(s, g, fonts, playerColor)
	local cell, ox, oy = 46, 203, 160
	local themes = { { 0.13, 0.23, 0.28 }, { 0.23, 0.16, 0.29 }, { 0.24, 0.21, 0.14 } }
	local theme = themes[s.theme]
	g.setColor(0.015, 0.025, 0.045)
	g.rectangle("fill", ox - 7, oy - 7, 19 * cell + 14, 11 * cell + 14, 9, 9)
	for y = 0, 10 do
		for x = 0, 18 do
			local px, py = ox + x * cell, oy + y * cell
			local k = B.key(x, y)
			local kind = s.tiles[k]
			g.setColor((x + y) % 2 == 0 and { 0.075, 0.11, 0.16 } or { 0.085, 0.125, 0.175 })
			g.rectangle("fill", px, py, cell - 1, cell - 1)
			if kind == "wall" then
				g.setColor(theme)
				g.rectangle("fill", px + 2, py + 2, cell - 5, cell - 5, 5, 5)
				g.setColor(theme[1] + 0.09, theme[2] + 0.09, theme[3] + 0.09)
				g.rectangle("fill", px + 6, py + 4, cell - 13, 5, 2, 2)
				g.setColor(0.03, 0.055, 0.08)
				g.circle("fill", px + 10, py + 34, 2)
				g.circle("fill", px + 34, py + 34, 2)
			elseif kind == "crate" then
				g.setColor(0.49, 0.28, 0.17)
				g.rectangle("fill", px + 4, py + 5, cell - 8, cell - 9, 4, 4)
				g.setColor(0.78, 0.49, 0.27)
				g.setLineWidth(3)
				g.rectangle("line", px + 7, py + 8, cell - 14, cell - 15, 2, 2)
				g.line(px + 10, py + 11, px + 35, py + 34)
				g.line(px + 10, py + 34, px + 35, py + 11)
			end
			if s.items[k] then
				icon(g, fonts, s.items[k], px + 23, py + 23, 27)
			end
			local f = s.flames[k]
			if f then
				local t = f.ttl / 0.55
				g.setColor(1, 0.35 + 0.3 * t, 0.14, 0.8 * t)
				g.rectangle("fill", px + 1, py + 1, cell - 2, cell - 2, 7, 7)
				g.setColor(1, 0.95, 0.65, t)
				g.setLineWidth(5)
				g.line(px + 9, py + 23, px + 37, py + 23)
				g.line(px + 23, py + 9, px + 23, py + 37)
			end
		end
	end
	for _, b in ipairs(s.bombs) do
		local x, y = ox + b.x * cell + 23, oy + b.y * cell + 24
		local pulse = math.sin(s.time * (b.fuse < 1 and 25 or 9)) * 1.7
		g.setColor(0.015, 0.02, 0.035, 0.8)
		g.ellipse("fill", x, y + 13, 17, 7)
		g.setColor(0.08, 0.11, 0.17)
		g.circle("fill", x, y, 16 + pulse)
		g.setColor(playerColor(b.owner))
		g.setLineWidth(2)
		g.circle("line", x, y, 16 + pulse)
		g.setFont(fonts.small)
		if b.shape == "beam" then
			g.line(x - b.dx * 9, y - b.dy * 9, x + b.dx * 9, y + b.dy * 9)
		else
			g.printf(glyphs[b.shape], x - 16, y - 8, 32, "center")
		end
		if b.remote then
			g.setColor(colors.remote)
			g.line(x + 9, y - 11, x + 14, y - 24)
			g.circle("fill", x + 14, y - 24, 3)
		else
			g.setColor(1, 0.74, 0.25)
			g.line(x + 6, y - 15, x + 9, y - 23)
			g.circle("fill", x + 9, y - 23, 2 + pulse / 2)
		end
	end
	for _, p in ipairs(s.players) do
		local x, y = ox + p.renderX * cell + 23, oy + p.renderY * cell + 23
		local c = playerColor(p)
		if p.alive then
			g.setColor(0.015, 0.02, 0.035, 0.7)
			g.ellipse("fill", x, y + 17, 15, 6)
			g.setColor(c)
			g.rectangle("fill", x - 13, y - 14, 26, 29, 8, 8)
			g.setColor(0.035, 0.055, 0.085)
			g.rectangle("fill", x - 10, y - 5, 20, 10, 3, 3)
			g.setColor(1, 1, 0.95)
			g.rectangle("fill", x - 6 + p.dx * 2, y - 3 + p.dy, 3, 5)
			g.rectangle("fill", x + 3 + p.dx * 2, y - 3 + p.dy, 3, 5)
			if p.kick then
				g.setColor(0.5, 1, 0.6)
				g.rectangle("fill", x - 13, y + 11, 10, 6, 2, 2)
				g.rectangle("fill", x + 3, y + 11, 10, 6, 2, 2)
			end
			if p.remote then
				g.setColor(colors.remote)
				g.circle("fill", x + 13, y - 13, 4)
			end
		else
			g.setColor(c[1], c[2], c[3], 0.35)
			g.setLineWidth(3)
			g.line(x - 8, y - 8, x + 8, y + 8)
			g.line(x - 8, y + 8, x + 8, y - 8)
		end
	end
	if s.intermission then
		g.setColor(0.02, 0.03, 0.06, 0.94)
		g.rectangle("fill", 370, 335, 540, 125, 15, 15)
		g.setColor(1, 0.85, 0.45)
		g.setFont(fonts.title)
		g.printf("NEXT ARENA", 370, 356, 540, "center")
		g.setColor(0.8, 0.85, 0.93)
		g.setFont(fonts.body)
		g.printf("Fresh map. Fresh tricks.", 370, 406, 540, "center")
	end
end
return M
