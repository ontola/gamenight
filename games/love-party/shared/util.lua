local M = {}
function M.clamp(v, a, b)
	return math.max(a, math.min(b, v))
end
function M.length(x, y)
	return math.sqrt(x * x + y * y)
end
function M.rng(seed)
	return function(a, b)
		seed = (seed * 16807) % 2147483647
		local r = (seed - 1) / 2147483646
		if a then
			return a + math.floor(r * (b - a + 1))
		end
		return r
	end
end
function M.players(seats, identities)
	local out = {}
	for _, seat in ipairs(seats) do
		if seat.occupant.kind ~= "empty" then
			local name, color, avatar, skin_color = "P" .. (seat.index + 1), nil, nil, nil
			for _, identity in ipairs(identities) do
				if identity.id == seat.occupant.player_id then
					name = identity.name
					color = identity.color
                    avatar, skin_color = identity.avatar, identity.skin_color
				end
			end
			out[#out + 1] = {
				slot = seat.index + 1,
				id = seat.occupant.player_id,
				name = name,
				bot = seat.occupant.kind == "ai",
				color = color,
                avatar = avatar, skin_color = skin_color,
				score = 0,
				controller = seat.controller,
			}
		end
	end
	return out
end
return M
