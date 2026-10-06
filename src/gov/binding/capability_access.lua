-- MIT. Resolve an application's own live installed grants.
local registry = require("registry")
local security = require("security")
local gateway = require("capability_gateway")
local grants = require("capability_grants")
local capability_model = require("capability_model")
local bounds = require("bounds")
type Object = {[string]: unknown}
type Reply = {ok: boolean, error: {code: string, message: string}?, value: unknown}
local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end
local M = {}
-- The decoded, live grant record of definition_id in workspace_id, or nil
-- when it holds none.
function M.record(workspace_id: string, definition_id: string): (grants.Installed?, Reply?)
    local raw_catalog = registry.get("bee.capability:catalog")
    local vocabulary, vocabulary_error = capability_model.decode(raw_catalog)
    if not vocabulary then return nil, fail("UNAVAILABLE", tostring(vocabulary_error)) end
    local entries, find_error = registry.find({[".kind"] = "registry.entry", ["meta.type"] = grants.SCHEMA})
    if find_error then return nil, fail("UNAVAILABLE", tostring(find_error)) end
    local selected: grants.Installed? = nil
    for _, entry in ipairs(entries) do
        local data = bounds.object(entry.data)
        local owner = data and bounds.id(data.overlay_owner) or nil
        if owner and data and data.workspace_id == workspace_id and data.application == definition_id then
            local record, record_error = grants.decode(entry, owner, workspace_id, definition_id, vocabulary)
            if not record then return nil, fail("DENIED", tostring(record_error)) end
            local live = grants.live(record, function(id: string): unknown return registry.get(id) end)
            if live then
                if selected then return nil, fail("DENIED", "multiple live grants claim the exact application") end
                selected = record
            end
        end
    end
    return selected, nil
end
-- The caller's authenticated identity and its own decoded, live grant record.
function M.granted(): (unknown?, Object?, boolean, Reply?)
    local actor = security.actor()
    if not actor then return nil, nil, false, fail("UNAUTHENTICATED", "the caller is not authenticated") end
    local caller, caller_error = gateway.caller(actor:id(), actor:meta())
    if not caller then return nil, nil, false, fail("DENIED", tostring(caller_error)) end
    local selected, refusal = M.record(caller.workspace_id, caller.definition_id)
    if refusal then return nil, nil, false, refusal end
    if not selected then return nil, nil, false, fail("DENIED", "the caller holds no live installed application grants") end
    return caller, selected, true, nil
end

return M
