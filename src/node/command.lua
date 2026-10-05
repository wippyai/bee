-- MIT. `bee NAME` opens the app a command names: an app lists the commands
-- it handles in its meta.application.commands, and a bee.app_command
-- registry entry names an installed app with the arguments it opens with.
local registry = require("registry")
local arguments = require("arguments")
type Handler = {name: string, arguments: {string}, fullscreen: boolean}
type Launch = {definition_id: string, arguments: {string}, fullscreen: boolean}
type ApplicationCommand = {name: string, definition_id: string, arguments: {string}, fullscreen: boolean}

local M = {}
M.TYPE = "bee.app_command"

local function command_name(name: unknown): string?
    if type(name) ~= "string" or #name == 0 or #name > 40 or not name:match("^[a-z][a-z0-9_-]*$") then return nil end
    if name == "run" or name == "runtime" or name == "update" or name == "client" or name == "node" then return nil end
    return name
end

function M.decode(value: unknown): {Handler}?
    if value == nil then return {} end
    if type(value) ~= "table" then return nil end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 16 then return nil end
        count = count + 1
    end
    local result: {Handler} = {}
    local seen: {[string]: boolean} = {}
    for index = 1, count do
        local item: unknown = value[index]
        if type(item) ~= "table" then return nil end
        local name = command_name(item.name)
        local fullscreen = item.fullscreen
        if not name or seen[name] then return nil end
        if fullscreen ~= nil and type(fullscreen) ~= "boolean" then return nil end
        local prefix = arguments.decode(item.arguments)
        if not prefix then return nil end
        seen[name] = true
        result[#result + 1] = {name = name, arguments = prefix, fullscreen = fullscreen == true}
    end
    return result
end

function M.decode_command(value: unknown): ApplicationCommand?
    if type(value) ~= "table" then return nil end
    local data = value
    if type(value.data) == "table" then data = value.data end
    local name = command_name(data.name)
    if not name then return nil end
    local definition_id = data.definition_id
    if type(definition_id) ~= "string" or #definition_id == 0 or #definition_id > 128 then return nil end
    local fullscreen = data.fullscreen
    if fullscreen ~= nil and type(fullscreen) ~= "boolean" then return nil end
    local prefix = arguments.decode(data.arguments)
    if not prefix then return nil end
    return {name = name, definition_id = definition_id, arguments = prefix, fullscreen = fullscreen == true}
end

-- resolve finds the one installed app command name opens, with tail after
-- its own arguments. installed maps the app definitions the node runs.
function M.resolve(name: string, tail: {string}, installed: {[string]: boolean}): (Launch?, string?)
    if not command_name(name) then return nil, "Invalid Bee command" end
    local selected: Launch? = nil
    local function select(definition_id: string, prefix: {string}, fullscreen: boolean): string?
        if selected then return "Ambiguous Bee command: " .. name end
        local values: {string} = {}
        for _, value in ipairs(prefix) do values[#values + 1] = value end
        for _, value in ipairs(tail) do values[#values + 1] = value end
        local decoded = arguments.decode(values)
        if not decoded then return "Too many or oversized application arguments" end
        selected = {definition_id = definition_id, arguments = decoded, fullscreen = fullscreen}
        return nil
    end
    local ids: {string} = {}
    for id in pairs(installed) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local entry, err = registry.get(id)
        if err or not entry then return nil, tostring(err or "app " .. id .. " is not installed") end
        local meta: unknown = entry.meta.application
        if type(meta) ~= "table" then return nil, "Invalid application metadata: " .. id end
        local handlers = M.decode(meta.commands)
        if not handlers then return nil, "Invalid command handlers: " .. id end
        for _, handler in ipairs(handlers) do
            if handler.name == name then
                local problem = select(id, handler.arguments, handler.fullscreen)
                if problem then return nil, problem end
            end
        end
    end
    local entries, find_error = registry.find({[".kind"] = "registry.entry", ["meta.type"] = M.TYPE})
    if find_error then return nil, tostring(find_error) end
    if #(entries or {}) > 64 then return nil, "Too many application commands" end
    for _, raw in ipairs(entries or {}) do
        local declared = M.decode_command(raw)
        if not declared then return nil, "Invalid application command: " .. tostring(raw.id) end
        if declared.name == name and installed[declared.definition_id] then
            if declared.definition_id == "bee.harness.app:app" and #tail > 0 then
                return nil, "Managed Bee command does not accept raw arguments: " .. name
            end
            local problem = select(declared.definition_id, declared.arguments, declared.fullscreen)
            if problem then return nil, problem end
        end
    end
    if not selected then return nil, "Unknown Bee command: " .. name end
    return selected, nil
end

return M
