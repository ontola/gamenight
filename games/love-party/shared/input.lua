local M = {
	pads = {},
	active = {},
	keyboardOnly = {},
	keys = {
		{ "a", "d", "w", "s", "space", "lshift" },
		{ "left", "right", "up", "down", "rctrl", "rshift" },
		{ "j", "l", "i", "k", "u", "o" },
		{ "f", "h", "t", "g", "r", "y" },
	},
}
function M.bind(players, pads)
	M.pads, M.active, M.keyboardOnly = {}, {}, {}
	for _, p in ipairs(players) do
		M.active[p.slot] = not p.bot
		if not p.bot then
			local ordinal = p.controller and tonumber(p.controller:match("^ordinal:(%d+)$"))
			M.pads[p.slot] = pads[ordinal and ordinal + 1 or p.slot]
			M.keyboardOnly[p.slot] = not p.controller and M.pads[p.slot] == nil
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
			M.keyboardOnly[slot] = false
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
function M.sample(slot, fireWithShoulder)
	local x, y, action, secondary = 0, 0, false, false
	local aimX, aimY = 0, 0
	local pad = M.pads[slot]
	if pad and pad:isConnected() and pad:isGamepad() then
		x, y = pad:getGamepadAxis("leftx"), pad:getGamepadAxis("lefty")
		aimX, aimY = pad:getGamepadAxis("rightx"), pad:getGamepadAxis("righty")
		local aim = math.sqrt(aimX * aimX + aimY * aimY)
		if aim < 0.2 then
			aimX, aimY = 0, 0
		elseif aim > 1 then
			aimX, aimY = aimX / aim, aimY / aim
		end
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
		if fireWithShoulder then
			action = pad:isGamepadDown("rightshoulder") or pad:getGamepadAxis("triggerright") > 0.25
		else
			action = pad:isGamepadDown("a")
		end
		secondary = pad:isGamepadDown("b")
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
		secondary = secondary or love.keyboard.isDown(k[6])
	end
	local n = math.sqrt(x * x + y * y)
	if n > 1 then
		x, y = x / n, y / n
	end
	return {
		x = x,
		y = y,
		action = action,
		secondary = secondary,
		aimX = aimX,
		aimY = aimY,
		autoAim = M.keyboardOnly[slot] == true,
	}
end
-- Read physical devices directly, including unassigned controllers. Stick drift
-- and idle trigger values must not create players or keep them awake.
function M.meaningful(pad)
	if not pad:isConnected() or not pad:isGamepad() then
		return false
	end
	for _, axis in ipairs({ "leftx", "lefty", "rightx", "righty" }) do
		if math.abs(pad:getGamepadAxis(axis)) > 0.25 then
			return true
		end
	end
	for _, axis in ipairs({ "triggerleft", "triggerright" }) do
		if pad:getGamepadAxis(axis) > 0.25 then
			return true
		end
	end
	return pad:isGamepadDown(
		"a",
		"b",
		"x",
		"y",
		"start",
		"back",
		"leftshoulder",
		"rightshoulder",
		"leftstick",
		"rightstick",
		"dpup",
		"dpdown",
		"dpleft",
		"dpright"
	)
end
return M
