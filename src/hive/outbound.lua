-- MIT
local time = require("time")
local protocol = require("protocol")
local bounds = require("bounds")
local gateway = require("gateway")
local canonical = require("canonical")
local schemas = require("schemas")
local declarations = require("declarations")
local M = {}
M.MAX_BYTES = protocol.MAX_BYTES
type Object = {[string]: unknown}
type Request = {node: string, timeout: string, args: Object}
local function contains(raw: unknown, value: string): boolean
    local rows = bounds.ids(raw, true)
    for _, item in ipairs(rows or {}) do if item == value then return true end end
    return false
end
local function application_key(raw: unknown): string?
    if type(raw) == "string" then return bounds.id(raw) end
    local identity = bounds.object(raw)
    if identity and identity.alias ~= nil then
        local alias = bounds.line(identity.alias, 64)
        if alias and not bounds.fields(identity, {"alias"}) then return "alias/" .. alias end
        return nil
    end
    if not identity or bounds.fields(identity, {"source_node", "source_workspace", "component"}) then return nil end
    local node, workspace, component = bounds.id(identity.source_node), bounds.id(identity.source_workspace), bounds.id(identity.component)
    if not node or not workspace or not component or node:find("/", 1, true) or workspace:find("/", 1, true) then return nil end
    return node .. "/" .. workspace .. "/" .. component
end
function M.authorize(raw: unknown, record: unknown, caller: unknown, live: boolean): (Request?, string?)
    local capabilities, err = gateway.own(record, caller, live)
    if not capabilities then return nil, err end
    local asked = bounds.object(raw)
    if not asked or bounds.fields(asked, {"node", "workspace_id", "application", "service", "operation", "arguments", "timeout", "idempotency_key"}) then
        return nil, "Hive call request is malformed"
    end
    local node, workspace = bounds.id(asked.node), bounds.id(asked.workspace_id)
    local app = application_key(asked.application)
    local service, operation = bounds.line(asked.service, 64), bounds.line(asked.operation, 64)
    local arguments = bounds.object(asked.arguments)
    local timeout = asked.timeout == nil and "30s" or bounds.line(asked.timeout, 32)
    local duration = timeout and time.parse_duration(timeout) or nil
    if not node or (asked.workspace_id ~= nil and not workspace) or not app or not service or not operation or not arguments or not duration
        or duration:nanoseconds() <= 0 or duration:nanoseconds() > 30000000000 then return nil, "Hive call target or deadline is malformed" end
    local key = asked.idempotency_key == nil and nil or bounds.line(asked.idempotency_key, 128)
    if asked.idempotency_key ~= nil and not key then return nil, "idempotency key is malformed" end
    if not canonical.encode(asked, M.MAX_BYTES) then return nil, "Hive call exceeds its byte bound" end
    local selected: Request? = nil
    for _, raw_grant in ipairs(capabilities) do
        local grant = bounds.object(raw_grant)
        local scope = grant and bounds.object(grant.scope) or nil
        if grant and scope and grant.capability == "hive.call" and grant.operation == "hive.call"
            and grant.resource == "applications" and contains(scope.nodes, node)
            and contains(scope.applications, app) and contains(scope.services, service) and contains(scope.operations, operation) then
            local workspaces = bounds.ids(scope.workspaces, true)
            local destination = workspace or (workspaces and #workspaces == 1 and workspaces[1] or nil)
            if destination and contains(scope.workspaces, destination) then
                if selected and selected.args.workspace_id ~= destination then return nil, "Hive destination workspace is ambiguous; supply workspace_id" end
                selected = {node = node, timeout = tostring(timeout), args = {workspace_id = destination, application = asked.application,
                    service = service, operation = operation, arguments = arguments, idempotency_key = key}}
            end
        end
    end
    if selected then return selected, nil end
    return nil, "no live grant covers the Hive destination and operation"
end
function M.result(raw: unknown): (unknown?, string?)
    local reply = bounds.object(raw)
    if not reply or reply.ok ~= true then return nil, reply and bounds.text(reply.error, 4096) or "invalid Hive reply" end
    local value = bounds.object(reply.value)
    local output = value and bounds.object(value.output) or nil
    if not value or bounds.fields(value, {"result", "output", "revision"}) or not output
        or not bounds.line(value.revision, 32) or not declarations.valid_definition(output)
        or not canonical.encode(reply, M.MAX_BYTES) then return nil, "invalid Hive reply contract or size" end
    local err = schemas.validate(output, value.result)
    if err then return nil, "invalid Hive reply: " .. err end
    return value.result, nil
end
return M
