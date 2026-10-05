-- MIT. Resolve component-owned short commands to one admitted definition.
-- Session discovery lives at bee.threads.sessions:catalog; this lookup is only for
-- the existing bee <driver> shortcuts.
local definitions = require("definitions")
local bounds = require("bounds")
local registry = require("registry")
local M = {}
M.MAX_DEFINITIONS = 64
type Command = {definition_ref: string, fullscreen: boolean}

function M.command(name: string): (Command?, string?)
    if not bounds.id(name) or #name > 40 or not name:match("^[a-z][a-z0-9_-]*$") then
        return nil, "Invalid Bee command"
    end
    local found, find_error = registry.find({["meta.type"] = definitions.TYPE})
    if find_error or not found then return nil, "Agent commands could not be read" end
    if #found > M.MAX_DEFINITIONS then return nil, "Too many Agent commands to resolve" end
    local selected: Command? = nil
    for _, raw in ipairs(found) do
        local entry = bounds.object(raw)
        local ref = entry and bounds.id(entry.id) or nil
        local definition = entry and ref and definitions.decode(ref, entry) or nil
        if definition then
            for _, command in ipairs(definition.command_names) do
                if command == name then
                    if definition.default_mode ~= "window" then
                        return nil, "Bee command " .. name .. " does not select a window profile"
                    end
                    if selected then return nil, "Ambiguous Bee command: " .. name end
                    selected = {definition_ref = definition.ref, fullscreen = definition.presentation.fullscreen}
                end
            end
        end
    end
    return selected, nil
end

return M
