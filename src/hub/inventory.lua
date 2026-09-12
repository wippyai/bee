-- MIT. Installed module identities come from one registry-owned snapshot.
local registry = require("registry")
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

function M.read(): (Result?, string?)
    local snapshot, snapshot_error = registry.snapshot()
    if not snapshot then return nil, tostring(snapshot_error) end
    local state, state_error = snapshot:state()
    if not state then return nil, tostring(state_error) end
    return M.decode(state, snapshot:version():id())
end
return M
