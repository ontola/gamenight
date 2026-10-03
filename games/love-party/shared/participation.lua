-- Apply party changes to a running match without resetting scores or world state.
local U = require("shared.util")
local M = {}
function M.apply(mode, state, seats, identities, presence)
	local roster = U.players(seats, identities)
	local nextPlayers = {}
	for _, incoming in ipairs(roster) do
		local player
		for _, existing in ipairs(state.players) do
			if
				incoming.id and existing.id == incoming.id
				or incoming.bot and existing.bot and incoming.slot == existing.slot
			then
				player = existing
				break
			end
		end
		if not player and mode.join then
			player = incoming
			mode.join(state, player)
		end
		if player then
			player.name, player.color, player.controller = incoming.name, incoming.color, incoming.controller
			player.slot, player.id, player.bot = incoming.slot, incoming.id, incoming.bot
			player.presence = "active"
			for _, status in ipairs(presence) do
				if status.player_id == player.id then
					player.presence = status.state
				end
			end
			nextPlayers[#nextPlayers + 1] = player
		end
	end
	state.players = nextPlayers
	return roster
end
return M
