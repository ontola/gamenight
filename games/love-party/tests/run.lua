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
	l:back()
	equal(sent[3].type, "request_overlay")
	l:receive({ type = "dispose", session = "one" })
	equal(l.phase, "idle")
	equal(l.session, nil)
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
	for _, name in ipairs({ "bumper", "trails", "meteor" }) do
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
local n = 0
for name, test in pairs(tests) do
	test()
	n = n + 1
	print("PASS " .. name)
end
print("PASS " .. n .. " party pack tests")
