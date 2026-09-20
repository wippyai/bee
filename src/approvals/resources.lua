-- MIT. The linked references the approval owner resolves at runtime: its
-- SQL resource and the host's approver policies.
local registry = require("registry")
local M = {}
M.DATABASE_REF = "bee.approvals:database_ref"
M.POLICIES_REF = "bee.approvals:policies_ref"
M.THREAD_APPEND = "bee.threads.approvals:append"
type DefinitionSelector = {definition_id: string}
type Approver = string | DefinitionSelector
type Policy = {name: string, approvers: {Approver}, max_ttl_ms: integer}
local function reference(id: string, label: string): (string?, string?)
    local entry = registry.get(id)
    if not entry then return nil, label .. " reference is missing" end
    local data = entry.data :: {[string]: unknown}
    local target = data.resource_ref
    if type(target) ~= "string" or target == "" then return nil, label .. " reference is not linked" end
    return target, nil
end
function M.database(): (string?, string?)
    return reference(M.DATABASE_REF, "approval database")
end
-- The host's approver policies: each names the principals who may decide
-- under it and the longest lifetime a request under it may ask for.
function M.policies(): ({[string]: Policy}?, string?)
    local target, target_error = reference(M.POLICIES_REF, "approver policies")
    if not target then return nil, target_error end
    local entry = registry.get(target)
    if not entry then return nil, "approver policies entry is missing" end
    local data = entry.data :: {[string]: unknown}
    local listed = data.policies
    if type(listed) ~= "table" then return nil, "approver policies entry has no policies list" end
    local policies: {[string]: Policy} = {}
    for _, raw in ipairs(listed :: {unknown}) do
        if type(raw) ~= "table" then return nil, "approver policy is not an object" end
        local item = raw :: {[string]: unknown}
        local name, approvers, ttl = item.name, item.approvers, item.max_ttl_ms
        if type(name) ~= "string" or name == "" then return nil, "approver policy has no name" end
        if type(approvers) ~= "table" then return nil, "approver policy " .. name .. " has no approvers" end
        if type(ttl) ~= "number" or ttl < 1 then return nil, "approver policy " .. name .. " has no max_ttl_ms" end
        local subjects: {Approver} = {}
        for _, approver in ipairs(approvers :: {unknown}) do
            if type(approver) == "string" then
                if approver == "" or #approver > 200 or approver:find("%c") then
                    return nil, "approver policy " .. name .. " lists a non-identifier"
                end
                subjects[#subjects + 1] = approver
            elseif type(approver) == "table" then
                local definition = approver.definition_id
                for field in pairs(approver) do
                    if field ~= "definition_id" then
                        return nil, "approver policy " .. name .. " has an unknown approver selector field " .. tostring(field)
                    end
                end
                if type(definition) ~= "string" or definition == "" or #definition > 160 or definition:find("%c") then
                    return nil, "approver policy " .. name .. " has an invalid application definition selector"
                end
                subjects[#subjects + 1] = {definition_id = definition}
            else
                return nil, "approver policy " .. name .. " lists an invalid approver selector"
            end
        end
        policies[name] = {name = name, approvers = subjects, max_ttl_ms = math.floor(ttl)}
    end
    return policies, nil
end
return M
