-- Local-only mailbox in this isolated world's directory. No remote evaluation.
-- Use Mineclonia's multiplicative physics API so sprint, potions and equipment
-- retain their factors. Removing OUR factor restores those effects, too.
local store = core.get_mod_storage()
local saved = store:get_string("state")
local state = (saved ~= "" and core.parse_json(saved)) or {
    revision = 0, values = {gravity = 1, jump = 1}, previous = false,
}
local dir = core.get_worldpath() .. "/gamenight"
core.mkdir(dir)
-- A tested mod installation is a new revision, even when physics is unchanged.
local manifest = io.open(dir .. "/mod-current.json", "rb")
if manifest then
    local content = core.parse_json(manifest:read(4096)); manifest:close()
    if content and content.request_id ~= state.mod_request_id then
        state.mod_hash = content.sha256
        state.mod_request_id = content.request_id
        state.can_undo_mod = type(content.previous_values) == "table"
        state.mod_values = content.values
        state.revision = state.revision + 1
        store:set_string("state", core.write_json(state))
    end
end
local contract_file = assert(io.open(core.get_modpath("gamenight_bridge") .. "/settings.json", "rb"))
local specs = assert(core.parse_json(contract_file:read("*a")))
contract_file:close()
local saved_time_speed = state.values.time_speed
for key, spec in pairs(specs) do
    if state.values[key] == nil then state.values[key] = spec.default end
end
-- Read the engine clock rather than resetting it when this adapter starts.
state.values.time_of_day = (core.get_timeofday() or 0.5) * 24
state.values.time_speed = saved_time_speed or tonumber(core.settings:get("time_speed")) or 72
core.settings:set("time_speed", tostring(state.values.time_speed))
local shutdown_after
local factor_id = "gamenight:session"
local function apply(player)
    for key, spec in pairs(specs) do
        if spec.physics then
            local value = state.values[key]
            if value == 1 then
                playerphysics.remove_physics_factor(player, spec.physics, factor_id)
            else
                playerphysics.add_physics_factor(player, spec.physics, factor_id, value)
            end
        end
    end
    if state.values.bounce > 0 then
        local meta = player:get_meta()
        local given = meta:get_int("gamenight:live_pads_count")
        if given < 8 then
            local rest = player:get_inventory():add_item("main", "gamenight_bridge:bounce_pad " .. (8-given))
            meta:set_int("gamenight:live_pads_count", 8-rest:get_count())
        end
    end
end
local function apply_world(changed)
    if changed.time_of_day ~= nil then core.set_timeofday(state.values.time_of_day / 24) end
    if changed.time_speed ~= nil then core.settings:set("time_speed", tostring(state.values.time_speed)) end
end
core.register_node("gamenight_bridge:bounce_pad", {
    description = "GameNight bounce pad",
    tiles = {"mcl_core_iron_block.png^[colorize:#ad6cfa:150"},
    groups = {cracky=1, pickaxey=1}, _mcl_hardness=1, _mcl_blast_resistance=1,
})
local cooldown, elapsed, bounce_events = {}, 0, 0
core.register_globalstep(function(dt)
    elapsed = elapsed + dt
    if state.values.bounce <= 0 then return end
    for _, player in ipairs(core.get_connected_players()) do
        local pos, name = player:get_pos(), player:get_player_name()
        local below = core.get_node({x=pos.x, y=pos.y-0.2, z=pos.z})
        if below.name == "gamenight_bridge:bounce_pad" and elapsed >= (cooldown[name] or 0) then
            player:add_velocity({x=0, y=8*state.values.bounce, z=0})
            cooldown[name] = elapsed + 0.8
            bounce_events = bounce_events + 1
        end
    end
end)
core.register_on_leaveplayer(function(player) cooldown[player:get_player_name()] = nil end)
local function persist()
    store:set_string("state", core.write_json(state))
