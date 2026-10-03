local Lifecycle = {}
Lifecycle.__index = Lifecycle
function Lifecycle.new(transport, hooks, game)
	hooks.hide()
	return setmetatable({ transport = transport, hooks = hooks, game = game, phase = "idle" }, Lifecycle)
end
function Lifecycle:dispose()
	self.hooks.hide()
	self.hooks.dispose()
	self.session, self.phase = nil, "idle"
end
function Lifecycle:receive(m)
	if m.type == "welcome" then
		assert(m.protocol_version == 1, "Unsupported GameNight protocol")
	elseif m.type == "prepare" and m.game == self.game and m.session ~= self.session then
		self:dispose()
		self.session = m.session
		self.hooks.prepare(m.seats or {}, m.players or {})
		self.phase = "ready"
		if self.hooks.party then
			self.transport:send({
				type = "participation",
				session = self.session,
				instant_join = self.hooks.instantJoin == true,
			})
		end
		self.transport:send({ type = "ready", session = self.session })
	elseif self.session and m.session == self.session then
		if m.type == "party_updated" and self.hooks.party then
			self.hooks.party(m.seats or {}, m.players or {}, m.presence or {})
		elseif m.type == "start" and self.phase == "ready" then
			self.phase = "running"
			self.hooks.show()
		elseif m.type == "pause" and (self.phase == "running" or self.phase == "finished") then
			self.previous = self.phase
			self.phase = "paused"
			self.hooks.hide()
		elseif m.type == "resume" and self.phase == "paused" then
			self.phase = self.previous
			self.hooks.show()
		elseif m.type == "dispose" then
			self:dispose()
		end
	end
end
function Lifecycle:update()
	local ok, err = self.transport:poll(function(m)
		self:receive(m)
	end)
	if not ok then
		self:dispose()
		self.transport:close()
		self.hooks.quit(err)
	end
end
function Lifecycle:finish()
	if self.phase == "running" then
		self.phase = "finished"
		self.hooks.hide()
		self.transport:send({ type = "finished", session = self.session })
	end
end
function Lifecycle:activity(controller)
	if self.phase == "running" and self.session then
		self.transport:send({ type = "controller_input", session = self.session, controller = controller })
	end
end
function Lifecycle:back()
	if self.phase == "running" or self.phase == "finished" then
		self.transport:send({ type = "request_overlay" })
	end
end
return Lifecycle
