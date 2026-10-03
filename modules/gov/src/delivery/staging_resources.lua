-- MIT. Only the host links the staging store. Never take a DB/path from agents.
local registry = require("registry")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local M = {}
M.DATABASE_REF = "bee.gov.env:database_ref"
M.PUBLICATION_PROFILES_REF = "bee.gov.env:publication_profiles_ref"
M.ACTIVATION_PROFILES_REF = "bee.gov.env:activation_profiles_ref"
M.APPROVAL_REQUEST_POLICY_REF = "bee.gov.env:approval_request_policy_ref"
M.APPROVAL_CONSUME_POLICY_REF = "bee.gov.env:approval_consume_policy_ref"
M.WORKSPACE_FOLDER_READ_REF = "bee.gov.env:workspace_folder_read_ref"
M.WORKSPACE_FOLDER_POLICY_REF = "bee.gov.env:workspace_folder_policy_ref"

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

-- Resolve the catalog folder under its host-selected read policy. The caller
-- uses this configuration to root approved volumes or bounded source reads.
function M.workspace_folder(workspace_id: string): (unknown?, string?)
    local read_id, read_error = M.workspace_folder_read()
    local policy_id, policy_error = M.workspace_folder_policy()
    if not read_id or not policy_id then return nil, read_error or policy_error end
    local policy, load_error = security.policy(policy_id)
    if not policy then return nil, tostring(load_error or "load workspace folder policy") end
    local executor = funcs.new():with_actor(security.new_actor("bee.gov.authoring")):with_scope(security.new_scope({policy}))
    local reply_raw, call_error = executor:call(read_id, {workspace_id = workspace_id})
    local reply = bounds.object(reply_raw)
    local value = reply and reply.ok == true and bounds.object(reply.value) or nil
    local row = value and bounds.object(value.workspace) or nil
    local root_ref = row and bounds.id(row.root_ref) or nil
    local subpath = row and row.subpath or nil
    if not root_ref or type(subpath) ~= "string" then
        local fault = reply and bounds.object(reply.error) or nil
        return nil, "workspace folder is unavailable: " .. tostring(call_error or (fault and fault.message)
            or "the workspace catalog returned no folder")
    end
    local root = registry.get(root_ref)
    local data = root and bounds.object(root.data) or nil
    if not root or root.kind ~= "fs.directory" or not data or type(data.directory) ~= "string" then
        return nil, "workspace root " .. root_ref .. " is not an fs.directory"
    end
    return {root_ref = root_ref, directory = data.directory, base = data.base, subpath = subpath}, nil
end
return M
