-- MIT. Only the host links the staging store. Never take a DB/path from agents.
local registry = require("registry")
local bounds = require("bounds")
local M = {}
M.DATABASE_REF = "bee.gov:database_ref"
M.PUBLICATION_PROFILES_REF = "bee.gov:publication_profiles_ref"
M.ACTIVATION_PROFILES_REF = "bee.gov:activation_profiles_ref"
M.APPROVAL_REQUEST_POLICY_REF = "bee.gov:approval_request_policy_ref"
M.APPROVAL_CONSUME_POLICY_REF = "bee.gov:approval_consume_policy_ref"
M.WORKSPACE_FOLDER_READ_REF = "bee.gov:workspace_folder_read_ref"
M.WORKSPACE_FOLDER_POLICY_REF = "bee.gov:workspace_folder_policy_ref"

function M.database(): (string?, string?)
    local entry = registry.get(M.DATABASE_REF)
    local value = entry and bounds.object(entry.data) or nil
    local resource = value and bounds.id(value.resource_ref) or nil
    if not resource then return nil, "governance workspace database is not linked" end
    return resource, nil
end

function M.publication_profiles(): (unknown?, string?)
    local reference = registry.get(M.PUBLICATION_PROFILES_REF)
    local data = reference and bounds.object(reference.data) or nil
    local target = data and bounds.id(data.resource_ref) or nil
    if not target then return nil, "publication profiles are not linked" end
    local entry, entry_error = registry.get(target)
    if not entry or entry.kind ~= "registry.entry" then
        return nil, tostring(entry_error or "publication profiles are unavailable")
    end
    return entry, nil
end

function M.activation_profiles(): (unknown?, string?)
    local reference = registry.get(M.ACTIVATION_PROFILES_REF)
    local data = reference and bounds.object(reference.data) or nil
    local target = data and bounds.id(data.resource_ref) or nil
    if not target then return nil, "activation profiles are not linked" end
    local entry, entry_error = registry.get(target)
    if not entry or entry.kind ~= "registry.entry" then
        return nil, tostring(entry_error or "activation profiles are unavailable")
    end
    return entry, nil
end

-- The linked registry entry behind a host reference, when it has one of the
-- expected kinds.
local function linked(ref: string, kinds: {[string]: boolean}, label: string): (string?, string?)
    local reference = registry.get(ref)
    local data = reference and bounds.object(reference.data) or nil
    local target = data and bounds.id(data.resource_ref) or nil
    if not target then return nil, label .. " is not linked" end
    local entry, entry_error = registry.get(target)
    if not entry or not kinds[entry.kind] then return nil, tostring(entry_error or (label .. " is unavailable")) end
    return target, nil
end

local POLICY_KINDS = {["security.policy"] = true, ["security.policy.expr"] = true}

function M.approval_request_policy(): (string?, string?)
    return linked(M.APPROVAL_REQUEST_POLICY_REF, POLICY_KINDS, "approval request policy")
end

function M.approval_consume_policy(): (string?, string?)
    return linked(M.APPROVAL_CONSUME_POLICY_REF, POLICY_KINDS, "approval consume policy")
end

function M.workspace_folder_read(): (string?, string?)
    return linked(M.WORKSPACE_FOLDER_READ_REF, {["function.lua"] = true}, "workspace folder read operation")
end

function M.workspace_folder_policy(): (string?, string?)
    return linked(M.WORKSPACE_FOLDER_POLICY_REF, POLICY_KINDS, "workspace folder read policy")
end
return M
