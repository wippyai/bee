-- MIT. Pure decoder for the host-owned protected kernel: the governance,
-- security, approvals, capability catalog and launch definitions no overlay
-- profile can open. Preflight refuses a plan that edits a named definition,
-- one of its transitive dependencies or a requirement selector aimed at them.
local M = {}
M.ID = "bee:protected_kernel"
M.TYPE = "bee.protected_kernel"
type Object = {[string]: unknown}
type Manifest = {revision: integer, namespaces: {string}, entries: {string}}

local function object(raw: unknown): Object?
    if type(raw) ~= "table" then return nil end
    for key in pairs(raw :: table) do if type(key) ~= "string" then return nil end end
    return raw :: Object
end

local function names(raw: unknown, pattern: string, maximum: integer): {string}?
    if type(raw) ~= "table" then return nil end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    local count = 0
    for key in pairs(raw :: table) do
        if type(key) ~= "number" then return nil end
        count = count + 1
    end
    if count == 0 or count > maximum then return nil end
    for index = 1, count do
        local value = (raw :: table)[index]
        if type(value) ~= "string" or #value > 160 or not value:match(pattern) or value:find("..", 1, true)
            or seen[value] then return nil end
        seen[value] = true
        result[index] = value
    end
    table.sort(result)
    return result
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
        if key ~= "revision" and key ~= "namespaces" and key ~= "entries" then
            return nil, "protected kernel manifest is malformed"
        end
    end
    local revision = data.revision
    local namespaces = names(data.namespaces, "^[a-z][a-z0-9_.]*[a-z0-9_]$", 64)
    local entries = names(data.entries, "^[a-z][a-z0-9_.]*:[A-Za-z0-9_.-]+$", 128)
    if not namespaces or not entries or type(revision) ~= "number" or revision < 1
        or revision ~= math.floor(revision) then
        return nil, "protected kernel manifest is malformed"
    end
    local included = false
    for _, id in ipairs(entries) do if id == M.ID then included = true end end
    if not included then return nil, "protected kernel manifest does not protect itself" end
    return {revision = math.floor(revision), namespaces = namespaces, entries = entries}, nil
end

-- Whether a kernel member's references are kernel dependencies. Code and its
-- wiring are; host records and selectors (registry entries, policies) name
-- applications as data, so they are protected by name without pulling the
-- applications they describe into the kernel.
function M.follows(kind: string): boolean
    return kind:match("%.lua$") ~= nil or kind == "process.service" or kind == "contract.binding"
        or kind == "contract.definition" or kind == "ns.dependency" or kind == "ns.requirement"
end

-- Whether a namespace is a protected namespace or a child of one.
function M.namespace(manifest: Manifest, namespace: string): boolean
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
