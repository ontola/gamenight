local M = {
	pads = {},
	active = {},
	keys = {
		{ "a", "d", "w", "s", "space" },
		{ "left", "right", "up", "down", "rctrl" },
		{ "j", "l", "i", "k", "u" },
		{ "f", "h", "t", "g", "r" },
	},
}
function M.bind(players, pads)
	M.pads, M.active = {}, {}
	for _, p in ipairs(players) do
		M.active[p.slot] = not p.bot
		if not p.bot then
			M.pads[p.slot] = pads[p.slot]
		end
	end
end
function M.attach(pad)
	for _, existing in pairs(M.pads) do
		if existing == pad then
			return
		end
	end
	for slot = 1, 4 do
		if M.active[slot] and not M.pads[slot] then
			M.pads[slot] = pad
			return
		end
	end
end
function M.detach(pad)
	for slot, existing in pairs(M.pads) do
		if existing == pad then
			M.pads[slot] = nil
		end
	end
end
function M.sample(slot)
	local x, y, action = 0, 0, false
	local pad = M.pads[slot]
	if pad and pad:isConnected() and pad:isGamepad() then
		x, y = pad:getGamepadAxis("leftx"), pad:getGamepadAxis("lefty")
		if math.abs(x) < 0.2 then
			x = 0
		end
		if math.abs(y) < 0.2 then
			y = 0
		end
		if pad:isGamepadDown("dpleft") then
			x = -1
		elseif pad:isGamepadDown("dpright") then
			x = 1
		end
		if pad:isGamepadDown("dpup") then
			y = -1
		elseif pad:isGamepadDown("dpdown") then
			y = 1
		end
		action = pad:isGamepadDown("a")
	end
	if love.keyboard and M.active[slot] then
		local k = M.keys[slot]
		if love.keyboard.isDown(k[1]) then
			x = -1
		elseif love.keyboard.isDown(k[2]) then
			x = 1
		end
		if love.keyboard.isDown(k[3]) then
			y = -1
		elseif love.keyboard.isDown(k[4]) then
			y = 1
		end
		action = action or love.keyboard.isDown(k[5])
	end
	local n = math.sqrt(x * x + y * y)
	if n > 1 then
		x, y = x / n, y / n
	end
	return { x = x, y = y, action = action }
end
return M
