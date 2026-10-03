local B = require("games.blast")
local U = require("shared.util")
local function arena()
	local players = { { slot = 1, name = "A", score = 0 }, { slot = 2, name = "B", score = 0 } }
	local s = B.new(players, U.rng(1))
	for y = 1, 9 do
		for x = 1, 17 do
			s.tiles[B.key(x, y)] = "floor"
		end
	end
	s.drops, s.items = {}, {}
	players[1].x, players[1].y = 5, 5
	players[2].x, players[2].y = 16, 8
	return s, players[1], players[2]
end
local idle = { { x = 0, y = 0 }, { x = 0, y = 0 } }
local function has(s, x, y)
	return s.flames[B.key(x, y)] ~= nil
end
local tests = {}
function tests.seeded_levels_have_safe_spawns_and_connected_terrain()
	local fingerprints = {}
	for seed = 1, 120 do
		local a = B.generate(U.rng(seed))
		local b = B.generate(U.rng(seed))
		local signature = {}
		for k = 0, 208 do
			assert(a[k] == b[k])
			signature[#signature + 1] = a[k]
		end
		fingerprints[table.concat(signature)] = true
		for _, v in ipairs({ { 1, 1 }, { 17, 9 }, { 1, 9 }, { 17, 1 } }) do
			assert(a[B.key(v[1], v[2])] == "floor")
			local exits = 0
			for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
				if a[B.key(v[1] + d[1], v[2] + d[2])] == "floor" then
					exits = exits + 1
				end
			end
			assert(exits >= 2, "spawn must have two escape routes")
		end
		-- Crates can be removed; fixed geometry must never partition the arena.
		local queue = { { 1, 1 } }
		local visited = { [B.key(1, 1)] = true }
		local i = 1
		while i <= #queue do
			local v = queue[i]
			i = i + 1
			for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
				local x, y = v[1] + d[1], v[2] + d[2]
				local k = B.key(x, y)
				if a[k] and a[k] ~= "wall" and not visited[k] then
					visited[k] = true
					queue[#queue + 1] = { x, y }
				end
			end
		end
		for k, kind in pairs(a) do
			if kind ~= "wall" then
				assert(visited[k], "isolated tile")
			end
		end
	end
	local n = 0
	for _ in pairs(fingerprints) do
		n = n + 1
	end
	assert(n > 100, "levels should vary")
end
function tests.crates_stop_blast_and_reveal_power()
	local s, p = arena()
	p.range = 4
	s.tiles[B.key(7, 5)] = "crate"
	s.drops[B.key(7, 5)] = "kick"
	local b = B.placeBomb(s, p)
	b.fuse = 0
	B.update(s, 0.01, idle)
	assert(has(s, 7, 5) and not has(s, 8, 5))
	assert(s.tiles[B.key(7, 5)] == "floor")
	assert(s.items[B.key(7, 5)] == "kick")
end
function tests.solid_walls_block_every_shape()
	for _, shape in ipairs({ "cross", "diagonal", "beam", "star" }) do
		local s, p = arena()
		p.shape = shape
		p.range = 4
		local dx, dy = 1, shape == "diagonal" and 1 or 0
		s.tiles[B.key(5 + dx, 5 + dy)] = "wall"
		local b = B.placeBomb(s, p)
		b.fuse = 0
		B.update(s, 0.01, idle)
		assert(not has(s, 5 + dx, 5 + dy))
		assert(not has(s, 5 + dx * 2, 5 + dy * 2))
	end
end
function tests.explosion_shapes_are_distinct()
	local counts = { cross = 9, diagonal = 9, beam = 9, star = 17 }
	for shape, count in pairs(counts) do
		local s, p = arena()
		p.shape = shape
		local b = B.placeBomb(s, p)
		b.fuse = 0
		B.update(s, 0.01, idle)
		local n = 0
		for _ in pairs(s.flames) do
			n = n + 1
		end
		assert(n == count, shape)
		if shape == "diagonal" then
			assert(has(s, 6, 6) and not has(s, 6, 5))
		end
		if shape == "beam" then
			assert(has(s, 9, 5) and not has(s, 5, 6))
		end
	end
end
function tests.remote_waits_for_its_owner_and_chains()
	local s, p, q = arena()
	p.remote = true
	local a = B.placeBomb(s, p)
	p.x, p.y = 1, 1
	B.update(s, 20, idle)
	assert(#s.bombs == 1 and a.fuse > 0 and next(s.flames) == nil)
	B.update(s, 0.01, { { x = 0, y = 0 }, { x = 0, y = 0, secondary = true } })
	assert(#s.bombs == 1, "other player cannot detonate")
	q.x, q.y = 7, 5
	local b = B.placeBomb(s, q)
	q.x, q.y = 16, 8
	B.update(s, 0.01, { { x = 0, y = 0, secondary = true }, { x = 0, y = 0 } })
	assert(#s.bombs == 0 and b.dead and has(s, 9, 5), "remote must trigger the chain")
end
function tests.kick_rolls_without_resetting_fuse_or_owner()
	local s, p, q = arena()
	p.x, p.y = 3, 5
	p.kick = true
	q.x, q.y = 4, 5
	local b = B.placeBomb(s, q)
	q.x, q.y = 16, 8
	B.update(s, 0.01, { { x = 1, y = 0 }, { x = 0, y = 0 } })
	assert(p.x == 4 and b.x == 5 and b.owner == q and b.fuse < 2.3)
	B.update(s, 0.08, idle)
	assert(b.x == 6 and b.fuse < 2.22)
	s.tiles[B.key(7, 5)] = "wall"
	B.update(s, 0.08, idle)
	assert(b.x == 6 and not b.sx)
end
function tests.no_kick_no_pass_and_one_bomb_per_press()
	local s, p, q = arena()
	p.x, p.y = 3, 5
	q.x, q.y = 4, 5
	B.placeBomb(s, q)
	q.x, q.y = 16, 8
	B.update(s, 0.01, { { x = 1, y = 0 }, { x = 0, y = 0 } })
	assert(p.x == 3)
	B.update(s, 0.01, { { x = 0, y = 0, action = true }, { x = 0, y = 0 } })
	assert(#s.bombs == 2)
	p.x = 2
	B.update(s, 0.01, { { x = 0, y = 0, action = true }, { x = 0, y = 0 } })
	assert(#s.bombs == 2)
	B.update(s, 0.01, idle)
	B.update(s, 0.01, { { x = 0, y = 0, action = true }, { x = 0, y = 0 } })
	assert(#s.bombs == 3)
end
function tests.powerups_apply_only_to_future_bombs()
	local s, p = arena()
	local before = B.placeBomb(s, p)
	for _, power in ipairs({ "remote", "kick", "star", "range", "capacity", "speed" }) do
		B.pickup(p, power)
	end
	assert(p.remote and p.kick and p.shape == "star" and p.range == 3 and p.capacity == 3 and p.speed == 7)
	assert(before.shape == "cross" and before.range == 2 and not before.remote)
end
function tests.round_replaces_level_and_resets_powers_without_losing_score()
	local s, p, q = arena()
	p.kick = true
	p.score = 9
	q.alive = false
	for _ = 1, 300 do
		B.update(s, 0.01, idle)
	end
	assert(s.round == 2 and p.alive and q.alive and not p.kick and p.score == 12)
end
local count = 0
for name, fn in pairs(tests) do
	fn()
	count = count + 1
	print("PASS blast: " .. name)
end
print("PASS " .. count .. " blast tests")
return true
