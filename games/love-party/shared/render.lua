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
end
function R.finish()
	G.pop()
end
function R.menu(modes, index, count)
	R.begin()
	centered("Choose a game", 80, "title")
	for i, mode in ipairs(modes) do
		local x = 110 + (i - 1) % 2 * 550
		local y = 165 + math.floor((i - 1) / 2) * 108
		local c = R.colors[(i - 1) % 4 + 1]
		G.setColor(i == index and { 0.09, 0.14, 0.18 } or { 0.04, 0.055, 0.085 })
		G.rectangle("fill", x, y, 510, 88, 8, 8)
		text(tostring(i), x + 20, y + 19, "small", c)
		text(mode.title, x + 52, y + 16, "body", c)
		text(mode.tagline, x + 52, y + 48, "small", { 0.55, 0.62, 0.7 })
	end
	centered(count .. " players  /  F2     1–" .. #modes .. " or D-pad choose     Enter / A play", 645, "small")
	centered(modes[index].controls, 704, "small", { 0.55, 0.65, 0.77 })
	centered("Keyboard: WASD + Space / Arrows + Right Ctrl / IJKL + U / TFGH + R", 744, "small", { 0.4, 0.48, 0.56 })
	R.finish()
end
function R.game(mode, s, remaining, finished, managed)
	R.begin()
	-- Keep world coordinates stable; enlarge the arena independently of the HUD.
	G.push()
	local zoom = mode.id == "blast-party" and 1.38
		or (mode.id == "bumper-royale" or mode.id == "orbit-guard") and 1.23
		or 1.065
	G.translate(640, 425)
	G.scale(zoom)
	G.translate(-640, -417)
	if mode.draw then
		mode.draw(s, G, R.fonts, player_color)
	elseif mode.id == "neon-siege" then
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
	end
	G.pop()
	-- A single quiet row replaces the title, scorecards and persistent instructions.
	G.setFont(R.fonts.small)
	G.setColor(remaining < 10 and { 1, 0.43, 0.4 } or { 0.55, 0.62, 0.7 })
	G.printf(string.format("%02d", math.ceil(remaining)), 595, 22, 90, "center")
	local positions = { 28, 300, 760, 1032 }
	for i, p in ipairs(s.players) do
		local x = positions[i]
		local c = player_color(p)
		G.setColor(c)
		G.circle("fill", x + 3, 30, 3)
		G.setFont(R.fonts.small)
		local name = p.name
		while R.fonts.small:getWidth(name) > 130 do
			name = name:sub(1, require("utf8").offset(name, -1) - 1)
		end
		G.print(name, x + 15, 22)
		G.setColor(0.7, 0.75, 0.8)
		G.printf(
			mode.coop and (p.hp == 0 and "down" or string.rep("·", p.hp)) or tostring(math.floor(p.score)),
			x + 150,
			22,
			55,
			"right"
		)
	end
	if mode.coop then
		centered(
			s.teamScore .. "   /   x" .. (mode.id == "neon-siege" and require("games.siege").multiplier(s) or 1),
			768,
			"small",
			{ 0.4, 0.65, 0.63 }
		)
	end

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
