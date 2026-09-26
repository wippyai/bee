-- MIT. CLI handlers are presentation metadata on host-admitted applications.
local registry = require("registry")
local catalog = require("catalog")
local arguments = require("arguments")
type Handler = {name: string, arguments: {string}, fullscreen: boolean}
type Launch = {definition_id: string, arguments: {string}, fullscreen: boolean}
type ApplicationCommand = {name: string, definition_id: string, arguments: {string}, fullscreen: boolean}

local KNOWN_PACKAGES: {[string]: string} = {
    agy = "bee/agents",
    claude = "bee/agents",
    codex = "bee/agents",
    grok = "bee/agents",
    muse = "bee/agents",
    opencode = "bee/agents",
    agent = "bee/agents",
}

local M = {}
M.KNOWN_PACKAGES = KNOWN_PACKAGES

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
        local name = item.name
        local fullscreen = item.fullscreen
        if type(name) ~= "string" then return nil end
        if #name > 40 or not name:match("^[a-z][a-z0-9_-]*$") or seen[name] then return nil end
        if name == "run" or name == "runtime" or name == "update" then return nil end
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
    local raw = value :: {[string]: unknown}
    local data = raw
    if type(raw.data) == "table" then
        data = raw.data :: {[string]: unknown}
    end
    local name = data.name
    if type(name) ~= "string" or #name == 0 or #name > 40 or not name:match("^[a-z][a-z0-9_-]*$") then
        return nil
    end
    if name == "run" or name == "runtime" or name == "update" then
        return nil
    end
    local definition_id = data.definition_id
    if type(definition_id) ~= "string" or #definition_id == 0 or #definition_id > 128 then
        return nil
    end
    local fullscreen = data.fullscreen
    if fullscreen ~= nil and type(fullscreen) ~= "boolean" then
        return nil
    end
    local prefix = arguments.decode(data.arguments)
    if not prefix then
        return nil
    end
    local name_str: string = name :: string
    local def_id_str: string = definition_id :: string
    local result: ApplicationCommand = {
        name = name_str,
        definition_id = def_id_str,
        arguments = prefix,
        fullscreen = fullscreen == true,
    }
    return result
end

function M.unknown_error(name: string): string
    local provider = KNOWN_PACKAGES[name]
    if provider then
        return "Unknown Bee command: " .. name .. " (install " .. provider .. ")"
    end
    return "Unknown Bee command: " .. name
end

function M.resolve(name: string, tail: {string}): (Launch?, string?)
    if type(name) ~= "string" or #name == 0 or #name > 40 or not name:match("^[a-z][a-z0-9_-]*$") then
        return nil, "Invalid Bee command"
    end

    local admitted: {[string]: boolean} = {}
    local selected: Launch? = nil

    for _, binding in ipairs(catalog.bindings()) do
        if catalog.descriptor(binding.definition_id) then
            admitted[binding.definition_id] = true
            local entry, err = registry.get(binding.definition_id)
            if err then return nil, tostring(err) end
            local meta: unknown = entry.meta.application
            if type(meta) ~= "table" then return nil, "Invalid application metadata" end
            local handlers = M.decode(meta.commands)
            if not handlers then return nil, "Invalid command handlers: " .. binding.definition_id end
            for _, handler in ipairs(handlers) do
                if handler.name == name then
                    if selected then return nil, "Ambiguous Bee command: " .. name end
                    local values: {string} = {}
                    for _, value in ipairs(handler.arguments) do values[#values + 1] = value end
                    for _, value in ipairs(tail) do values[#values + 1] = value end
                    local decoded = arguments.decode(values)
                    if not decoded then return nil, "Too many or oversized application arguments" end
                    selected = {definition_id = binding.definition_id, arguments = decoded, fullscreen = handler.fullscreen}
                end
            end
        end
    end

    local entries, find_error = registry.find({["meta.type"] = "bee.application_command"})
    if find_error then return nil, tostring(find_error) end
    if entries then
        if #entries > 64 then return nil, "Too many application commands" end
        for _, raw in ipairs(entries) do
            local cmd = M.decode_command(raw)
            if not cmd then return nil, "Invalid application command: " .. tostring(raw.id) end
            if cmd.name == name and admitted[cmd.definition_id] then
                if selected then return nil, "Ambiguous Bee command: " .. name end
                if cmd.definition_id == "bee.harness.window:app" and #tail > 0 then
                    return nil, "Managed Bee command does not accept raw arguments: " .. name
                end
                local values: {string} = {}
                for _, value in ipairs(cmd.arguments) do values[#values + 1] = value end
                for _, value in ipairs(tail) do values[#values + 1] = value end
                local decoded = arguments.decode(values)
                if not decoded then return nil, "Too many or oversized application arguments" end
                selected = {definition_id = cmd.definition_id, arguments = decoded, fullscreen = cmd.fullscreen}
            end
        end
    end

    if not selected then
        return nil, M.unknown_error(name)
    end
    return selected, nil
end

return M
