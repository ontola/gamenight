local M = {
	title = "NEON TRAILS",
	tagline = "Leave a trail. Leave no escape.",
	controls = "TURN  stick / direction keys     Survive to score",
	id = "neon-trails",
}
local W, H = 48, 26
local function key(x, y)
	return y * W + x
end
local function reset(s)
	s.grid = {}
	s.clock = 0
	s.intermission = nil
	for i, p in ipairs(s.players) do
		p.x, p.y = ({ 8, 39, 8, 39 })[i], ({ 6, 19, 19, 6 })[i]
		p.dx, p.dy = ({ 1, -1, 1, -1 })[i], 0
		p.alive = true
		p.nextX, p.nextY = nil, nil
		p.trail = { { p.x, p.y } }
		s.grid[key(p.x, p.y)] = p.slot
	end
end
function M.new(players, rng)
	local s = { players = players, rng = rng }
	reset(s)
	return s
end
function M.update(s, dt, inputs)
	if s.intermission then
		s.intermission = s.intermission - dt
		if s.intermission <= 0 then
			reset(s)
		end
		return
	end
	for i, p in ipairs(s.players) do
		local c = inputs[i]
		local dx, dy = 0, 0
		if math.abs(c.x) > math.abs(c.y) and math.abs(c.x) > 0.3 then
			dx = c.x > 0 and 1 or -1
		elseif math.abs(c.y) > 0.3 then
			dy = c.y > 0 and 1 or -1
		end
		if dx ~= 0 or dy ~= 0 then
			if dx ~= -p.dx or dy ~= -p.dy then
				p.nextX, p.nextY = dx, dy
			end
		end
	end
	s.clock = s.clock + dt
	if s.clock < 0.105 then
		return
	end
	s.clock = s.clock - 0.105
	local targets = {}
	for _, p in ipairs(s.players) do
		if p.alive then
			p.dx, p.dy = p.nextX or p.dx, p.nextY or p.dy
			p.nextX, p.nextY = nil, nil
			p.nx, p.ny = p.x + p.dx, p.y + p.dy
			local k = key(p.nx, p.ny)
			targets[k] = (targets[k] or 0) + 1
		end
	end
	local survivors = 0
	for _, p in ipairs(s.players) do
		if p.alive then
			local k = key(p.nx, p.ny)
			if p.nx < 0 or p.nx >= W or p.ny < 0 or p.ny >= H or s.grid[k] or targets[k] > 1 then
				p.alive = false
			else
				p.x, p.y = p.nx, p.ny
				survivors = survivors + 1
			end
		end
	end
	for _, p in ipairs(s.players) do
		if p.alive then
			s.grid[key(p.x, p.y)] = p.slot
			p.trail[#p.trail + 1] = { p.x, p.y }
		end
	end
	if survivors <= 1 then
		for _, p in ipairs(s.players) do
			if p.alive then
				p.score = p.score + 3
			end
		end
		s.intermission = 1.4
	end
end
function M.bot(s, p)
	local options = { { p.dx, p.dy }, { -p.dy, p.dx }, { p.dy, -p.dx } }
	for _, v in ipairs(options) do
		local x, y = p.x + v[1] * 2, p.y + v[2] * 2
		if
			x >= 0
			and x < W
			and y >= 0
			and y < H
			and not s.grid[key(x, y)]
			and not s.grid[key(p.x + v[1], p.y + v[2])]
		then
			return { x = v[1], y = v[2] }
		end
	end
	return { x = p.dx, y = p.dy }
end
return M
