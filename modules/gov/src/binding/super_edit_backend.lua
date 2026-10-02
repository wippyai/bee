-- MIT. Apply the host's protected activation profile update.
local registry = require("registry")
local security = require("security")
local system = require("system")
local time = require("time")
local uuid = require("uuid")
local bounds = require("bounds")
local transaction = require("transaction")
local activation_profiles = require("activation_profiles")
local super_edit = require("super_edit")
local protected_kernel = require("protected_kernel")

local M = {}
local PROFILE_ID = "bee.env:gov_activation_profiles"
local KERNEL_ID = "bee.security.gov:protected_kernel"
local FORMAT = "2006-01-02T15:04:05.000Z07:00"
type Object = {[string]: unknown}

local function failure(code: string, message: string): {[string]: unknown}
    return transaction.failure(code, message)
end

local function entry(snapshot: registry.Snapshot, id: string, kind: string, meta_type: string): (Object?, string?)
    local raw, read_error = snapshot:get(id)
    local value = bounds.object(raw)
    local meta = value and bounds.object(value.meta) or nil
    if read_error or not value or value.kind ~= kind or not meta or meta.type ~= meta_type then
        return nil, "host entry " .. id .. " is unavailable or malformed"
    end
    return value, nil
end

local function overlay_clear(owner: string): (boolean, string?)
    local snapshot, snapshot_error = registry.overlay(owner)
    if not snapshot then return false, tostring(snapshot_error or "open governed overlay") end
    local entries, entries_error = snapshot:entries()
    if not entries then return false, tostring(entries_error or "read governed overlay") end
    if #entries == 0 then return true, nil end
    local changes = snapshot:changes()
    for _, raw in ipairs(entries) do
        local item = bounds.object(raw)
        if not item or not bounds.id(item.id) then return false, "governed overlay contains a malformed entry" end
        local _, delete_error = changes:delete(item.id)
        if delete_error then return false, tostring(delete_error) end
    end
    local _, apply_error = changes:apply()
    if apply_error then return false, tostring(apply_error) end
    return true, nil
end

local function owner_ids(namespaces: {string}, workspace_id: string): ({[string]: string}?, string?)
    local result: {[string]: string} = {}
    for _, namespace in ipairs(namespaces) do
        local token, token_error = uuid.v7()
        if not token or token_error then return nil, "allocate a super-edit overlay identity" end
        result[namespace] = "bee.super_edit:" .. workspace_id .. "." .. token
    end
    return result, nil
end

local function current_actor(operation: string): boolean
    local actor = security.actor()
    if operation == "disable_all" then
        return actor ~= nil and actor:id() == "bee.gov.recovery"
            and security.can("bee.gov.super_edit.recover", "host-activation-profiles")
    end
    return actor ~= nil and actor:id() == "bee.gov.super_edit"
        and security.can("bee.gov.super_edit.execute", "host-activation-profiles")
end

