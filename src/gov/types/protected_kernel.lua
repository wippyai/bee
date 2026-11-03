-- MIT. The protected kernel: the shipped definitions no overlay profile can
-- open. Each kernel component declares its namespace with a registry entry
-- of meta.type bee.kernel. A declaration covers the entries its own module
-- ships in that namespace and, with scope tree, in every descendant
-- namespace. Registry provenance names the module; overlay-authored entries
-- have none, so a declaration never covers them and an overlay cannot make
-- one. The host trust map bee.gov:protected_kernel holds the super-edit set:
-- exact entries the host has deliberately opened to a super-edit profile.
-- Preflight refuses a plan that edits a protected definition, one of its
-- transitive dependencies or a requirement selector aimed at them.
local M = {}
M.ID = "bee.gov:protected_kernel"
M.TYPE = "bee.protected_kernel"
M.DECLARATION = "bee.kernel"
local bounds = require("bounds")
type Object = {[string]: unknown}
type Manifest = {revision: integer, super_edit: {string}, entries: {string}}
type Declaration = {module: string, tree: boolean}

local MAX_NAMES = 16384
local MAX_STATE = 65536

local function object(raw: unknown): Object?
    return bounds.object(raw)
end

local function names(raw: unknown, maximum: integer): {string}?
    local supplied = bounds.dense_list(raw, maximum, "protected kernel names")
    if not supplied then return nil end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    if #supplied == 0 then return nil end
    for _, value in ipairs(supplied) do
        if type(value) ~= "string" or #value > 160 or not value:match("^[a-z][a-z0-9.]*:[A-Za-z0-9_.-]+$")
            or value:find("..", 1, true) or seen[value] then return nil end
        seen[value] = true
        result[#result + 1] = value
    end
    table.sort(result)
    return result
end

-- An optional list: absent or empty both decode as an empty set.
local function optional_names(raw: unknown, maximum: integer): ({string}?, string?)
    if raw == nil then return {}, nil end
    if type(raw) == "table" and next(raw) == nil then return {}, nil end
    local values = names(raw, maximum)
    if not values then return nil, "protected kernel manifest is malformed" end
    return values, nil
end

-- Decodes a manifest value, such as the one a preflight context carries. The
-- manifest protects the trust map itself, so no plan can rewrite it.
function M.decode(raw: unknown): (Manifest?, string?)
    local data = object(raw)
    if not data then return nil, "protected kernel manifest is unavailable" end
    if bounds.fields(data, {"revision", "super_edit", "entries"}) then
        return nil, "protected kernel manifest is malformed"
    end
    local revision = data.revision
    local super_edit, super_edit_error = optional_names(data.super_edit, MAX_NAMES)
    local entries = names(data.entries, MAX_NAMES)
    if not super_edit or not entries or type(revision) ~= "number" or revision < 1
        or revision ~= math.floor(revision) then
        return nil, super_edit_error or "protected kernel manifest is malformed"
    end
    local included = false
    for _, id in ipairs(entries) do if id == M.ID then included = true end end
    if not included then return nil, "protected kernel manifest does not protect itself" end
    return {revision = math.floor(revision), super_edit = super_edit,
        entries = entries}, nil
end

local function module_of(entry: Object): string?
    local provenance = object(entry.registry)
    local owner = provenance and provenance.owner
    if type(owner) ~= "string" or owner == "" or #owner > 160 then return nil end
    return owner
end

local function parent_of(namespace: string): string?
    return namespace:match("^(.+)%.[^.]+$")
end

-- Builds the manifest from registry state entries that carry provenance, as
-- a snapshot's state does. Returns the manifest and the ids of the trust map
-- and the declarations it is built from. A malformed trust map, or a
-- malformed or repeated declaration a module ships, refuses the manifest.
function M.build(raw: unknown): (Manifest?, {string}?, string?)
    local rows, rows_error = bounds.dense_list(raw, MAX_STATE, "registry state")
    if not rows then return nil, nil, rows_error or "registry state is unavailable" end
    local shipped: {[string]: string} = {}
    local trust_map: Object? = nil
    local declarations: {[string]: Declaration} = {}
    local sources: {string} = {}
    for _, row in ipairs(rows) do
        local entry = object(row)
        local id = entry and bounds.id(entry.id) or nil
        if not entry or not id then return nil, nil, "registry state contains an invalid entry" end
        if id == M.ID then trust_map = entry end
        local module = module_of(entry)
        local meta = object(entry.meta)
        if module then shipped[id] = module end
        if module and meta and meta.type == M.DECLARATION then
            local namespace = id:match("^([^:]+):")
            local data = object(entry.data)
            if entry.kind ~= "registry.entry" or not namespace or not data or bounds.fields(data, {"scope"})
                or (data.scope ~= "tree" and data.scope ~= "namespace") then
                return nil, nil, "protected kernel declaration is malformed: " .. id
            end
            if declarations[namespace] then
                return nil, nil, "protected kernel is declared twice in namespace " .. namespace
            end
            declarations[namespace] = {module = module, tree = data.scope == "tree"}
            sources[#sources + 1] = id
        end
    end
    local map_meta = trust_map and object(trust_map.meta) or nil
    local map_data = trust_map and object(trust_map.data) or nil
    if not trust_map or trust_map.kind ~= "registry.entry" or not map_meta or map_meta.type ~= M.TYPE
        or not map_data or bounds.fields(map_data, {"revision", "super_edit"}) then
        return nil, nil, "protected kernel trust map is unavailable or malformed"
    end
    sources[#sources + 1] = M.ID
    table.sort(sources)
    local function covered(id: string, module: string): boolean
        local namespace = id:match("^([^:]+):")
        if not namespace then return false end
        local own = declarations[namespace]
        if own and own.module == module then return true end
        local ancestor = parent_of(namespace)
        while ancestor do
            local declared = declarations[ancestor]
            if declared and declared.tree and declared.module == module then return true end
            ancestor = parent_of(ancestor)
        end
        return false
    end
    local protected: {string} = {}
    for id, module in pairs(shipped) do
        if covered(id, module) then protected[#protected + 1] = id end
    end
    local manifest, manifest_error = M.decode({revision = map_data.revision, super_edit = map_data.super_edit,
        entries = protected})
    if not manifest then return nil, nil, manifest_error end
    return manifest, sources, nil
end

-- Whether a kernel member's references are kernel dependencies. Code and its
-- wiring are; host records and selectors (registry entries, policies) name
-- applications as data, so they are protected by name without pulling the
-- applications they describe into the kernel.
function M.follows(kind: string): boolean
    return kind:match("%.lua$") ~= nil or kind == "process.service" or kind == "contract.binding"
        or kind == "contract.definition" or kind == "ns.dependency" or kind == "ns.requirement"
end

function M.opened(manifest: Manifest, id: string): boolean
    for _, open in ipairs(manifest.super_edit) do if id == open then return true end end
    return false
end

function M.names(manifest: Manifest, id: string): boolean
    for _, protected in ipairs(manifest.entries) do if id == protected then return true end end
    return false
end

local function namespace_of(id: string): string
    return (id:match("^([^:]+):") or "")
end

-- area is how the kernel holds one namespace: "protected" when it covers an
-- entry there, "opened" when the host trust map opens entries there to a
-- super-edit profile, otherwise nil.
function M.area(manifest: Manifest, namespace: string): string?
    for _, id in ipairs(manifest.entries) do if namespace_of(id) == namespace then return "protected" end end
    for _, id in ipairs(manifest.super_edit) do if namespace_of(id) == namespace then return "opened" end end
    return nil
end

-- opened_areas are the namespaces the host trust map opens to a super-edit
-- profile, in order.
function M.opened_areas(manifest: Manifest): {string}
    local seen: {[string]: boolean} = {}
    local result: {string} = {}
    for _, id in ipairs(manifest.super_edit) do
        local namespace = namespace_of(id)
        if not seen[namespace] then seen[namespace] = true; result[#result + 1] = namespace end
    end
    table.sort(result)
    return result
end

return M
