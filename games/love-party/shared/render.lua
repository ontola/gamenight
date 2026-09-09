local R = { colors = { { 0.30, 0.92, 0.83 }, { 1, 0.43, 0.40 }, { 1, 0.82, 0.32 }, { 0.61, 0.53, 1 } } }
local G
local function player_color(p)
	if p.color and p.color:match("^#%x%x%x%x%x%x$") then
		return {
			tonumber(p.color:sub(2, 3), 16) / 255,
			tonumber(p.color:sub(4, 5), 16) / 255,
			tonumber(p.color:sub(6, 7), 16) / 255,
		}
	end
	return R.colors[p.slot]
end
function R.load()
	G = love.graphics
	R.fonts = { huge = G.newFont(52), title = G.newFont(30), body = G.newFont(19), small = G.newFont(14) }
end
local function text(value, x, y, font, color)
	G.setFont(R.fonts[font or "body"])
	G.setColor(color or { 0.91, 0.94, 1 })
	G.print(value, x, y)
end
local function centered(value, y, font, color)
	G.setFont(R.fonts[font or "body"])
	G.setColor(color or { 0.91, 0.94, 1 })
	G.printf(value, 0, y, 1280, "center")
end
function R.begin()
	local w, h = G.getDimensions()
	local scale = math.min(w / 1280, h / 800)
	G.clear(0.018, 0.027, 0.055)
	G.push()
	G.translate((w - 1280 * scale) / 2, (h - 800 * scale) / 2)
	G.scale(scale)
	G.setColor(0.035, 0.05, 0.09)
	G.rectangle("fill", 0, 0, 1280, 800)
	G.setColor(0.065, 0.085, 0.13)
	G.setLineWidth(1)
	for x = 0, 1280, 40 do
		G.line(x, 145, x, 690)
	end
	for y = 145, 690, 40 do
		G.line(0, y, 1280, y)
	end
end
function R.finish()
	G.pop()
end
function R.menu(modes, index, count)
	R.begin()
	text("GAMENIGHT  /  THE FIRST COLLECTION", 70, 40, "small", { 0.3, 0.92, 0.83 })
	text("GOOD FRIENDS.", 70, 78, "huge")
	text("QUESTIONABLE ALLIANCES.", 70, 137, "huge")
	text("Five little games. One very busy couch.", 73, 215, "body", { 0.55, 0.65, 0.77 })
	for i, mode in ipairs(modes) do
		local x = 70 + ((i - 1) % 3) * 390
		local y = 278 + math.floor((i - 1) / 3) * 171
		local c = R.colors[(i - 1) % 4 + 1]
		local chosen = i == index
		G.setColor(chosen and 0.10 or 0.055, chosen and 0.16 or 0.085, chosen and 0.22 or 0.14)
		G.rectangle("fill", x, y, 370, 150, 16, 16)
		G.setColor(c)
		G.setLineWidth(chosen and 3 or 1)
		G.rectangle("line", x, y, 370, 150, 16, 16)
		text("0" .. i, x + 22, y + 17, "small", c)
		local cx, cy = x + 45, y + 90
		if i == 1 then
			G.circle("line", cx, cy, 28)
			G.circle("fill", cx - 10, cy, 10)
			G.circle("fill", cx + 19, cy + 9, 10)
		elseif i == 2 then
			G.setLineWidth(7)
			G.line(cx - 25, cy + 23, cx - 25, cy - 21, cx + 14, cy - 21, cx + 14, cy + 13, cx + 35, cy + 13)
		elseif i == 3 or i == 5 then
			G.polygon("fill", cx, cy - 29, cx - 20, cy + 22, cx, cy + 10, cx + 20, cy + 22)
		else
			G.circle("fill", cx, cy, 23)
			G.setLineWidth(3)
			G.line(cx + 12, cy - 19, cx + 25, cy - 34, cx + 35, cy - 29)
			G.setColor(0.035, 0.05, 0.09)
			G.line(cx - 12, cy, cx + 12, cy)
			G.line(cx, cy - 12, cx, cy + 12)
		end
		text(mode.title, x + 85, y + 37, "body", c)
		G.setFont(R.fonts.small)
		G.setColor(0.91, 0.94, 1)
		G.printf(mode.tagline, x + 85, y + 80, 268)
	end
	centered(count .. " PLAYERS   •   F2 changes player count", 641, "body")
	centered("1 / 2 / 3 / 4 / 5 choose     ENTER or controller A play", 683, "body", { 0.3, 0.92, 0.83 })
	centered(
		"Keyboard: WASD + Space   /   Arrows + Right Ctrl   /   IJKL + U   /   TFGH + R",
		741,
		"small",
		{ 0.55, 0.65, 0.77 }
	)
	R.finish()