function M.handle(raw: unknown): {[string]: unknown}
    local request = bounds.object(raw)
    local operation = request and bounds.id(request.operation) or nil
    if not operation or not current_actor(operation) then return failure("DENIED", "super-edit profile writer is not authorized") end
    if operation == "disable_all" then
        if not request or bounds.fields(request, {"operation"}) then return failure("INVALID", "boot fallback request is invalid") end
    elseif operation ~= "enable" and operation ~= "disable" then
        return failure("INVALID", "super-edit profile request is invalid")
    end
    local workspace_id = request and bounds.text(request.workspace_id, 32) or nil
    if operation ~= "disable_all" and (not request or bounds.fields(request, {"operation", "workspace_id", "input"})
        or not workspace_id or #workspace_id ~= 32 or workspace_id:find("[^0-9a-f]")) then
        return failure("INVALID", "super-edit profile request is invalid")
    end
    local snapshot, snapshot_error = registry.snapshot()
    if not snapshot then return failure("UNAVAILABLE", tostring(snapshot_error or "read host registry")) end
    local profile_entry, profile_error = entry(snapshot, PROFILE_ID, "registry.entry", "bee.gov.activation_profiles")
    if not profile_entry then return failure("UNAVAILABLE", profile_error or "activation profile entry is unavailable") end
    local data = bounds.object(profile_entry.data)
    if not data then return failure("INVALID", "host activation profiles are malformed") end
    local updated: Object?
    local notice = ""
    if operation == "enable" then
        local namespaces, duration, parse_error = super_edit.parse_enable(request.input)
        if not namespaces or not duration then return failure("INVALID", parse_error or "edit mode request is invalid") end
        local node, node_error = system.node.id()
        if not node or node_error then return failure("UNAVAILABLE", "native node identity is unavailable") end
        local kernel_entry, kernel_error = entry(snapshot, KERNEL_ID, "registry.entry", "bee.protected_kernel")
        if not kernel_entry then return failure("UNAVAILABLE", kernel_error or "protected kernel entry is unavailable") end
        local manifest, manifest_error = protected_kernel.decode(kernel_entry)
        if not manifest then return failure("UNAVAILABLE", tostring(manifest_error or "protected kernel map is unavailable")) end
        local owners, owner_error = owner_ids(namespaces, assert(workspace_id))
        if not owners then return failure("UNAVAILABLE", owner_error or "allocate overlay identities") end
        local expires = time.now():add(duration):utc():format(FORMAT)
        updated, parse_error = super_edit.enable(data, workspace_id, node, namespaces, expires, manifest.namespaces, owners)
        if not updated then return failure("INVALID", parse_error or "super-edit profile is invalid") end
        local decoded, decode_error = activation_profiles.decode(updated)
        if not decoded then return failure("INVALID", tostring(decode_error or "activation profiles are invalid")) end
        notice = "Enabled until " .. expires .. " for " .. table.concat(namespaces, ", ")
    elseif operation == "disable" then
        local rows = type(data.profiles) == "table" and data.profiles or {}
        for _, raw_row in ipairs(rows) do
            local row = bounds.object(raw_row)
            if row and row.workspace_id == workspace_id and row.expires_at ~= nil then
                local owner = bounds.id(row.overlay_owner)
                if not owner then return failure("INVALID", "super-edit profile has an invalid overlay owner") end
                local cleared, clear_error = overlay_clear(owner)
                if not cleared then return failure("UNAVAILABLE", tostring(clear_error or "clear super-edit overlay")) end
            end
        end
        local disable_error: string?
        updated, disable_error = super_edit.disable(data, workspace_id)
        if not updated then return failure("INVALID", disable_error or "super-edit profile is invalid") end
        local decoded, decode_error = activation_profiles.decode(updated)
        if not decoded then return failure("INVALID", tostring(decode_error or "activation profiles are invalid")) end
        notice = "Disabled edit mode for this workspace"
    else
        local owners: {string}?
        local disable_error: string?
        updated, owners, disable_error = super_edit.disable_all(data)
        if not updated or not owners then return failure("INVALID", disable_error or "super-edit profiles are invalid") end
        if #owners == 0 then return transaction.success({changed = false, message = "No super-edit profiles are active"}, false) end
        for _, owner in ipairs(owners) do
            local cleared, clear_error = overlay_clear(owner)
            if not cleared then return failure("UNAVAILABLE", tostring(clear_error or "clear super-edit overlay")) end
        end
        local decoded, decode_error = activation_profiles.decode(updated)
        if not decoded then return failure("INVALID", tostring(decode_error or "activation profiles are invalid")) end
        notice = "Disabled all super-edit profiles for boot recovery"
    end
    profile_entry.data = updated
    local changes = snapshot:changes()
    local _, update_error = changes:update({id = PROFILE_ID, kind = "registry.entry", data = updated, meta = bounds.object(profile_entry.meta)})
    if update_error then return failure("CONFLICT", tostring(update_error)) end
    local _, apply_error = changes:apply()
    if apply_error then return failure("CONFLICT", tostring(apply_error)) end
    return transaction.success({changed = true, message = notice}, false)
end

return M
