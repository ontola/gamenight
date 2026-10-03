local U = require("shared.util")
local M = {
	title = "BLAST PARTY",
	tagline = "Small bombs. Big betrayals.",
	id = "blast-party",
	controls = "MOVE stick / keys   BOMB A / action   DETONATE B / secondary",
	width = 19,
	height = 11,
	powers = { "remote", "kick", "diagonal", "beam", "star", "range", "capacity", "speed", "cross" },
}
local directions = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local diagonals = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local spawns = { { 1, 1 }, { 17, 9 }, { 1, 9 }, { 17, 1 } }
function M.key(x, y)
	return y * M.width + x
end
local function tile(s, x, y)
	return s.tiles[M.key(x, y)] or "wall"
end
local function bombAt(s, x, y)
	for _, b in ipairs(s.bombs) do
		if not b.dead and b.x == x and b.y == y then
			return b
		end
	end
end
local function occupied(s, x, y)
	for _, p in ipairs(s.players) do
		if p.alive and p.x == x and p.y == y then
			return true
		end
	end
	return false
end
function M.generate(rng)
	local tiles, drops = {}, {}
	for y = 0, 10 do
		for x = 0, 18 do
			local mx, my = math.min(x, 18 - x), math.min(y, 10 - y)
			local k = M.key(mx, my)
			if tiles[k] == nil then
				local safe = false
				for _, v in ipairs(spawns) do
					if math.abs(mx - v[1]) + math.abs(my - v[2]) <= 3 then
						safe = true
					end
				end
				local kind = "floor"
				if mx == 0 or my == 0 then
					kind = "wall"
				elseif mx % 2 == 0 and my % 2 == 0 and rng() < 0.85 then
					kind = "wall"
				elseif not safe and rng() < 0.62 then
					kind = "crate"
				end
				tiles[k] = kind
				if kind == "crate" and rng() < 0.55 then
					drops[k] = M.powers[rng(1, #M.powers)]
				end
			end
			tiles[M.key(x, y)] = tiles[k]
			drops[M.key(x, y)] = drops[k]
		end
	end
	return tiles, drops
end
local function reset(s)
	s.tiles, s.drops = M.generate(s.rng)
	s.bombs, s.flames, s.items = {}, {}, {}
	s.round = (s.round or 0) + 1
	s.theme = s.rng(1, 3)
	s.roundTime = 0
	s.settle = nil
	s.intermission = nil
	for i, p in ipairs(s.players) do
		p.x, p.y = spawns[i][1], spawns[i][2]
		p.renderX, p.renderY = p.x, p.y
		p.alive, p.range, p.capacity, p.speed = true, 2, 2, 6
		p.remote, p.kick, p.shape = false, false, "cross"
		p.dx, p.dy = 1, 0
		p.moveClock = 0
		p.actionHeld, p.secondaryHeld = false, false
		p.botClock = 0
	end
	-- Visible opening prizes encourage leaving the safe spawn pockets.
	local available = {}
	for y = 1, 9 do
		for x = 4, 14 do
			if tile(s, x, y) == "floor" then
				available[#available + 1] = { x, y }
			end
		end
	end
	for _, power in ipairs({ "remote", "kick", "diagonal", "beam", "star" }) do
		if #available > 0 then
			local v = table.remove(available, s.rng(1, #available))
			s.items[M.key(v[1], v[2])] = power
		end
	end
end
function M.new(players, rng)
	local s = { players = players, rng = rng, time = 0 }
	reset(s)
	return s
end
function M.blastCells(s, b)
	local cells = { { b.x, b.y } }
	local rays = directions
	local reach = b.range
	if b.shape == "diagonal" then
		rays = diagonals
	elseif b.shape == "beam" then
		rays = { { b.dx, b.dy }, { -b.dx, -b.dy } }
		reach = reach * 2
	elseif b.shape == "star" then
		rays = {}
		for _, v in ipairs(directions) do
			rays[#rays + 1] = v
		end
		for _, v in ipairs(diagonals) do
			rays[#rays + 1] = v
		end
	end
	for _, v in ipairs(rays) do
		for n = 1, reach do
			local x, y = b.x + v[1] * n, b.y + v[2] * n
			local kind = tile(s, x, y)
			if kind == "wall" then
				break
			end
			cells[#cells + 1] = { x, y }
			if kind == "crate" or bombAt(s, x, y) then
				break
			end
		end
	end
	return cells
end
function M.placeBomb(s, p)
	if not p.alive or bombAt(s, p.x, p.y) then
		return nil
	end
	local count = 0
	for _, b in ipairs(s.bombs) do
		if not b.dead and b.owner == p then
			count = count + 1
		end
	end
	if count >= p.capacity then
		return nil
	end
	local b = {
		x = p.x,
		y = p.y,
		owner = p,
		range = p.range,
		shape = p.shape,
		dx = p.dx,
		dy = p.dy,
		remote = p.remote,
		fuse = p.remote and math.huge or 2.3,
		slideClock = 0,
	}
	s.bombs[#s.bombs + 1] = b
	return b
end
function M.pickup(p, power)
	if power == "remote" then
		p.remote = true
	elseif power == "kick" then
		p.kick = true
	elseif power == "range" then
		p.range = math.min(5, p.range + 1)
	elseif power == "capacity" then
		p.capacity = math.min(5, p.capacity + 1)
	elseif power == "speed" then
		p.speed = math.min(9, p.speed + 1)
	else
		p.shape = power
	end
end
local function explode(s, first)
	s.blastCount = (s.blastCount or 0) + 1
	local queue = { first }
	local queued = { [first] = true }
	local destroyed = {}
	local index = 1
	-- Keep crates intact until the whole chain has traced its rays. A second
	-- blast in this chain must not pass through a crate the first one destroyed.
	while index <= #queue do
		local b = queue[index]
		index = index + 1
		if not b.dead then
			local cells = M.blastCells(s, b)
			b.dead = true
			for _, v in ipairs(cells) do
				local k = M.key(v[1], v[2])
				s.flames[k] = { ttl = 0.55, owner = b.owner, shape = b.shape }
				local chained = bombAt(s, v[1], v[2])
				if chained and not queued[chained] then
					queued[chained] = true
					queue[#queue + 1] = chained
				end
				if tile(s, v[1], v[2]) == "crate" then
					destroyed[k] = true
				else
					s.items[k] = nil
				end
			end
		end
	end
	for k in pairs(destroyed) do
		s.tiles[k] = "floor"
		s.items[k] = s.drops[k]
		s.drops[k] = nil
	end
end
local function killInFlame(s, p)
	local flame = s.flames[M.key(p.x, p.y)]
	if p.alive and flame then
		p.alive = false
		p.score = p.score - 1
		if flame.owner ~= p then
			flame.owner.score = flame.owner.score + 1
		end
	end
end
local function moveBomb(s, b, dx, dy)
	local x, y = b.x + dx, b.y + dy
	if tile(s, x, y) ~= "floor" or bombAt(s, x, y) or occupied(s, x, y) then
		return false
	end
	b.x, b.y = x, y
	return true
end
local function movePlayer(s, p, c, dt)
	p.moveClock = math.max(0, p.moveClock - dt)
	if p.moveClock > 0 then
		return
	end
	local dx, dy = 0, 0
	if math.abs(c.x) > math.abs(c.y) and math.abs(c.x) > 0.3 then
		dx = c.x > 0 and 1 or -1
	elseif math.abs(c.y) > 0.3 then
		dy = c.y > 0 and 1 or -1
	end
	if dx == 0 and dy == 0 then
		return
	end
	p.dx, p.dy = dx, dy
	local x, y = p.x + dx, p.y + dy
	if tile(s, x, y) ~= "floor" then
		return
	end
	local b = bombAt(s, x, y)
	if b then
		if not p.kick or not moveBomb(s, b, dx, dy) then
			return
		end
		b.sx, b.sy = dx, dy
		b.slideClock = 0
	end
	p.x, p.y = x, y
	p.moveClock = 1 / p.speed
end
function M.update(s, dt, inputs)
	s.time = s.time + dt
	if s.intermission then
		s.intermission = s.intermission - dt
		if s.intermission <= 0 then
			reset(s)
		end
		return
	end
	s.roundTime = s.roundTime + dt
	for k, f in pairs(s.flames) do
		f.ttl = f.ttl - dt
		if f.ttl <= 0 then
			s.flames[k] = nil
		end
	end
	for i, p in ipairs(s.players) do
		local c = inputs[i]
		killInFlame(s, p)
		if p.alive then
			if c.action and not p.actionHeld then
				M.placeBomb(s, p)
			end
			if c.secondary and not p.secondaryHeld then
				for _, b in ipairs(s.bombs) do
					if b.owner == p and b.remote then
						b.fuse = 0
					end
				end
			end
			movePlayer(s, p, c, dt)
			local k = M.key(p.x, p.y)
			if s.items[k] and not s.flames[k] then
				M.pickup(p, s.items[k])
				s.items[k] = nil
			end
		end
		p.actionHeld, p.secondaryHeld = c.action, c.secondary
		p.renderX = p.renderX + (p.x - p.renderX) * math.min(1, dt * 24)
		p.renderY = p.renderY + (p.y - p.renderY) * math.min(1, dt * 24)
	end
	for _, b in ipairs(s.bombs) do
		if b.sx and not b.dead then
			b.slideClock = b.slideClock + dt
			if b.slideClock >= 0.075 then
				b.slideClock = b.slideClock - 0.075
				if not moveBomb(s, b, b.sx, b.sy) then
					b.sx, b.sy = nil, nil
				end
			end
		end
		if not b.owner.alive then
			b.fuse = math.min(b.fuse, 2.3)
		end
		b.fuse = b.fuse - dt
		if s.flames[M.key(b.x, b.y)] then
			b.fuse = 0
		end
		if b.fuse <= 0 and not b.dead then
			explode(s, b)
		end
	end
	for i = #s.bombs, 1, -1 do
		if s.bombs[i].dead then
			table.remove(s.bombs, i)
		end
	end
	local alive = 0
	for _, p in ipairs(s.players) do
		killInFlame(s, p)
		if p.alive then
			alive = alive + 1
		end
	end
	if alive <= 1 and #s.players > 1 then
		s.settle = (s.settle or 0) + dt
		if s.settle > 0.65 then
			for _, p in ipairs(s.players) do
				if p.alive then
					p.score = p.score + 3
				end
			end
			s.intermission = 1.7
		end
	end
end
function M.bot(s, p)
	if not p.alive then
		return { x = 0, y = 0 }
	end
	if p.botClock and p.botClock > s.time then
		return p.botInput
	end
	p.botClock = s.time + 0.16
	local danger = {}
	for _, b in ipairs(s.bombs) do
		for _, v in ipairs(M.blastCells(s, b)) do
			danger[M.key(v[1], v[2])] = true
		end
	end
	for k in pairs(s.flames) do
		danger[k] = true
	end
	local adjacent = false
	for _, v in ipairs(directions) do
		if tile(s, p.x + v[1], p.y + v[2]) == "crate" then
			adjacent = true
		end
	end
	local choices = {}
	for _, v in ipairs(directions) do
		local x, y = p.x + v[1], p.y + v[2]
		if tile(s, x, y) == "floor" and not bombAt(s, x, y) then
			local score = s.rng() * 2 + (danger[M.key(x, y)] and -10 or 5)
			if s.items[M.key(x, y)] then
				score = score + 6
			end
			choices[#choices + 1] = { x = v[1], y = v[2], score = score }
		end
	end
	table.sort(choices, function(a, b)
		return a.score > b.score
	end)
	local c = choices[1] or { x = 0, y = 0 }
	-- Bot bombs are deliberately occasional; humans get the same rules.
	c.action = adjacent and not danger[M.key(p.x, p.y)] and #choices > 1 and s.rng() < 0.18
	c.secondary = not danger[M.key(p.x, p.y)] and s.rng() < 0.15
	p.botInput = c
	return c
end
function M.describe(p)
	if not p.alive then
		return "OUT - back next round"
	end
	local names = { cross = "CROSS", diagonal = "X", beam = "BEAM", star = "STAR" }
	return names[p.shape]
		.. "  "
		.. p.capacity
		.. "B / "
		.. p.range
		.. "R"
		.. (p.remote and "  REM" or "")
		.. (p.kick and "  KICK" or "")
end
return M
