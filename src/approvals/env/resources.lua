-- MIT. The linked references the approval owner resolves at runtime: its
-- SQL resource and the host's approver policies.
local registry = require("registry")
local bounds = require("bounds")
local M = {}
M.POLICIES_REF = "bee.approvals.env:policies_ref"
M.THREAD_APPEND = "bee.threads.binding:append"
type DefinitionSelector = {definition_id: string}
type Approver = string | DefinitionSelector
type Confirmation = "standard" | "explicit"
type Policy = {name: string, approvers: {Approver}, max_ttl_ms: integer, request_ttl_ms: integer?, confirm: Confirmation, allow_permanent: boolean}
M.MAX_POLICIES = 64
M.MAX_APPROVERS = 64
M.MAX_TTL_MS = 31536000000
local function reference(id: string, label: string): (string?, string?)
    local entry = registry.get(id)
    if not entry then return nil, label .. " reference is missing" end
    local data = bounds.object(entry.data)
    if not data or bounds.fields(data, {"resource_ref"}) then return nil, label .. " reference is malformed" end
    local target = bounds.id(data.resource_ref)
    if not target then return nil, label .. " reference is not linked" end
    return target, nil
end
local function list(value: unknown, maximum: integer, label: string): ({unknown}?, string?)
    local result, array_error = bounds.array(value, maximum)
    if not result then return nil, label .. " " .. tostring(array_error or "is not a list") end
    return result, nil
end
-- The host's approver policies: each names the principals who may decide
-- under it and the longest lifetime a request under it may ask for.
function M.policies(): ({[string]: Policy}?, string?)
    local target, target_error = reference(M.POLICIES_REF, "approver policies")
    if not target then return nil, target_error end
    local entry = registry.get(target)
    if not entry then return nil, "approver policies entry is missing" end
    local data = bounds.object(entry.data)
    if not data or bounds.fields(data, {"policies"}) then return nil, "approver policies entry is malformed" end
    local listed, list_error = list(data.policies, M.MAX_POLICIES, "approver policies")
    if not listed then return nil, list_error end
    local policies: {[string]: Policy} = {}
    for _, raw in ipairs(listed) do
        local item = bounds.object(raw)
        if not item then return nil, "approver policy is not an object" end
        local extra = bounds.fields(item, {"name", "approvers", "max_ttl_ms", "request_ttl_ms", "confirm", "allow_permanent"})
        if extra then return nil, "approver policy: " .. extra end
        local name = bounds.id(item.name)
        if not name then return nil, "approver policy has no valid name" end
        if policies[name] then return nil, "approver policy name is repeated: " .. name end
        local approvers, approver_error = list(item.approvers, M.MAX_APPROVERS, "approver policy " .. name .. " approvers")
        if not approvers then return nil, approver_error end
        if #approvers == 0 then return nil, "approver policy " .. name .. " has no approvers" end
        local ttl = bounds.integer(item.max_ttl_ms)
        if not ttl or ttl < 1 or ttl > M.MAX_TTL_MS then return nil, "approver policy " .. name .. " has invalid max_ttl_ms" end
        -- How long a request under the policy waits for its approvers when its
        -- requester names no lifetime: a person's decision waits for the person.
        local request_ttl: integer? = nil
        if item.request_ttl_ms ~= nil then
            request_ttl = bounds.integer(item.request_ttl_ms)
            if not request_ttl or request_ttl < 1 or request_ttl > M.MAX_TTL_MS then
                return nil, "approver policy " .. name .. " has invalid request_ttl_ms"
            end
        end
        -- A host may demand an explicit confirmation for a policy; the default
        -- is a standard decision. The owner records the value so a consumer
        -- such as the super-edit admission can require it.
        local confirm: Confirmation = "standard"
        if item.confirm ~= nil then
            if item.confirm == "standard" then confirm = "standard"
            elseif item.confirm == "explicit" then confirm = "explicit"
            else return nil, "approver policy " .. name .. " confirm must be standard or explicit" end
        end
        if item.allow_permanent ~= nil and type(item.allow_permanent) ~= "boolean" then return nil, "allow_permanent must be boolean" end
        local subjects: {Approver} = {}
        local seen: {[string]: boolean} = {}
        for _, approver in ipairs(approvers) do
            if type(approver) == "string" then
                local actor = bounds.id(approver)
                if not actor or seen[actor] then
                    return nil, "approver policy " .. name .. " lists a non-identifier"
                end
                seen[actor] = true
                subjects[#subjects + 1] = actor
            elseif type(approver) == "table" then
                local selector = bounds.object(approver)
                if not selector or bounds.fields(selector, {"definition_id"}) then
                    return nil, "approver policy " .. name .. " has an invalid selector object"
                end
                local definition = bounds.id(selector.definition_id)
                if not definition or seen["definition:" .. definition] then
                    return nil, "approver policy " .. name .. " has an invalid application definition selector"
                end
                seen["definition:" .. definition] = true
                subjects[#subjects + 1] = {definition_id = definition}
            else
                return nil, "approver policy " .. name .. " lists an invalid approver selector"
            end
        end
        policies[name] = {name = name, approvers = subjects, max_ttl_ms = ttl, request_ttl_ms = request_ttl, confirm = confirm, allow_permanent = item.allow_permanent == true}
    end
    return policies, nil
end
type Consumer = {destination: string, operation_ref: string, worker_name: string, effect_prefix: string?}
type Scope = {version: string, digest: string}
function M.consumers(): ({Consumer}?, string?)
    local found, err = registry.find({["meta.type"] = "bee.approvals.effect-consumer"})
    if not found or err then return nil, "discover approval effect consumers: " .. tostring(err) end
    local result: {Consumer} = {}
    local seen: {[string]: boolean} = {}
    for _, entry in ipairs(found) do
        local meta = bounds.object(entry.meta)
        local destination = meta and bounds.id(meta.destination) or nil
        local operation = meta and bounds.id(meta.operation_ref) or nil
        local worker = meta and bounds.id(meta.worker_name) or nil
        local prefix = meta and bounds.text(meta.effect_prefix, 128) or nil
        if not destination or not operation or not worker or seen[destination] then return nil, "invalid or duplicate approval effect consumer" end
        seen[destination] = true
        result[#result + 1] = {destination = destination, operation_ref = operation, worker_name = worker, effect_prefix = prefix}
    end
    return result, nil
end
function M.consumer(destination: string): (Consumer?, string?)
    local found, err = M.consumers()
    if not found then return nil, err end
    for _, entry in ipairs(found) do if entry.destination == destination then return entry, nil end end
    return nil, "approval effect destination is not registered"
end
function M.scope(scope_type: string): (Scope?, string?)
    local found, err = registry.find({["meta.type"] = "bee.approvals.scope", ["meta.scope_type"] = scope_type})
    if not found or err or #found ~= 1 then return nil, "approval scope type is not uniquely registered" end
    local meta = bounds.object(found[1].meta)
    local version = meta and bounds.id(meta.version) or nil
    local digest = meta and bounds.text(meta.digest, 64) or nil
    if not version or not digest or #digest ~= 64 then return nil, "approval scope adapter is invalid" end
    return {version = version, digest = digest}, nil
end
return M