end
function R.game(mode, s, remaining, finished, managed)
	R.begin()
	text("GAMENIGHT  /  PARTY PACK", 42, 22, "small", { 0.3, 0.92, 0.83 })
	text(mode.title, 40, 48, "title")
	text(mode.tagline, 42, 91, "small", { 0.55, 0.65, 0.77 })
	G.setFont(R.fonts.huge)
	G.setColor(remaining < 10 and { 1, 0.43, 0.40 } or { 0.91, 0.94, 1 })
	G.printf(string.format("%02d", math.ceil(remaining)), 1080, 38, 150, "right")
	if mode.id == "neon-siege" then
		require("games.siege_render").draw(s, G, R.fonts, player_color)
	elseif mode.id == "blast-party" then
		require("games.blast_render").draw(s, G, R.fonts, player_color)
	elseif mode.id == "bumper-royale" then
		G.setColor(0.09, 0.14, 0.2)
		G.circle("fill", 640, 410, s.radius)
		G.setColor(0.3, 0.92, 0.83, 0.12)
		G.setLineWidth(14)
		G.circle("line", 640, 410, s.radius)
		G.setColor(0.3, 0.92, 0.83)
		G.setLineWidth(2)
		G.circle("line", 640, 410, s.radius)
		for _, p in ipairs(s.players) do
			local c = player_color(p)
			G.setColor(c[1], c[2], c[3], p.flash > 0 and 0.4 or 1)
			G.circle("fill", p.x, p.y, 20)
			G.setColor(0.04, 0.06, 0.1)
			G.circle("fill", p.x + 6, p.y - 4, 4)
			G.circle("fill", p.x - 6, p.y - 4, 4)
			if p.cool == 0 then
				G.setColor(c)
				G.circle("line", p.x, p.y, 25)
			end
		end
		text("+3 knockout   /   -1 fall", 60, 655, "small")
	elseif mode.id == "neon-trails" then
		G.setColor(0.11, 0.15, 0.22)
		G.rectangle("fill", 64, 155, 1152, 520)
		for _, p in ipairs(s.players) do
			local c = player_color(p)
			G.setColor(c[1], c[2], c[3], p.alive and 0.85 or 0.2)
			for _, v in ipairs(p.trail) do
				G.rectangle("fill", 65 + v[1] * 24, 156 + v[2] * 20, 22, 18, 3, 3)
			end
			if p.alive then
				G.setColor(1, 1, 1)
				G.rectangle("fill", 69 + p.x * 24, 159 + p.y * 20, 14, 12, 3, 3)
			end
		end
		if s.intermission then
			centered("LAST RIDER +3  /  NEXT ROUND…", 395, "title")
		end
	else
		for _, o in ipairs(s.objects) do
			G.setColor(o.star and { 1, 0.82, 0.32 } or { 0.43, 0.49, 0.63 })
			G.circle(o.star and "line" or "fill", o.x, o.y, o.r)
			if o.star then
				G.line(o.x - 6, o.y, o.x + 6, o.y)
				G.line(o.x, o.y - 6, o.x, o.y + 6)
			end
		end
		for _, p in ipairs(s.players) do
			G.setColor(player_color(p))
			G.polygon("fill", p.x, p.y - 20, p.x - 15, p.y + 14, p.x, p.y + 6, p.x + 15, p.y + 14)
			if p.shield > 0 then
				G.setLineWidth(3)
				G.circle("line", p.x, p.y, 27)
			end
		end
		text("+5 star   /   -10 hit   /   +1 per second", 60, 655, "small")
	end
	local width = 1160 / math.max(1, #s.players)
	for i, p in ipairs(s.players) do
		local x = 60 + (i - 1) * width
		G.setColor(0.055, 0.08, 0.13)
		G.rectangle("fill", x, 703, width - 12, 54, 8, 8)
		text(p.name, x + 14, 714, "body", player_color(p))
		if mode.describe then
			text(mode.describe(p), x + 14, 738, "small", { 0.65, 0.74, 0.83 })
		end
		G.setFont(R.fonts.body)
		G.setColor(1, 1, 1)
		G.printf(mode.coop and (p.hp .. " HP") or tostring(math.floor(p.score)), x, 714, width - 28, "right")
	end
	centered(mode.controls .. "     " .. (managed and "BACK  lobby" or "ESC  menu"), 774, "small", { 0.55, 0.65, 0.77 })
	if finished then
		G.setColor(0.02, 0.03, 0.06, 0.92)
		G.rectangle("fill", 260, 255, 760, 290, 20, 20)
		if mode.coop then
			centered(s.over and "TEAM DOWN" or "TEAM SURVIVED", 290, "title", { 0.3, 0.92, 0.83 })
			centered(s.kills .. " ENEMIES / WAVE " .. s.wave, 350, "body")
			centered(s.teamScore .. " POINTS", 391, "huge")
		else
			local best = -math.huge
			for _, p in ipairs(s.players) do
				best = math.max(best, math.floor(p.score))
			end
			local winners = {}
			for _, p in ipairs(s.players) do
				if math.floor(p.score) == best then
					winners[#winners + 1] = p.name
				end
			end
			centered(#winners == 1 and "ROUND WINNER" or "SHARED VICTORY", 290, "small", { 0.3, 0.92, 0.83 })
			centered(table.concat(winners, " + "), 336, "title")
			centered(tostring(best) .. " POINTS", 391, "huge")
		end
		centered(managed and "Waiting for the party…" or "ENTER / A rematch   •   ESC menu", 490, "body")
	end
	R.finish()
end
return R
