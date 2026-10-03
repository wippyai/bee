-- MIT. Host activation policy updates for person-confirmed, time-bounded overlays.
local M = {}
local hash = require("hash")
local protected_kernel = require("protected_kernel")

local MAX_NAMESPACES = 32
local MAX_PROFILES = 64
local MAX_INPUT_BYTES = 256
local MAX_DURATION_SECONDS = 24 * 60 * 60
local APPROVAL_POLICY = "super-edit-person"
local ALLOWED_KINDS = {"library.lua", "process.lua", "ns.requirement"}

type Object = {[string]: unknown}

local function namespace(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > 160 then return nil end
    for part in value:gmatch("[^.]+") do
        if not part:match("^[a-z][a-z0-9_]*$") then return nil end
    end
    if value:find("..", 1, true) or value:sub(1, 1) == "." or value:sub(-1) == "." then return nil end
    return value
end

local function intersects(left: string, right: string): boolean
    return left == right or left:sub(1, #right + 1) == right .. "."
        or right:sub(1, #left + 1) == left .. "."
end

local function list(value: unknown, label: string): ({unknown}?, string?)
    if type(value) ~= "table" then return nil, label .. " must be a list" end
    local source = value
    local count = 0
    for key in pairs(source) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return nil, label .. " must be a dense list"
        end
        count = count + 1
    end
    local result: {unknown} = {}
    for index = 1, count do
        if source[index] == nil then return nil, label .. " must be a dense list" end
        result[index] = source[index]
    end
    return result, nil
end

-- DURATION is a single positive amount with an explicit unit. The bounded
-- form avoids indefinite host openings and keeps the input easy to review.
function M.duration(raw: unknown): (string?, string?)
    if type(raw) ~= "string" or #raw > 16 then return nil, "duration must be a positive amount in s, m, h, or d" end
    local amount_text, unit = raw:match("^(%d+)([smhd])$")
    if not amount_text or not unit then return nil, "duration must be a positive amount in s, m, h, or d" end
    local amount: number = tonumber(amount_text) or 0
    if amount < 1 then return nil, "duration must be a positive amount in s, m, h, or d" end
    local seconds = amount * (unit == "s" and 1 or unit == "m" and 60 or unit == "h" and 3600 or 86400)
    if seconds > MAX_DURATION_SECONDS then return nil, "duration may not exceed 24h" end
    if unit == "d" then return tostring(amount * 24) .. "h", nil end
    return raw, nil
end

function M.parse_enable(raw: unknown): ({string}?, string?, string?)
    if type(raw) ~= "string" or #raw > MAX_INPUT_BYTES then return nil, nil, "namespace input exceeds its bound" end
    local fields: {string} = {}
    for item in raw:gmatch("%S+") do fields[#fields + 1] = item end
    if #fields < 3 or fields[#fields - 1] ~= "--for" then
        return nil, nil, "enter NAMESPACE... --for DURATION"
    end
    local duration, duration_error = M.duration(fields[#fields])
    if not duration then return nil, nil, duration_error end
    local namespaces: {string} = {}
    local seen: {[string]: boolean} = {}
    for index = 1, #fields - 2 do
        local item = namespace(fields[index])
        if not item or seen[item] then return nil, nil, "namespace list contains an invalid or duplicate value" end
        seen[item] = true
        namespaces[#namespaces + 1] = item
    end
    if #namespaces > MAX_NAMESPACES then return nil, nil, "namespace list exceeds its bound" end
    table.sort(namespaces)
    return namespaces, duration, nil
end

function M.is_kernel(namespace_raw: unknown, kernel_raw: unknown): boolean
    local requested = namespace(namespace_raw)
    local manifest = protected_kernel.decode(kernel_raw)
    if not requested or not manifest then return true end
    if protected_kernel.namespace(manifest, requested) then return true end
    for _, protected in ipairs(manifest.namespaces) do
        if protected:sub(1, #requested + 1) == requested .. "." then return true end
    end
    return false
end

local function workspace_id(value: unknown): string?
    if type(value) == "string" and #value == 32 and not value:find("[^0-9a-f]") then return value end
    return nil
end

function M.enable(configuration_raw: unknown, workspace_raw: unknown, node_raw: unknown,
    namespaces_raw: unknown, expires_raw: unknown, kernel_raw: unknown, owner_ids_raw: unknown?): (Object?, string?)
    local configuration = type(configuration_raw) == "table" and configuration_raw or nil
    local workspace, node = workspace_id(workspace_raw), type(node_raw) == "string" and node_raw or nil
    local expires = type(expires_raw) == "string" and expires_raw or nil
    local namespaces, namespaces_error = list(namespaces_raw, "namespace list")
    local rows, rows_error = list(configuration and configuration.profiles, "activation profiles")
    local owner_ids = type(owner_ids_raw) == "table" and owner_ids_raw or nil
    if not configuration or not workspace or not node or node == "" or not expires or not namespaces or not rows then
        return nil, namespaces_error or rows_error or "super-edit request is invalid"
    end
    if owner_ids_raw ~= nil and not owner_ids then return nil, "overlay owners are invalid" end
    if #namespaces == 0 or #namespaces > MAX_NAMESPACES then return nil, "namespace list is empty or exceeds its bound" end
    local checked: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, raw_namespace in ipairs(namespaces) do
        local item = namespace(raw_namespace)
        if not item or seen[item] then return nil, "namespace list contains an invalid or duplicate value" end
        if M.is_kernel(item, kernel_raw) then return nil, "kernel namespace is protected: " .. item end
        seen[item] = true
        checked[#checked + 1] = item
    end
    table.sort(checked)

    local result: {unknown} = {}
    local replacing: {[string]: boolean} = {}
    for _, item in ipairs(checked) do replacing[item] = true end
    for _, raw in ipairs(rows) do
        local row = type(raw) == "table" and raw or nil
        if not row then return nil, "activation profiles contain a malformed row" end
        local same = row.workspace_id == workspace and row.source_node == node
            and type(row.source_workspace) == "string" and replacing[row.source_workspace]
        if same then
            return nil, "an activation profile already owns namespace " .. tostring(row.source_workspace)
                .. "; disable edit mode before enabling it again"
        end
        if not same then result[#result + 1] = row end
    end
    for _, item in ipairs(checked) do
        local namespace_digest, namespace_error = hash.sha256(item)
        if not namespace_digest or namespace_error then return nil, "measure super-edit overlay owner" end
        local overlay_owner = owner_ids and owner_ids[item]
            or ("bee.super_edit:" .. workspace .. "." .. namespace_digest)
        if type(overlay_owner) ~= "string" or #overlay_owner > 160 or not overlay_owner:match("^[a-z][a-z0-9_.-]*:[A-Za-z0-9_.-]+$") then
            return nil, "super-edit overlay owner is invalid"
        end
        result[#result + 1] = {workspace_id = workspace, source_node = node, source_workspace = item,
            component = item, overlay_owner = overlay_owner,
            approval_policy = APPROVAL_POLICY, resolver = "overlay", parameters = {}, expires_at = expires,
            allow = {packages = {item}, namespaces = {item}, kinds = ALLOWED_KINDS,
                databases = {}, grants = {}, modules = {"tty"}, auto_start = false}}
    end
    if #result > MAX_PROFILES then return nil, "activation profile limit would be exceeded" end
    local output: Object = {}
    for key, value in pairs(configuration) do output[key] = value end
    output.profiles = result
    return output, nil
end

function M.disable(configuration_raw: unknown, workspace_raw: unknown): (Object?, string?)
    local configuration = type(configuration_raw) == "table" and configuration_raw or nil
    local workspace = workspace_id(workspace_raw)
    local rows, rows_error = list(configuration and configuration.profiles, "activation profiles")
    if not configuration or not workspace or not rows then return nil, rows_error or "super-edit request is invalid" end
    local result: {unknown} = {}
    for _, raw in ipairs(rows) do
        local row = type(raw) == "table" and raw or nil
        if not row then return nil, "activation profiles contain a malformed row" end
        if not (row.workspace_id == workspace and row.expires_at ~= nil) then result[#result + 1] = row end
    end
    local output: Object = {}
    for key, value in pairs(configuration) do output[key] = value end
    output.profiles = result
    return output, nil
end

-- Boot fallback removes every expiring activation row on this node. Readiness
-- can fail before local bootstrap learns which workspace failed, so this host
-- kill switch clears all super-edit owners and preserves ordinary profiles.
function M.disable_all(configuration_raw: unknown): (Object?, {string}?, string?)
    local configuration = type(configuration_raw) == "table" and configuration_raw or nil
    local rows, rows_error = list(configuration and configuration.profiles, "activation profiles")
    if not configuration or not rows then return nil, nil, rows_error or "super-edit request is invalid" end
    local result: {unknown} = {}
    local owners: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local row = type(raw) == "table" and raw or nil
        if not row then return nil, nil, "activation profiles contain a malformed row" end
        if row.expires_at ~= nil then
            local owner = row.overlay_owner
            if type(owner) ~= "string" or #owner > 160
                or not owner:match("^[a-z][a-z0-9_.-]*:[A-Za-z0-9_.-]+$") then
                return nil, nil, "super-edit profile has an invalid overlay owner"
            end
            if not seen[owner] then owners[#owners + 1] = owner; seen[owner] = true end
        else
            result[#result + 1] = row
        end
    end
    table.sort(owners)
    local output: Object = {}
    for key, value in pairs(configuration) do output[key] = value end
    output.profiles = result
    return output, owners, nil
end

return M
