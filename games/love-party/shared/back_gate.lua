-- A newly focused window can receive the press that resumed it. Require
-- a short, continuously released interval before accepting a fresh Back.
local Gate = {}
Gate.__index = Gate
function Gate.new() return setmetatable({released = 0}, Gate) end
function Gate:reset() self.released = 0 end
function Gate:update(dt, held)
	self.released = held and 0 or math.min(1.0, self.released + dt)
end
function Gate:press()
	local armed = self.released >= 1.0
	self:reset()
	return armed
end
return Gate
