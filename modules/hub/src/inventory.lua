-- MIT. Pure installed-module snapshot decoder shared by Hub planning and reads.
local bounds = require("bounds")
local requirements = require("requirements")
local M = {}
type Module = {component: string, version: string, source: string, direct: boolean,
    roots: {string}, used_by: {string}, entries: integer}
type Root = {id: string, component: string, version: string, parameters: {requirements.Parameter}}
type Result = {version: integer, modules: {Module}, roots: {Root}}

local function component(raw: unknown): string?
    local name = bounds.line(raw, 160)
    if not name then return nil end
    local org, module = name:match("^([%w_%-%.]+)/([%w_%-%.]+)$")
    if not org or not module or org == "." or org == ".." or module == "." or module == ".." then return nil end
    return name
end
local function rows(raw: unknown, maximum: integer): ({unknown}?, string?)
    if type(raw) ~= "table" then return nil, "expected a list" end
    local count = 0
    for key in pairs(raw) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, "expected a dense list" end
        count = count + 1
    end
    if count > maximum then return nil, "inventory exceeds its bound" end
    local result: {unknown} = {}
    for i = 1, count do
        if raw[i] == nil then return nil, "expected a dense list" end
        result[i] = raw[i]
    end
    return result, nil
end
local function optional_text(raw: unknown): string?
    if raw == nil or raw == "" then return "" end
    return bounds.line(raw, 160)
