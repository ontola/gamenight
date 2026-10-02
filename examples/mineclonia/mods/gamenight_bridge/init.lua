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
local shutdown_after
local factor_id = "gamenight:session"
local function apply(player)
    for key, value in pairs(state.values) do
        if value == 1 then
            playerphysics.remove_physics_factor(player, key, factor_id)
        else
            playerphysics.add_physics_factor(player, key, factor_id, value)
        end
    end
end
local function persist()
    store:set_string("state", core.write_json(state))
end
local function snapshot()
    local players = {}
    for _, player in ipairs(core.get_connected_players()) do
        table.insert(players, {
            name = player:get_player_name(), position = player:get_pos(),
            physics = player:get_physics_override(),
        })
    end
    return {revision = state.revision, values = state.values, players = players,
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
                if (k ~= "gravity" and k ~= "jump") or type(value) ~= "number"
                    or value ~= value or value < 0.25 or value > 2 then valid = false end
            end
        end
        if not valid then
            result.error = "only gravity and jump factors in [0.25, 2] are supported"
        else
            state.previous = {gravity = state.values.gravity, jump = state.values.jump}
            for k, value in pairs(v) do state.values[k] = value end
            state.revision = state.revision + 1
            result.ok = true
        end
    elseif request.action == "undo" and type(state.previous) == "table" then
        state.values = state.previous
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
