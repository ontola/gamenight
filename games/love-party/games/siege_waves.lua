-- Authored formations repeat in a readable order; difficulty follows clears,
-- never elapsed time. A struggling team cannot accumulate another wave.
local W = { names = { "SWEEP", "PINCER", "CORNERS", "CROSSWIND" }, rest = 3, warning = 1.4 }
function W.plan(number, players, width, height)
	local count = math.min(32, 8 + (number - 1) * 2 + math.max(0, players - 2) * 3)
	local pattern = (number - 1) % 4 + 1
	local rotation = math.floor((number - 1) / 4) % 4
	local groups = pattern == 1 and 2 or 3
	local plan = {}
	for i = 1, count do
		local group = (i - 1) % groups
		local lane = math.floor((i - 1) / groups)
		local lanes = math.ceil((count - group) / groups)
		local t = (lane + 1) / (lanes + 1)
		local side
		if pattern == 1 then
			side = rotation
		elseif pattern == 2 then
			side = (rotation + (group % 2) * 2) % 4
		elseif pattern == 3 then
			side = (rotation + group) % 4
			t = 0.12 + t * 0.25
		else
			side = (rotation + group) % 4
		end
		local x, y
		if side == 0 then
			x, y = 30, 60 + t * (height - 120)
		elseif side == 1 then
			x, y = 60 + t * (width - 120), 30
		elseif side == 2 then
			x, y = width - 30, 60 + t * (height - 120)
		else
			x, y = 60 + t * (width - 120), height - 30
		end
		local kind = "chaser"
		if number >= 7 and i % 10 == 0 then
			kind = "fort"
		elseif number >= 5 and i % 7 == 0 then
			kind = "splitter"
		elseif number >= 3 and i % 3 == 0 then
			kind = "weaver"
		end
		plan[#plan + 1] = { x = x, y = y, kind = kind, at = group * 2.2, group = group }
	end
	return plan, W.names[pattern]
end
function W.update(s, dt, spawn)
	if s.wavePhase == "rest" then
		s.waveRest = math.max(0, s.waveRest - dt)
		if s.waveRest == 0 then
			s.wave = s.wave + 1
			s.waveClock = 0
			s.wavePhase = "attack"
			s.waveQueue, s.waveName = W.plan(s.wave, #s.players, s.width, s.height)
		end
		return
	end
	s.waveClock = s.waveClock + dt
	for i = #s.waveQueue, 1, -1 do
		local entry = s.waveQueue[i]
		if entry.at <= s.waveClock then
			spawn(s, entry.kind, entry.x, entry.y, W.warning)
			table.remove(s.waveQueue, i)
		end
	end
	if #s.waveQueue == 0 and #s.enemies == 0 then
		s.wavePhase = "rest"
		s.waveRest = W.rest
		-- Stray turret bullets must not spoil the earned breathing room.
		s.hostile = {}
	end
end
return W
