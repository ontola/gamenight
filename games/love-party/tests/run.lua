local U = require("shared.util")
local function roster(n)
	local p = {}
	for i = 1, n do
		p[i] = { slot = i, name = "P" .. i, score = 0 }
	end
	return p
end
local function equal(a, b)
	assert(a == b, tostring(a) .. " ~= " .. tostring(b))
end
local tests = {}
function tests.back_does_not_bounce_after_resume()
	local gate=require("shared.back_gate").new()
	gate:update(1,false)
	assert(gate:press())
	gate:reset() -- Resume while the same physical button is still held.
	gate:update(2,true)
	assert(not gate:press())
	gate:update(0.1,false)
	assert(not gate:press()) -- A focus replay is not a new deliberate press.
	gate:update(1.0,false)
	assert(gate:press())
	assert(not gate:press())
end
function tests.participation()
	local mode = require("games.siege")
	local seats = { { index = 0, occupant = { kind = "local", player_id = "one" }, controller = "ordinal:1" } }
	local ids = { { id = "one", name = "One" }, { id = "two", name = "Two" } }
	local state = mode.new(U.players(seats, ids), U.rng(1))
	state.wave, state.teamScore = 7, 123
	state.players[1].score = 42
	local original = state.players[1]
	seats[2] = { index = 1, occupant = { kind = "local", player_id = "two" }, controller = "ordinal:0" }
	local apply = require("shared.participation").apply
	apply(mode, state, seats, ids, { { player_id = "one", state = "sleeping" } })
	equal(#state.players, 2)
	equal(state.players[1], original)
	equal(original.score, 42)
	equal(original.presence, "sleeping")
	equal(state.wave, 7)
	equal(state.teamScore, 123)
	equal(state.players[2].hp, 3)
	equal(state.players[2].invul, 3)
	apply(mode, state, seats, ids, { { player_id = "one", state = "active" } })
	equal(#state.players, 2)
	equal(original.presence, "active")
	equal(original.score, 42)
end
function tests.activity_ignores_drift()
	local input = require("shared.input")
	local values, down = {}, false
	local pad = {
		isConnected = function()
			return true
		end,
		isGamepad = function()
			return true
		end,
		getGamepadAxis = function(_, axis)
			return values[axis] or 0
		end,
		isGamepadDown = function()
			return down
		end,
	}
	equal(input.meaningful(pad), false)
	values.leftx = 0.1
	equal(input.meaningful(pad), false)
	values.triggerleft = -1
	equal(input.meaningful(pad), false)
	values.rightx = 0.7
	equal(input.meaningful(pad), true)
	values.rightx = 0
	down = true
	equal(input.meaningful(pad), true)
end
function tests.participation_lifecycle()
	local messages, updates = {}, 0
	local lifecycle = require("shared.lifecycle").new({
		send = function(_, m)
			messages[#messages + 1] = m
		end,
	}, {
		hide = function() end,
		show = function() end,
		dispose = function() end,
		prepare = function() end,
		instantJoin = true,
		party = function()
			updates = updates + 1
		end,
	}, "arena")
	lifecycle:receive({ type = "prepare", game = "arena", session = "one" })
	equal(messages[1].type, "participation")
	equal(messages[1].instant_join, true)
	equal(messages[2].type, "ready")
	lifecycle:activity("ordinal:0")
	equal(#messages, 2)
	lifecycle:receive({ type = "party_updated", session = "stale" })
	equal(updates, 0)
	lifecycle:receive({ type = "party_updated", session = "one" })
	equal(updates, 1)
	lifecycle:receive({ type = "start", session = "one" })
	lifecycle:activity("ordinal:0")
	equal(messages[3].type, "controller_input")
	lifecycle:receive({ type = "pause", session = "one" })
	lifecycle:activity("ordinal:1")
	equal(#messages, 3)
end
function tests.lifecycle()
	local sent, events = {}, {}
	local transport = {
		send = function(_, m)
			sent[#sent + 1] = m
		end,
	}
	local hooks = {
		hide = function()
			events[#events + 1] = "hide"
		end,
		show = function()
			events[#events + 1] = "show"
		end,
		prepare = function()
			events[#events + 1] = "prepare"
		end,
		dispose = function() end,
	}
	local l = require("shared.lifecycle").new(transport, hooks, "test")
	l:receive({ type = "prepare", game = "test", session = "one", seats = {}, players = {} })
	equal(l.phase, "ready")
	equal(sent[1].type, "ready")
	l:receive({ type = "start", session = "wrong" })
	equal(l.phase, "ready")
	l:receive({ type = "start", session = "one" })
	equal(l.phase, "running")
	equal(events[#events], "show")
	l:receive({ type = "pause", session = "one" })
	equal(l.phase, "paused")
	equal(events[#events], "hide")
	l:receive({ type = "resume", session = "one" })
	l:finish()
	l:finish()
	equal(#sent, 2)
	equal(sent[2].type, "finished")
	equal(events[#events], "hide")
	l:receive({ type = "pause", session = "one" })
	equal(l.phase, "paused")
	l:back()
	equal(#sent, 2) -- A paused/background game must not reopen the lobby.
	l:receive({ type = "resume", session = "one" })
	l:back()
	equal(sent[3].type, "request_overlay")
	l:receive({ type = "dispose", session = "one" })
	equal(l.phase, "idle")
	equal(l.session, nil)
end
function tests.controller_identity_is_independent_of_join_order()
	local input = require("shared.input")
	local first, second, third = {}, {}, {}
	local players = U.players({
		{ index = 0, occupant = { kind = "local", player_id = "a" }, controller = "ordinal:2" },
		{ index = 1, occupant = { kind = "local", player_id = "b" }, controller = "ordinal:0" },
		{ index = 2, occupant = { kind = "local", player_id = "c" }, controller = "ordinal:1" },
	}, { { id = "a", name = "Ada" }, { id = "b", name = "Bea" }, { id = "c", name = "Cam" } })
	input.bind(players, { first, second, third })
	equal(players[1].name, "Ada")
	equal(input.pads[1], third)
	equal(input.pads[2], first)
	equal(input.pads[3], second)
end
function tests.controllers_keep_seat_holes()
	local input = require("shared.input")
	local a, b, c = {}, {}, {}
	input.bind({ { slot = 1 }, { slot = 3 } }, { a, b, c })
	equal(input.pads[3], c)
	input.detach(a)
	equal(input.pads[3], c)
	equal(input.pads[1], nil)
	local replacement = {}
	input.attach(replacement)
	equal(input.pads[1], replacement)
	equal(input.pads[3], c)
end
function tests.simultaneous_trail_collision()
	local m = require("games.trails")
	local s = m.new(roster(2), U.rng(1))
	local a, b = s.players[1], s.players[2]
	a.x, a.y, a.dx, a.dy = 10, 10, 1, 0
	b.x, b.y, b.dx, b.dy = 12, 10, -1, 0
	s.grid = {}
	m.update(s, 0.11, { { x = 0, y = 0 }, { x = 0, y = 0 } })
	equal(a.alive, false)
	equal(b.alive, false)
	equal(a.score, 0)
	equal(b.score, 0)
end
function tests.trail_no_reverse()
	local m = require("games.trails")
	local s = m.new(roster(2), U.rng(1))
	local a = s.players[1]
	local x = a.x
	m.update(s, 0.11, { { x = -1, y = 0 }, { x = 0, y = 0 } })
	equal(a.x, x + 1)
end
function tests.bumper_knockout()
	local m = require("games.bumper")
	local s = m.new(roster(2), U.rng(1))
	local a, b = s.players[1], s.players[2]
	a.x = 1200
	a.hit = b
	a.hitTime = 0
	m.update(s, 1 / 120, { { x = 0, y = 0 }, { x = 0, y = 0 } })
	equal(a.score, -1)
	equal(b.score, 3)
	assert(a.x < 900)
end
function tests.meteor_shield()
	local m = require("games.meteor")
	local s = m.new(roster(2), U.rng(1))
	local a = s.players[1]
	s.objects = { { x = a.x, y = a.y, r = 15, speed = 0 } }
	m.update(s, 0.01, { { x = 0, y = 0, action = true }, { x = 0, y = 0 } })
	assert(a.score >= 0)
	equal(#s.objects, 1)
	a.shield = 0
	m.update(s, 0.01, { { x = 0, y = 0 }, { x = 0, y = 0 } })
	assert(a.score < 0)
	equal(#s.objects, 0)
end
function tests.bot_soak_all_player_counts()
	for _, name in ipairs({ "bumper", "trails", "meteor", "blast" }) do
		local m = require("games." .. name)
		for n = 2, 4 do
			local s = m.new(roster(n), U.rng(123))
			for tick = 1, 120 * 70 do
				local input = {}
				for i, p in ipairs(s.players) do
					input[i] = m.bot(s, p)
				end
				m.update(s, 1 / 120, input)
				for _, p in ipairs(s.players) do
					assert(p.x == p.x and p.y == p.y and math.abs(p.score) < 100000)
				end
			end
		end
	end
end
require("tests.blast")
require("tests.siege")
require("tests.collection")
local n = 0
for name, test in pairs(tests) do
	test()
	n = n + 1
	print("PASS " .. name)
end
print("PASS " .. n .. " party pack tests")
