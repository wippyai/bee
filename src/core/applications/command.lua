-- MIT. CLI handlers are presentation metadata on host-admitted applications.
local registry = require("registry")
local catalog = require("catalog")
local arguments = require("arguments")
type Handler = {name: string, arguments: {string}, fullscreen: boolean}
type Launch = {definition_id: string, arguments: {string}, fullscreen: boolean}
local M = {}
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
function M.resolve(name: string, tail: {string}): (Launch?, string?)
    local selected: Launch? = nil
    for _, binding in ipairs(catalog.bindings()) do
        if catalog.descriptor(binding.definition_id) then
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
    if not selected then return nil, "Unknown Bee command: " .. name end
    return selected, nil
end
return M
