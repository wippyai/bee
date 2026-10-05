-- MIT. Pure decoder for the host-owned protected kernel: the host, governance,
-- security, approvals, capability catalog, launch and every other shipped
-- definition no overlay profile can open. Preflight refuses a plan that edits
-- a named definition, one of its transitive dependencies or a requirement
-- selector aimed at them. The one carve-out is the host's explicit super-edit
-- set: namespaces it has deliberately opened to a super-edit profile.
local M = {}
M.ID = "bee.gov:protected_kernel"
M.TYPE = "bee.protected_kernel"
local bounds = require("bounds")
type Object = {[string]: unknown}
type Manifest = {revision: integer, namespaces: {string}, super_edit: {string}, entries: {string}}

local function object(raw: unknown): Object?
    return bounds.object(raw)
end

local function names(raw: unknown, pattern: string, maximum: integer): {string}?
    local supplied = bounds.dense_list(raw, maximum, "protected kernel names")
    if not supplied then return nil end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    if #supplied == 0 then return nil end
    for _, value in ipairs(supplied) do
        if type(value) ~= "string" or #value > 160 or not value:match(pattern) or value:find("..", 1, true)
            or seen[value] then return nil end
        seen[value] = true
        result[#result + 1] = value
    end
    table.sort(result)
    return result
end

-- An optional list: absent or empty both decode as an empty set.
local function optional_names(raw: unknown, pattern: string, maximum: integer): ({string}?, string?)
    if raw == nil then return {}, nil end
    if type(raw) == "table" and next(raw) == nil then return {}, nil end
    local values = names(raw, pattern, maximum)
    if not values then return nil, "protected kernel manifest is malformed" end
    return values, nil
end

-- Decodes the registry entry or the manifest value carried in a preflight
-- context. The manifest names itself, so no plan can rewrite the map.
function M.decode(raw: unknown): (Manifest?, string?)
    local value = object(raw)
    if not value then return nil, "protected kernel manifest is unavailable" end
    local data = value
    if value.kind ~= nil then
        local meta = object(value.meta)
        if value.id ~= M.ID or value.kind ~= "registry.entry" or not meta or meta.type ~= M.TYPE then
            return nil, "protected kernel manifest is malformed"
        end
        data = object(value.data) or {}
    end
    for key in pairs(data) do
        if key ~= "revision" and key ~= "namespaces" and key ~= "super_edit" and key ~= "entries" then
            return nil, "protected kernel manifest is malformed"
        end
    end
    local revision = data.revision
    local namespaces = names(data.namespaces, "^[a-z][a-z0-9_.]*[a-z0-9_]$", 256)
    local super_edit, super_edit_error = optional_names(data.super_edit, "^[a-z][a-z0-9_.]*[a-z0-9_]$", 64)
    local entries = names(data.entries, "^[a-z][a-z0-9_.]*:[A-Za-z0-9_.-]+$", 128)
    if not namespaces or not super_edit or not entries or type(revision) ~= "number" or revision < 1
        or revision ~= math.floor(revision) then
        return nil, super_edit_error or "protected kernel manifest is malformed"
    end
    local included = false
    for _, id in ipairs(entries) do if id == M.ID then included = true end end
    if not included then return nil, "protected kernel manifest does not protect itself" end
    return {revision = math.floor(revision), namespaces = namespaces, super_edit = super_edit,
        entries = entries}, nil
end

-- Whether a kernel member's references are kernel dependencies. Code and its
-- wiring are; host records and selectors (registry entries, policies) name
-- applications as data, so they are protected by name without pulling the
-- applications they describe into the kernel.
function M.follows(kind: string): boolean
    return kind:match("%.lua$") ~= nil or kind == "process.service" or kind == "contract.binding"
        or kind == "contract.definition" or kind == "ns.dependency" or kind == "ns.requirement"
end

-- The host's explicit carve-out, independent of a caller's exact namespace grant.
function M.opened(manifest: Manifest, namespace: string): boolean
    for _, open in ipairs(manifest.super_edit) do
        if namespace == open or namespace:sub(1, #open + 1) == open .. "." then return true end
    end
    return false
end

-- Whether a namespace is protected by the manifest outside that carve-out.
function M.namespace(manifest: Manifest, namespace: string): boolean
    if M.opened(manifest, namespace) then return false end
    for _, protected in ipairs(manifest.namespaces) do
        if namespace == protected or namespace:sub(1, #protected + 1) == protected .. "." then return true end
    end
    return false
end

-- Whether the manifest names an entry directly or through its namespace.
function M.names(manifest: Manifest, id: string): boolean
    for _, protected in ipairs(manifest.entries) do if id == protected then return true end end
    local namespace = id:match("^([^:]+):")
    return namespace ~= nil and M.namespace(manifest, namespace)
end

return M
