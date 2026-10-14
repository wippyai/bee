-- MIT
local bounds = require("bounds")
local schemas = require("schemas")

local M = {}
type Object = {[string]: unknown}
type Operation = {ref: string, application_ref: string, service: string, name: string,
    revision: string, mode: string, effect: string, input: Object, output: Object}

local function name(raw: unknown): string?
    local value = bounds.line(raw, 64)
    if not value or not value:match("^[A-Za-z0-9][A-Za-z0-9_.-]*$") then return nil end
    return value
end

function M.decode(raw: unknown, host: boolean?): (Operation?, string?)
    local entry = bounds.object(raw)
    local meta = entry and bounds.object(entry.meta) or nil
    if not entry or not meta then return nil, nil end
    local mode = bounds.member(meta.hive, {"open", "policy"})
    if meta.hive ~= nil and not mode then
        return nil, "Hive mode must be open or policy"
    end
    if meta.hive_service == nil and meta.hive_operation == nil then return nil, nil end
    local ref = entry and bounds.id(entry.id) or nil
    local service = name(meta.hive_service)
    local declared = bounds.object(meta.hive_operation)
    if not ref or entry.kind ~= "function.lua" or not service or not declared
        or not mode then
        return nil, "Hive declaration requires a function, mode, service and operation"
    end
    local data = bounds.object(entry.data)
    if data and data.security ~= nil and not host then
        return nil, "Hive application operation declares its own security; it runs only with the application's grants"
    end
    local extra = bounds.fields(declared, {"name", "revision", "title", "input", "output", "effect"})
    local effect = declared.effect == nil and "mutation" or bounds.member(declared.effect, {"read", "mutation"})
    local operation = name(declared.name)
    local revision = bounds.line(declared.revision, 32)
    local input, output = bounds.object(declared.input), bounds.object(declared.output)
    if extra or not effect or not operation or not revision or not input or not output
        or not schemas.valid_definition(input) or not schemas.valid_definition(output) then
        return nil, "Hive operation requires a name, revision and valid input/output schemas"
    end
    local application = bounds.id(meta.application_ref)
    if not application then return nil, "Hive application_ref must name the owning application" end
    return {ref = ref, application_ref = application, service = service, name = operation,
        revision = revision, mode = mode, effect = effect, input = input, output = output}, nil
end

function M.validate(entries: {Object}): string?
    local indexed: {[string]: Object} = {}
    for _, entry in ipairs(entries) do indexed[tostring(entry.id)] = entry end
    local names: {[string]: boolean} = {}
    for _, entry in ipairs(entries) do
        local operation, err = M.decode(entry)
        if err then return tostring(entry.id) .. ": " .. err end
        if operation then
            local app = indexed[operation.application_ref]
            local meta = app and bounds.object(app.meta) or nil
            if not app or app.kind ~= "process.lua" or not meta or meta.type ~= "bee.app" then
                return operation.ref .. ": Hive application_ref is not an application in this artifact"
            end
            local key = operation.application_ref .. "\n" .. operation.service .. "\n" .. operation.name
            if names[key] then return "duplicate Hive operation " .. operation.service .. "." .. operation.name end
            names[key] = true
        end
    end
    return nil
end

return M