end
local function add_once(values: {string}, value: string)
    for _, current in ipairs(values) do if current == value then return end end
    values[#values + 1] = value
end

function M.decode(raw: unknown, revision: unknown): (Result?, string?)
    local state = bounds.object(raw)
    local version = bounds.integer(revision)
    if not state or not version or version < 0 then return nil, "invalid registry inventory snapshot" end
    local entries, entry_error = rows(state.entries, 16384)
    if not entries then return nil, entry_error end
    local by_name: {[string]: Module} = {}
    local function module(name: string): Module
        local found = by_name[name]
        if found then return found end
        local item: Module = {component = name, version = "", source = "", direct = false,
            roots = {}, used_by = {}, entries = 0}
        by_name[name] = item
        return item
    end
    if state.resolution ~= nil then
        local resolution = bounds.object(state.resolution)
        if not resolution then return nil, "invalid registry resolution" end
        local resolved, resolve_error = rows(resolution.modules, 512)
        if not resolved then return nil, resolve_error end
        for _, raw_item in ipairs(resolved) do
            local item = bounds.object(raw_item)
            if not item then return nil, "invalid resolved module" end
            local name = component(item.name)
            local selected = bounds.line(item.version, 128)
            local source = optional_text(item.source)
            if not name or not selected or not source or by_name[name] then return nil, "invalid or duplicate resolved module" end
            local bucket = module(name)
            bucket.version, bucket.source = selected, source
        end
    end
    local roots: {Root} = {}
    local seen: {[string]: boolean} = {}
    for _, raw_entry in ipairs(entries) do
        local entry = bounds.object(raw_entry)
        if not entry then return nil, "invalid registry entry" end
        local id, kind = bounds.id(entry.id), bounds.id(entry.kind)
        local owned = bounds.object(entry.registry)
        if not id or not kind or not owned or seen[id] then return nil, "missing registry ownership or duplicate entry" end
        seen[id] = true
        local owner = optional_text(owned.owner)
        if not owner or (owner ~= "" and not component(owner)) then return nil, "invalid registry owner" end
        if owned.root ~= nil and type(owned.root) ~= "boolean" then return nil, "invalid registry root marker" end
        if owner ~= "" then
            local bucket = module(owner)
            bucket.entries = bucket.entries + 1
        end
        if kind == "ns.dependency" then
            local data = bounds.object(entry.data)
            if not data then return nil, "invalid dependency declaration" end
            local target, constraint = component(data.component), bounds.line(data.version, 128)
            if not target or not constraint then return nil, "invalid dependency identity" end
            local bucket = module(target)
            if owner ~= "" then add_once(bucket.used_by, owner) end
            if owned.root == true then
                local supplied: unknown = data.parameters
                if supplied == nil then supplied = {} end
                local parameters, parameter_error = requirements.parameters(supplied)
                if not parameters then return nil, parameter_error end
                roots[#roots + 1] = {id = id, component = target, version = constraint, parameters = parameters}
                add_once(bucket.roots, id)
                bucket.direct = true
            end
        end
    end
    local modules: {Module} = {}
    for _, item in pairs(by_name) do
        if #modules >= 512 then return nil, "inventory exceeds module bound" end
        table.sort(item.roots)
        table.sort(item.used_by)
        modules[#modules + 1] = item
    end
    table.sort(modules, function(a: Module, b: Module): boolean return a.component < b.component end)
    table.sort(roots, function(a: Root, b: Root): boolean return a.id < b.id end)
    return {version = version, modules = modules, roots = roots}, nil
end

-- Hub owns only roots it published. Host-declared component roots remain
-- resident deployment configuration and must not become Hub plan inputs.
function M.dependency_members(state: Result): {[string]: boolean}
    local host_members: {[string]: boolean} = {}
    for _, root in ipairs(state.roots) do
        if root.id:sub(1, 13) ~= "bee.hub.deps:" then host_members[root.component] = true end
    end
    -- First retain the complete closure of host roots. A Hub root may share
    -- any member of that closure, but cannot replace or remove it.
    local changed = true
    while changed do
        changed = false
        for _, item in ipairs(state.modules) do
            if not host_members[item.component] then
                for _, owner in ipairs(item.used_by) do
                    if host_members[owner] then host_members[item.component] = true; changed = true; break end
                end
            end
        end
    end
    local members: {[string]: boolean} = {}
    for _, root in ipairs(state.roots) do
        if root.id:sub(1, 13) == "bee.hub.deps:" and not host_members[root.component] then members[root.component] = true end
    end
    changed = true
    while changed do
        changed = false
        for _, item in ipairs(state.modules) do
            if not members[item.component] and not host_members[item.component] then
                for _, owner in ipairs(item.used_by) do
                    if members[owner] then members[item.component] = true; changed = true; break end
                end
            end
        end
    end
    return members
end

-- Source inspection is deliberately narrower than a registry snapshot. A
-- component read grant reveals only Lua source owned by that exact installed
-- component; registry configuration, grants and other owners never enter the
-- result. Revision fences keep paged reads on one effective installation.
function M.sources(raw_state: unknown, raw_revision: unknown, raw_request: unknown): ({[string]: unknown}?, string?)
    local request = bounds.object(raw_request)
    if not request or bounds.fields(request, {"component", "version", "entry_id", "expected_revision", "offset", "limit"}) then
        return nil, "invalid installed source request"
    end
    local name, selected = component(request.component), bounds.line(request.version, 128)
    local revision = bounds.integer(raw_revision)
    if not name or not selected or not revision or revision < 0 then return nil, "invalid installed component identity" end
    local decoded, problem = M.decode(raw_state, revision)
    if not decoded then return nil, problem end
    local installed = false
    for _, item in ipairs(decoded.modules) do
        if item.component == name and item.version == selected then installed = true; break end
    end
    if not installed then return nil, "component version is not installed" end
    local wanted: string? = nil
    if request.entry_id ~= nil then
        wanted = bounds.id(request.entry_id)
        if not wanted or request.expected_revision ~= revision then return nil, "entry or registry revision changed" end
    elseif request.expected_revision ~= nil or request.offset ~= nil or request.limit ~= nil then
        return nil, "select an entry before paging source"
    end
    local offset: integer? = 0
    local limit: integer? = 16384
    if request.offset ~= nil then offset = bounds.count(request.offset) end
    if request.limit ~= nil then limit = bounds.count(request.limit) end
    if not offset or offset > 4194304 or not limit or limit < 1 or limit > 16384 then
        return nil, "installed source window is out of bounds"
    end
    local from: integer = offset
    local length: integer = limit
    local state = bounds.object(raw_state)
    if not state then return nil, "invalid registry state" end
    local raw_entries = state.entries
    if type(raw_entries) ~= "table" then return nil, "invalid registry entries" end
    local entries: {{id: string, kind: string, bytes: integer}} = {}
    for _, raw_entry in ipairs(raw_entries :: {unknown}) do
        local entry = bounds.object(raw_entry)
        local owned = entry and bounds.object(entry.registry)
        if owned and owned.owner == name and entry then
            local kind = bounds.member(entry.kind, {"library.lua", "function.lua", "process.lua"})
            local data = bounds.object(entry.data)
            local id = bounds.id(entry.id)
            if kind and data and id and type(data.source) == "string" then
                local source = data.source :: string
                if wanted == id then
                    return {component = name, version = selected, revision = revision, entry_id = id,
                        offset = from, content = source:sub(from + 1, from + length), bytes = #source,
                        eof = from + length >= #source}, nil
                end
                if #entries >= 256 then return nil, "installed source manifest exceeds its bound" end
                entries[#entries + 1] = {id = id, kind = kind, bytes = #source}
            end
        end
    end
    if wanted then return nil, "source entry is not owned by this installed component" end
    table.sort(entries, function(a, b): boolean return a.id < b.id end)
    return {component = name, version = selected, revision = revision, entries = entries}, nil
end
return M
