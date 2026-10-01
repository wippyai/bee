-- MIT. Resolve the authenticated application's own live installed grants.
local registry = require("registry")
local security = require("security")
local bounds = require("bounds")
local gateway = require("capability_gateway")
local grants = require("capability_grants")
local capability_model = require("capability_model")
local workspace_applications = require("workspace_applications")
type Object = {[string]: unknown}
type Reply = {ok: boolean, error: {code: string, message: string}?, value: unknown}
local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end
local M = {}
-- The caller's authenticated identity and its own decoded, live grant record.
function M.granted(): (unknown?, Object?, boolean, Reply?)
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
    local grant_id = grants.record_id(owner)
    if not grant_id then return nil, nil, false, fail("DENIED", "the caller holds no installed application grants") end
    local raw = registry.get(grant_id)
    if not raw then
        local prior_owner = workspace_applications.prior_owner(caller.workspace_id, name)
        local prior_id = prior_owner and grants.prior_record_id(prior_owner) or nil
        raw = prior_id and registry.get(prior_id) or nil
        if raw then owner = prior_owner end
    end
    if not raw then return nil, nil, false, fail("DENIED", "the caller holds no installed application grants") end
    local raw_catalog = registry.get("bee:capability_catalog")
    local vocabulary, vocabulary_error = capability_model.decode(raw_catalog)
    if not vocabulary then return nil, nil, false, fail("UNAVAILABLE", tostring(vocabulary_error)) end
    local record, record_error = grants.decode(raw, owner, caller.workspace_id, caller.definition_id,
        vocabulary)
    if not record then return nil, nil, false, fail("DENIED", tostring(record_error)) end
    local live = grants.live(record, function(id: string): unknown return registry.get(id) end)
    return caller, record, live, nil
end

return M
