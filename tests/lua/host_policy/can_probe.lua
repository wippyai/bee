-- MIT. Bounded policy test probe evaluating security.can under scoped policies.
local security = require("security")

local function text(value: unknown, limit: integer): string?
    if type(value) ~= "string" or #value > limit then return nil end
    return value
end

type Query = {
    action: string,
    resource: string,
}

local function decode_query(value: unknown): Query?
    if type(value) ~= "table" then return nil end
    local action = text(value.action, 128)
    local resource = text(value.resource, 128)
    if not action or not resource then return nil end
    return {action = action, resource = resource}
end

local function handle(request: unknown): boolean
    local query = decode_query(request)
    if not query then
        error("can_probe: invalid query format; expected {action = string, resource = string}")
    end
    return security.can(query.action, query.resource)
end

return {handle = handle}
