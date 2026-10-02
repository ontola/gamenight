-- Validated, per-game preferences. New rounds take a snapshot so edits never
-- change a running simulation halfway through a point or physics step.
local M = {}
function M.bind(game, specs)
    local values, byKey = {}, {}
    game.settings = specs
    for _, spec in ipairs(specs) do
        assert(not byKey[spec.key], "duplicate setting: " .. spec.key)
        byKey[spec.key], values[spec.key] = spec, spec.default
    end
    function game.setting(key, value)
        local spec = byKey[key]
        if not spec then return false end
        if spec.kind == "toggle" then
            if type(value) ~= "boolean" then return false end
        elseif spec.kind == "number" then
            if type(value) ~= "number" or value ~= value or value % 1 ~= 0 or value < spec.min or value > spec.max then return false end
        elseif spec.kind == "choice" then
            local found = false
            for _, option in ipairs(spec.options) do if option == value then found = true end end
            if not found then return false end
        else return false end
        values[key] = value
        return true
    end
    function game.preferences()
        local snapshot = {}
        for key, value in pairs(values) do snapshot[key] = value end
        return snapshot
    end
end
return M
