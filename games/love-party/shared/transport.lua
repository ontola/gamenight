--- GameNight v1's newline-delimited TCP transport. LuaSocket ships with LÖVE.
local json = require("vendor.json")
local Transport = {}
Transport.__index = Transport

function Transport.new(addr, game, token)
	local host, port = addr:match("^%[([^%]]+)%]:(%d+)$")
	if not host then
		host, port = addr:match("^([^:]+):(%d+)$")
	end
	assert(host and port, "GAMENIGHT_ADDR must be host:port")
	local socket = require("socket")
	local peer = assert(host:find(":", 1, true) and socket.tcp6() or socket.tcp())
	peer:settimeout(3)
	assert(peer:connect(host, tonumber(port)))
	peer:settimeout(0)
	local self = setmetatable({ peer = peer, incoming = "", outgoing = "" }, Transport)
	self:send({ type = "hello", role = "game", game = game, token = token })
	return self
end

function Transport:send(message)
	self.outgoing = self.outgoing .. json.encode(message) .. "\n"
end

function Transport:poll(receive)
	if #self.outgoing > 0 then
		local sent, err, partial = self.peer:send(self.outgoing)
		self.outgoing = self.outgoing:sub((sent or partial or 0) + 1)
		if err and err ~= "timeout" then
			return nil, err
		end
	end
	-- Bound each frame's work, and preserve partial lines across frames.
	for _ = 1, 64 do
		local line, err, partial = self.peer:receive("*l", self.incoming)
		self.incoming = line and "" or (partial or "")
		if #self.incoming > 1024 * 1024 then
			return nil, "message too large"
		end
		if line then
			if #line > 1024 * 1024 then
				return nil, "message too large"
			end
			local ok, message = pcall(json.decode, line)
			if not ok or type(message) ~= "table" then
				return nil, "invalid JSON message"
			end
			receive(message)
		elseif err == "timeout" then
			return true
		else
			return nil, err
		end
	end
	return true
end

function Transport:close()
	self.peer:close()
end

return Transport