end
local function snapshot()
    state.values.time_of_day = core.get_timeofday() * 24
    local players = {}
    for _, player in ipairs(core.get_connected_players()) do
        table.insert(players, {
            name = player:get_player_name(), position = player:get_pos(),
            physics = player:get_physics_override(), velocity = player:get_velocity(),
            bounce_pads = player:get_inventory():contains_item("main", "gamenight_bridge:bounce_pad"),
        })
    end
    return {revision = state.revision, values = state.values, players = players,
        bounce_events = bounce_events, time_of_day = core.get_timeofday() * 24,
        time_speed = tonumber(core.settings:get("time_speed")) or 72,
        mod_values = state.mod_values or {}, can_undo_mod = state.can_undo_mod or false, can_undo = type(state.previous) == "table", game = "mineclonia", game_time = core.get_gametime()}
end
local function run(request)
    if type(request) ~= "table" or type(request.id) ~= "string"
        or #request.id > 64 or not request.id:match("^[a-zA-Z0-9_-]+$") then
        return {ok = false, error = "invalid request id"}
    end
    -- Durable duplicate detection: retries never reapply a change or shutdown.
    local key = "request:" .. request.id
    local previous = store:get_string(key)
    local old = previous ~= "" and core.parse_json(previous)
    if old then
        if old.request ~= core.write_json(request) then
            return {ok = false, error = "request id already used"}
        end
        return old.response
    end
    local result = {ok = false, id = request.id}
    if request.action == "status" then
        result.ok = true
    elseif request.expected_revision ~= state.revision then
        result.error = "state changed; read status and retry with a new id"
    elseif request.action == "set" then
        local v = request.values
        local valid = type(v) == "table" and next(v) ~= nil
        if valid then
            for k, value in pairs(v) do
                local spec = specs[k]
                if not spec or type(value) ~= "number" or value ~= value
                    or value < spec.min or value > spec.max then valid = false end
            end
        end
        if not valid then
            result.error = "unsupported setting or value outside the live contract"
        else
            state.values.time_of_day = core.get_timeofday() * 24
            state.previous = {}
            for k, value in pairs(v) do
                state.previous[k] = state.values[k]
                state.values[k] = value
            end
            apply_world(v)
            state.revision = state.revision + 1
            result.ok = true
        end
    elseif request.action == "undo" and type(state.previous) == "table" then
        for k, value in pairs(state.previous) do state.values[k] = value end
        apply_world(state.previous)
        state.previous = false
        state.revision = state.revision + 1
        result.ok = true
    elseif request.action == "keep" then
        state.previous = false
        state.revision = state.revision + 1
        result.ok = true
    elseif request.action == "shutdown" then
        result.ok = true
    elseif request.action == "disconnect_views" then
        -- Host-owned local lifecycle command; never exposed to model proposals.
        -- Remove old peers before replacement views reuse their saved identity.
        for _, player in ipairs(core.get_connected_players()) do
            local name = player:get_player_name()
            if name == "Couch1" or name == "Couch2" then
                core.kick_player(name, "Reconnecting GameNight view")
            end
        end
        result.ok = true
    else
        result.error = "unsupported action or nothing to undo"
    end
    if result.ok then
        persist()
        for _, player in ipairs(core.get_connected_players()) do apply(player) end
    end
    result.state = snapshot()
    store:set_string(key, core.write_json({request = core.write_json(request), response = result}))
    if result.ok and request.action == "shutdown" then
        shutdown_after = core.get_us_time() + 500000
    end
    return result
end
core.register_on_joinplayer(function(player)
    core.after(0, function()
        if player and player:is_player() then apply(player) end
    end)
end)
local last_poll = 0
local function poll()
    local now = core.get_us_time()
    if shutdown_after and now >= shutdown_after then
        core.request_shutdown("GameNight prototype saved", false, 0)
        shutdown_after = nil
    end
    if now - last_poll < 200000 then return end
    last_poll = now
    core.safe_file_write(dir .. "/status.json", core.write_json(snapshot()))
    local path = dir .. "/request.json"
    local file = io.open(path, "rb")
    if not file then return end
    local text = file:read(8193)
    file:close()
    os.remove(path)
    local request = #text <= 8192 and core.parse_json(text) or nil
    local response = run(request)
    core.safe_file_write(dir .. "/response.json", core.write_json(response))
end
core.register_globalstep(poll)
-- Called by the opt-in engine adapter without stepping mobs, timers or physics.
core.gamenight_paused_callbacks = {poll}
