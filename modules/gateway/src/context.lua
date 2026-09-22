-- MIT. Pure, bounded MCP context values. Context is ordinary call data, not
-- an authorization mechanism; the host supplies fixed values separately.
local bounds = require("bounds")
local json = require("json")
local M = {}
M.MAX_BYTES = 16384
M.MAX_DEPTH = 4
M.MAX_KEYS = 32
M.BINDING_KEY = "bee.gateway.binding"
type Object = {[string]: unknown}
type Values = {[string]: unknown}
type Context = {[string]: unknown}
type CopyState = {keys: integer, active: {[table]: boolean}}
type OriginView = {view_id: string, instance_id: string}
type Runtime = {thread_id: string, subject: string, initiating_owner: string, binding_id: string,
    access_approval_id: string, access_proposal_digest: string, surface_revision: integer, surface_digest: string}
type Attribution = {binding_id: string, thread_id: string, subject: string, action_id: string, attempt_id: string,
    policy_ref: string?, workspace_id: string?, origin_view: OriginView?, application_runtime: Runtime?}

local function digest(value: unknown): string?
    local text = bounds.text(value, 64)
    if not text or #text ~= 64 or not text:match("^[0-9a-f]+$") then return nil end
    return text
end

local function copy_value(value: unknown, parent_depth: integer, state: CopyState): (unknown, string?)
    if value == nil or type(value) == "boolean" or type(value) == "string" then return value, nil end
    if type(value) == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return nil, "context numbers must be finite" end
        return value, nil
    end
    if type(value) ~= "table" then return nil, "context values must be JSON values" end

    local depth = parent_depth + 1
    if depth > M.MAX_DEPTH then return nil, "context nests deeper than " .. tostring(M.MAX_DEPTH) end
    local source = value :: table
    if state.active[source] then return nil, "context must not contain a cycle" end
    state.active[source] = true

    local count = 0
    local string_keys: {string} = {}
    local numeric_keys: {integer} = {}
    for key in pairs(source) do
        count = count + 1
        state.keys = state.keys + 1
        if state.keys > M.MAX_KEYS then
            state.active[source] = nil
            return nil, "context has more than " .. tostring(M.MAX_KEYS) .. " keys"
        end
        if type(key) == "string" then
            string_keys[#string_keys + 1] = key
        elseif type(key) == "number" and key == math.floor(key) and key >= 1 and key <= M.MAX_KEYS then
            numeric_keys[#numeric_keys + 1] = math.floor(key)
        else
            state.active[source] = nil
            return nil, "context table keys must be strings or dense array indexes"
        end
    end

    if #string_keys > 0 and #numeric_keys > 0 then
        state.active[source] = nil
        return nil, "context table must not mix object and array keys"
    end
    local result: table = {}
    if #numeric_keys > 0 then
        if #numeric_keys ~= count then
            state.active[source] = nil
            return nil, "context array indexes must be dense"
        end
        for index = 1, count do
            if source[index] == nil then
                state.active[source] = nil
                return nil, "context array indexes must be dense"
            end
            local copied, copy_error = copy_value(source[index], depth, state)
            if copy_error then
                state.active[source] = nil
                return nil, copy_error
            end
            result[index] = copied
        end
    else
        for _, key in ipairs(string_keys) do
            local copied, copy_error = copy_value(source[key], depth, state)
            if copy_error then
                state.active[source] = nil
                return nil, copy_error
            end
            result[key] = copied
        end
    end
    state.active[source] = nil
    return result, nil
end

local function checked_object(value: unknown): (Object?, string?)
    if value == nil then return {}, nil end
    local object = bounds.object(value)
    if not object then return nil, "context must be an object" end
    for key in pairs(object) do
        if key == "" then return nil, "context keys must not be empty" end
        if key == M.BINDING_KEY then return nil, "context key is reserved for gateway attribution" end
    end
    return object, nil
end

local function checked_values(value: unknown): (Values?, string?)
    local object, object_error = checked_object(value)
    if not object then return nil, object_error end
    local state: CopyState = {keys = 0, active = {}}
    local copied, copy_error = copy_value(object, 0, state)
    if copy_error or type(copied) ~= "table" then return nil, copy_error or "context must be an object" end
    local encoded, encode_error = json.encode(copied)
    if not encoded then return nil, "context JSON encoding failed: " .. tostring(encode_error) end
    if #encoded > M.MAX_BYTES then return nil, "context exceeds " .. tostring(M.MAX_BYTES) .. " encoded bytes" end
    return copied :: Values, nil
end

-- Decode an untrusted dynamic context map to a bounded, independently owned
-- value. A missing map is an empty context.
function M.decode(value: unknown): (Values?, string?)
    return checked_values(value)
end

-- Merge caller metadata into host-selected context. Dynamic names must be
-- explicitly admitted, and a caller cannot replace any host-owned value.
-- Both inputs are copied and the final encoded size is checked after merging.
function M.compose(fixed_value: unknown, dynamic_value: unknown, allowed_dynamic: {string}): (Context?, string?)
    local fixed, fixed_error = checked_values(fixed_value)
    if not fixed then return nil, "host context: " .. tostring(fixed_error) end
    local dynamic, dynamic_error = checked_values(dynamic_value)
    if not dynamic then return nil, dynamic_error end

    if #allowed_dynamic > M.MAX_KEYS then return nil, "allowed dynamic context keys exceed " .. tostring(M.MAX_KEYS) end
    local allowed: {[string]: boolean} = {}
    for _, key in ipairs(allowed_dynamic) do
        if key == "" or allowed[key] then return nil, "allowed dynamic context keys must be unique and nonempty" end
        if key == M.BINDING_KEY then return nil, "context key is reserved for gateway attribution" end
        allowed[key] = true
    end

    for key in pairs(dynamic) do
        if fixed[key] ~= nil then return nil, "dynamic context cannot overwrite host context key " .. key end
        if not allowed[key] then return nil, "unknown dynamic context key " .. key end
    end

    local combined: Object = {}
    for key, value in pairs(fixed) do combined[key] = value end
    for key, value in pairs(dynamic) do combined[key] = value end
    local checked, combined_error = checked_values(combined)
    if not checked then return nil, combined_error end
    return checked :: Context, nil
end

-- The endpoint supplies these identities from its authenticated binding, never
-- from tool arguments. This fixed-size record is outside the configurable
-- context quota. It identifies the call; actor and scope still authorize it.
function M.bind(values: unknown, identity: Attribution): (Context?, string?)
    local copied, copy_error = checked_values(values)
    if not copied then return nil, copy_error end
    local binding_id = bounds.id(identity.binding_id)
    local thread_id = bounds.id(identity.thread_id)
    local subject = bounds.id(identity.subject)
    local action_id = bounds.id(identity.action_id)
    local attempt_id = bounds.id(identity.attempt_id)
    if not binding_id or not thread_id or not subject or not action_id or not attempt_id then
        return nil, "invalid gateway binding attribution"
    end
    local policy_ref: string? = nil
    if identity.policy_ref ~= nil then
        policy_ref = bounds.id(identity.policy_ref)
        if not policy_ref then return nil, "invalid gateway binding attribution" end
    end
    local workspace_id: string? = nil
    if identity.workspace_id ~= nil then
        workspace_id = bounds.id(identity.workspace_id)
        if not workspace_id then return nil, "invalid gateway binding attribution" end
    end
    local origin_view: OriginView? = nil
    if identity.origin_view ~= nil then
        local source = bounds.object(identity.origin_view)
        if not source then return nil, "invalid gateway binding attribution" end
        if bounds.fields(source, {"view_id", "instance_id"}) then return nil, "invalid gateway binding attribution" end
        local view_id, instance_id = bounds.id(source.view_id), bounds.id(source.instance_id)
        if not view_id or not instance_id then return nil, "invalid gateway binding attribution" end
        origin_view = {view_id = view_id, instance_id = instance_id}
    end
    local runtime: Runtime? = nil
    if identity.application_runtime ~= nil then
        local value = identity.application_runtime
        local approval_id = bounds.id(value.access_approval_id)
        local revision = bounds.count(value.surface_revision)
        local proposal_digest, surface_digest = digest(value.access_proposal_digest), digest(value.surface_digest)
        if value.thread_id ~= thread_id or value.subject ~= subject or value.initiating_owner ~= subject or value.binding_id ~= binding_id
            or not approval_id or not revision or revision < 1 or not proposal_digest or not surface_digest then
            return nil, "invalid application runtime attribution"
        end
        runtime = {thread_id = thread_id, subject = subject, initiating_owner = subject, binding_id = binding_id,
            access_approval_id = approval_id, access_proposal_digest = proposal_digest,
            surface_revision = revision, surface_digest = surface_digest}
    end
    copied[M.BINDING_KEY] = {binding_id = binding_id, thread_id = thread_id, subject = subject,
        action_id = action_id, attempt_id = attempt_id, policy_ref = policy_ref, workspace_id = workspace_id,
        origin_view = origin_view, application_runtime = runtime}
    return copied, nil
end

return M
