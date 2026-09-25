-- MIT. The host gateway for contract calls and HTTP requests an application's
-- installed grants allow. It authenticates the calling application principal,
-- reads that application's own live grant record and performs only the exact
-- approved call. A contract callee runs under the original application actor
-- and none of the gateway's authority, so its owner checks see the real
-- caller.
local registry = require("registry")
local security = require("security")
local contract = require("contract")
local http_client = require("http_client")
local bounds = require("bounds")
local gateway = require("capability_gateway")
local grants = require("capability_grants")
local catalog = require("capability_catalog")
local workspace_applications = require("workspace_applications")

type Object = {[string]: unknown}
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown}

local function succeed(value: unknown): Reply
    return {ok = true, error = nil, value = value}
end

local MAX_BODY = 1048576
local MAX_RESPONSE = 4194304

local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end

-- The caller's authenticated identity and its own decoded, live grant record.
local function granted(): (unknown?, Object?, boolean, Reply?)
    local actor = security.actor()
    if not actor then return nil, nil, false, fail("UNAUTHENTICATED", "the caller is not authenticated") end
    local caller, caller_error = gateway.caller(actor:id(), actor:meta())
    if not caller then return nil, nil, false, fail("DENIED", tostring(caller_error)) end
    local component = caller.definition_id:match("^([^:]+):")
    local name = workspace_applications.source_of(component)
    local identity = name and workspace_applications.identity(caller.workspace_id, name) or nil
    if not identity or identity.definition_id ~= caller.definition_id then
        return nil, nil, false, fail("DENIED", "the caller holds no installed application grants")
    end
    local owner = identity.overlay_owner
    local raw = registry.get(grants.record_id(owner) :: string)
    if not raw then
        local prior_owner = workspace_applications.prior_owner(caller.workspace_id, name)
        local prior_id = prior_owner and grants.prior_record_id(prior_owner) or nil
        raw = prior_id and registry.get(prior_id) or nil
        if raw then owner = prior_owner :: string end
    end
    if not raw then return nil, nil, false, fail("DENIED", "the caller holds no installed application grants") end
    local vocabulary, vocabulary_error = catalog.decode(registry.get("bee:capability_catalog"))
    if not vocabulary then return nil, nil, false, fail("UNAVAILABLE", tostring(vocabulary_error)) end
    local record, record_error = grants.decode(raw, owner, caller.workspace_id, caller.definition_id, vocabulary)
    if not record then return nil, nil, false, fail("DENIED", tostring(record_error)) end
    local live = grants.live(record, function(id: string): unknown return registry.get(id) end)
    return caller, record, live, nil
end

-- Calls one method of an approved contract binding for the calling
-- application: {binding, method, arguments?}.
local function contract_call(request_raw: unknown): Reply
    local request = bounds.object(request_raw)
    if not request or bounds.fields(request, {"binding", "method", "arguments"}) then
        return fail("INVALID", "contract call request is malformed")
    end
    local arguments = request.arguments or {}
    if type(arguments) ~= "table" or #(arguments :: {unknown}) > 16 then
        return fail("INVALID", "contract call arguments are malformed")
    end
    local caller, record, live, refusal = granted()
    if refusal then return refusal end
    local allowed, denied = gateway.contract(record, caller, request.binding, request.method, live)
    if not allowed then return fail("DENIED", tostring(denied)) end
    local binding_id = request.binding :: string
    local method = request.method :: string
    local binding = registry.get(binding_id)
    local data = binding and bounds.object(binding.data) or nil
    local implemented = data and data.contracts or nil
    local contract_id: string? = nil
    if binding and binding.kind == "contract.binding" and type(implemented) == "table" then
        for _, raw in ipairs(implemented :: {unknown}) do
            local item = bounds.object(raw)
            local methods = item and bounds.object(item.methods) or nil
            if methods and methods[method] ~= nil and bounds.id(item.contract) then contract_id = item.contract :: string end
        end
    end
    if not contract_id then return fail("NOT_FOUND", "binding " .. binding_id .. " implements no method " .. method) end
    local definition, get_error = contract.get(contract_id)
    if not definition then return fail("UNAVAILABLE", tostring(get_error)) end
    local actor = security.actor()
    local as_caller, actor_error = definition:with_actor(actor)
    if not as_caller then return fail("UNAVAILABLE", tostring(actor_error)) end
    local confined, scope_error = as_caller:with_scope(security.new_scope({}))
    if not confined then return fail("UNAVAILABLE", tostring(scope_error)) end
    local instance, open_error = confined:open(binding_id)
    if not instance then return fail("UNAVAILABLE", tostring(open_error)) end
    local call = (instance :: {[string]: unknown})[method]
    if type(call) ~= "function" then return fail("NOT_FOUND", "binding " .. binding_id .. " has no method " .. method) end
    local result, call_error = (call :: (unknown, ...unknown) -> (unknown, unknown))(instance,
        table.unpack(arguments :: {unknown}))
    if call_error ~= nil then return fail("FAILED", tostring(call_error)) end
    return succeed(result)
end

-- Performs one approved HTTP request for the calling application:
-- {method, url, headers?, body?, timeout?}.
local function http_request(request_raw: unknown): Reply
    local request = bounds.object(request_raw)
    if not request or bounds.fields(request, {"method", "url", "headers", "body", "timeout"}) then
        return fail("INVALID", "HTTP request is malformed")
    end
    local headers: {[string]: string} = {}
    if request.headers ~= nil then
        local supplied = bounds.object(request.headers)
        if not supplied then return fail("INVALID", "HTTP headers are malformed") end
        for key, value in pairs(supplied) do
            if type(value) ~= "string" or #key > 128 or #value > 8192
                or key:find("[%c:]") or value:find("[\r\n]") then
                return fail("INVALID", "HTTP headers are malformed")
            end
            headers[key] = value
        end
    end
    local body: string? = nil
    if request.body ~= nil then
        if type(request.body) ~= "string" or #request.body > MAX_BODY then
            return fail("INVALID", "HTTP body is malformed")
        end
        body = request.body
    end
    local timeout = request.timeout
    if timeout == nil then timeout = 30 end
    if type(timeout) ~= "number" or timeout <= 0 or timeout > 60 then
        return fail("INVALID", "HTTP timeout is malformed")
    end
    local caller, record, live, refusal = granted()
    if refusal then return refusal end
    local allowed, denied = gateway.http(record, caller, request.method, request.url, live)
    if not allowed then return fail("DENIED", tostring(denied)) end
    local response, request_error = http_client.request((request.method :: string):upper(), request.url :: string,
        {headers = headers, body = body, timeout = timeout, max_response_body = MAX_RESPONSE})
    if not response then return fail("FAILED", tostring(request_error)) end
    local arrived = response.url or request.url
    local located, location_error = gateway.located(record, arrived)
    if not located then return fail("DENIED", tostring(location_error)) end
    return succeed({status_code = response.status_code, headers = response.headers, body = response.body})
end

return {contract_call = contract_call, http_request = http_request}
