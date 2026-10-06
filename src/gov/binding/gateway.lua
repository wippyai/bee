-- MIT. The host gateway for contract calls and HTTP requests an application's
-- installed grants allow. It authenticates the calling application principal,
-- reads that application's own live grant record and performs only the exact
-- approved call. A contract callee runs under the original application actor
-- and none of the gateway's authority, so its owner checks see the real
-- caller.
local registry = require("registry")
local security = require("security")
local contract = require("contract")
local bounds = require("bounds")
local gateway = require("capability_gateway")
local access = require("capability_access")
local files = require("capability_files")
local capability_http = require("capability_http")

type Object = {[string]: unknown}
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown}

local function succeed(value: unknown): Reply
    return {ok = true, error = nil, value = value}
end

local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end

-- Calls one method of an approved contract binding for the calling
-- application: {binding, method, arguments?}.
local function contract_call(request_raw: unknown): Reply
    local request = bounds.object(request_raw)
    if not request or bounds.fields(request, {"binding", "method", "arguments"}) then
        return fail("INVALID", "contract call request is malformed")
    end
    local arguments = request.arguments or {}
    if type(arguments) ~= "table" or #(arguments) > 16 then
        return fail("INVALID", "contract call arguments are malformed")
    end
    local caller, record, live, refusal = access.granted()
    if refusal then return refusal end
    local allowed, denied = gateway.contract(record, caller, request.binding, request.method, live)
    if not allowed then return fail("DENIED", tostring(denied)) end
    local binding_id = bounds.id(request.binding)
    local method = request.method
    if not binding_id or type(method) ~= "string" then return fail("DENIED", "contract call is malformed") end
    local binding = registry.get(binding_id)
    local data = binding and bounds.object(binding.data) or nil
    local implemented = data and data.contracts or nil
    local contract_id: string? = nil
    if binding and binding.kind == "contract.binding" and type(implemented) == "table" then
        for _, raw in ipairs(implemented) do
            local item = bounds.object(raw)
            local methods = item and bounds.object(item.methods) or nil
            local implemented_contract = item and bounds.id(item.contract) or nil
            if methods and methods[method] ~= nil and implemented_contract then contract_id = implemented_contract end
        end
    end
    if not contract_id then return fail("NOT_FOUND", "binding " .. binding_id .. " implements no method " .. method) end
    local definition, get_error = contract.get(contract_id)
    if not definition then return fail("UNAVAILABLE", tostring(get_error)) end
    local actor = security.actor()
    local as_caller, actor_error = definition:with_actor(actor)
    if not as_caller then return fail("UNAVAILABLE", tostring(actor_error)) end
    local scope, scope_error = security.named_scope("bee.gov.security:gateway_callee_scope")
    if not scope then return fail("UNAVAILABLE", tostring(scope_error)) end
    local confined, confinement_error = as_caller:with_scope(scope)
    if not confined then return fail("UNAVAILABLE", tostring(confinement_error)) end
    local instance, open_error = confined:open(binding_id)
    if not instance then return fail("UNAVAILABLE", tostring(open_error)) end
    local call = (instance)[method]
    if type(call) ~= "function" then return fail("NOT_FOUND", "binding " .. binding_id .. " has no method " .. method) end
    local result, call_error = (call)(instance,
        table.unpack(arguments))
    if call_error ~= nil then return fail("FAILED", tostring(call_error)) end
    return succeed(result)
end

-- Performs one approved HTTP request for the calling application:
-- {method, url, headers?, body?, timeout?}.
local function http_request(request_raw: unknown): Reply
    return capability_http.perform(request_raw, function(): ({unknown}?, Reply?)
        local caller, record, live, refusal = access.granted()
        if refusal then return nil, refusal end
        local capabilities, denied = gateway.own(record, caller, live)
        if not capabilities then return nil, fail("DENIED", tostring(denied)) end
        return capabilities, nil
    end)
end

-- The registry identities of the calling application's own installed file
-- volumes and database, keyed by the approved subpath and database name, so
-- an application addresses its grants on any node without embedding
-- host-generated identities.
local function granted_resources(_request: unknown): Reply
    local _, record, live, refusal = access.granted()
    if refusal then return refusal end
    if not live or not record then return fail("DENIED", "the caller holds no live application grants") end
    local volumes: {[string]: string} = {}
    local databases: {[string]: string} = {}
    for _, raw_grant in ipairs((record.capabilities or {})) do
        local grant = bounds.object(raw_grant)
        local scope = grant and bounds.object(grant.scope) or nil
        if grant and scope and (grant.capability == "workspace.files.read" or grant.capability == "workspace.files.write") then
            local id, id_error = files.volume_id(record.overlay_owner, record.folder, scope.subpath)
            if not id then return fail("UNAVAILABLE", tostring(id_error)) end
            volumes[scope.subpath] = id
        elseif grant and scope and grant.capability == "app.database" then
            local id, id_error = files.database_id(record.overlay_owner, scope.name)
            if not id then return fail("UNAVAILABLE", tostring(id_error)) end
            databases[scope.name] = id
        end
    end
    return succeed({volumes = volumes, databases = databases})
end

return {contract_call = contract_call, http_request = http_request, granted_resources = granted_resources}
