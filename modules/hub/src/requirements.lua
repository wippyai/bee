-- MIT. Reads declared Hub requirement holes without resolving, linking, or
-- mutating them. The caller supplies already-decoded configuration values.
local bounds = require("bounds")
local canonical = require("canonical")
local M = {}
M.MAX_PACKAGE_ENTRIES = 512
M.MAX_REQUIREMENTS = 128
M.MAX_PARAMETERS = 128
M.MAX_TARGETS = 128
M.MAX_TARGET_PATH_BYTES = 512
M.MAX_PARAMETER_BYTES = bounds.MAX_RECORD_BYTES
type Parameter = {name: string, value: unknown}
type Target = {entry: string, path: string}
type Requirement = {
    id: string,
    default: unknown?,
    has_default: boolean,
    targets: {Target},
    selected: unknown?,
    has_selected: boolean,
}
type Result = {requirements: {Requirement}, missing: {string}}

local function dense(value: unknown, label: string, maximum: integer): ({unknown}?, string?)
    if type(value) ~= "table" then return nil, label .. " must be a list" end
    local count = 0
    local highest = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, label .. " must be a dense list" end
        count = count + 1
        if key > highest then highest = key end
    end
    if count ~= highest then return nil, label .. " must be a dense list" end
    if count > maximum then return nil, label .. " exceeds " .. tostring(maximum) .. " items" end
    local result: {unknown} = {}
    for index = 1, count do
        local item = value[index]
        if item == nil then return nil, label .. " must be a dense list" end
        result[index] = item
    end
    return result, nil
end

local function qualified_name(value: unknown, label: string): (string?, string?)
    local name = bounds.id(value)
    if not name or not name:match("^[^:%s]+:[^:%s]+$") then return nil, label .. " must be a qualified identifier" end
    return name, nil
end

-- A dependency parameter addresses requirements the way the native linker
-- does: a canonical ns:name selects that exact requirement, and a bare name
-- selects every requirement of that name the dependency owns.
local function parameter_name(value: unknown, label: string): (string?, string?)
    local name = bounds.id(value)
    if not name or not (name:match("^[^:%s]+$") or name:match("^[^:%s]+:[^:%s]+$")) then
        return nil, label .. " must be a requirement name or a qualified identifier"
    end
    return name, nil
end

local function target_path(value: unknown): (string?, string?)
    local path = bounds.line(value, M.MAX_TARGET_PATH_BYTES)
    -- Native linking owns the path language, including selectors and append.
    if not path then
        return nil, "path must be a bounded target path"
    end
    return path, nil
end

function M.parameters(value: unknown): ({Parameter}?, string?)
    local raw, raw_error = dense(value, "parameters", M.MAX_PARAMETERS)
    if not raw then return nil, raw_error end
    local result: {Parameter} = {}
    local names: {[string]: boolean} = {}
    for index, item in ipairs(raw) do
        local parameter = bounds.object(item)
        if not parameter then return nil, "parameters[" .. tostring(index) .. "] must be an object" end
        local unexpected = bounds.fields(parameter, {"name", "value"})
        if unexpected then return nil, "parameters[" .. tostring(index) .. "]: " .. unexpected end
        local name, name_error = parameter_name(parameter.name, "parameters[" .. tostring(index) .. "].name")
        if not name then return nil, name_error end
        local supplied = parameter.value
        if supplied == nil then return nil, "parameters[" .. tostring(index) .. "].value is required" end
        local encoded, encode_error = canonical.encode(supplied)
        if not encoded or #encoded > M.MAX_PARAMETER_BYTES then
            return nil, encode_error or "parameter value exceeds its bound"
        end
        if names[name] then return nil, "parameters name " .. name .. " twice" end
        names[name] = true
        result[index] = {name = name, value = supplied}
    end
    return result, nil
end

local function decode_targets(value: unknown, label: string): ({Target}?, string?)
    local raw, raw_error = dense(value, label, M.MAX_TARGETS)
    if not raw then return nil, raw_error end
    if #raw == 0 then return nil, label .. " must not be empty" end
    local targets: {Target} = {}
    for index, item in ipairs(raw) do
        local target = bounds.object(item)
        if not target then return nil, label .. "[" .. tostring(index) .. "] must be an object" end
        local unexpected = bounds.fields(target, {"entry", "path"})
        if unexpected then return nil, label .. "[" .. tostring(index) .. "]: " .. unexpected end
        local entry = bounds.id(target.entry)
        if not entry then return nil, label .. "[" .. tostring(index) .. "].entry is not an identifier" end
        local path, path_error = target_path(target.path)
        if not path then return nil, label .. "[" .. tostring(index) .. "]." .. tostring(path_error) end
        targets[index] = {entry = entry, path = path}
    end
    return targets, nil
end

function M.read(entries: unknown, parameters: {Parameter}): (Result?, string?)
    local raw_entries, entries_error = dense(entries, "package entries", M.MAX_PACKAGE_ENTRIES)
    if not raw_entries then return nil, entries_error end
    local requirements: {Requirement} = {}
    local by_id: {[string]: integer} = {}
    local by_name: {[string]: {integer}} = {}
    for index, item in ipairs(raw_entries) do
        local entry = bounds.object(item)
        if not entry then return nil, "package entry must be an object" end
        local entry_id = qualified_name(entry.id, "package entry id")
        if not entry_id or not bounds.id(entry.kind) then return nil, "invalid package entry identity" end
        if entry.kind == "ns.requirement" then
            local unexpected = bounds.fields(entry, {"id", "kind", "meta", "data"})
            if unexpected then return nil, "package entries[" .. tostring(index) .. "]: " .. unexpected end
            local id = bounds.id(entry.id)
            if not id then return nil, "package entries[" .. tostring(index) .. "].id is not an identifier" end
            if by_id[id] then return nil, "requirement id " .. id .. " twice" end
            local data = bounds.object(entry.data)
            if not data then return nil, "package entries[" .. tostring(index) .. "].data must be an object" end
            local data_unexpected = bounds.fields(data, {"default", "targets"})
            if data_unexpected then return nil, "package entries[" .. tostring(index) .. "].data: " .. data_unexpected end
            local targets, targets_error = decode_targets(data.targets, "package entries[" .. tostring(index) .. "].data.targets")
            if not targets then return nil, targets_error end
            if #requirements >= M.MAX_REQUIREMENTS then return nil, "package requirements exceeds " .. tostring(M.MAX_REQUIREMENTS) .. " items" end
            local has_default = data.default ~= nil
            if has_default then
                local encoded, encode_error = canonical.encode(data.default)
                if not encoded or #encoded > M.MAX_PARAMETER_BYTES then
                    return nil, encode_error or "requirement default exceeds its bound"
                end
            end
            requirements[#requirements + 1] = {id = id, default = data.default, has_default = has_default, targets = targets, has_selected = false}
            by_id[id] = #requirements
            local bare = id:match(":([^:]+)$")
            if bare then
                local owned = by_name[bare] or {}
                owned[#owned + 1] = #requirements
                by_name[bare] = owned
            end
        end
    end
    for _, parameter in ipairs(parameters) do
        local addressed = by_name[parameter.name]
        local exact = by_id[parameter.name]
        if exact then addressed = {exact} end
        if not addressed then return nil, "parameter names no requirement " .. parameter.name end
        for _, requirement_index in ipairs(addressed) do
            local requirement = requirements[requirement_index]
            requirement.selected = parameter.value
            requirement.has_selected = true
        end
    end
    local missing: {string} = {}
    for _, requirement in ipairs(requirements) do
        if not requirement.has_selected and not requirement.has_default then missing[#missing + 1] = requirement.id end
    end
    return {requirements = requirements, missing = missing}, nil
end
-- Project migration database references and top-level SQL configuration holes.
-- Native linking still owns general paths and is verified after publication.
type Entry = {id: string, kind: string, meta: {[string]: unknown}, data: unknown}
function M.migration_targets(raw: unknown, selected: Result): ({Entry}?, string?)
    local supplied, supplied_error = dense(raw, "migration package entries", M.MAX_PACKAGE_ENTRIES)
    if not supplied then return nil, supplied_error end
    local entries: {Entry} = {}
    for _, item in ipairs(supplied) do
        local entry = bounds.object(item)
        local id = entry and bounds.id(entry.id) or nil
        local kind = entry and bounds.id(entry.kind) or nil
        local meta = entry and bounds.object(entry.meta) or nil
        if not entry or not id or not kind or not meta then return nil, "invalid migration package entry" end
        entries[#entries + 1] = {id = id, kind = kind, meta = meta, data = entry.data}
    end
    local migrations: {[string]: boolean}, databases: {[string]: boolean} = {}, {}
    for _, entry in ipairs(entries) do
        if entry.meta.type == "migration" then migrations[entry.id] = true end
        if entry.kind == "db.sql.sqlite" or entry.kind == "db.sql.postgres" or entry.kind == "db.sql.mysql" then databases[entry.id] = true end
    end
    local targets: {[string]: string} = {}
    local configurations: {[string]: {[string]: unknown}} = {}
    for _, requirement in ipairs(selected.requirements) do
        if requirement.has_selected or requirement.has_default then
            local value = requirement.default
            if requirement.has_selected then value = requirement.selected end
            for _, target in ipairs(requirement.targets) do
                if migrations[target.entry] and (target.path == "meta.target_db" or target.path == ".meta.target_db") then
                    local database = bounds.id(value)
                    if not database then return nil, "migration database requirement must be an identifier: " .. requirement.id end
                    if targets[target.entry] and targets[target.entry] ~= database then
                        return nil, "conflicting migration database requirements for " .. target.entry
                    end
                    targets[target.entry] = database
                elseif databases[target.entry] then
                    -- SQL resource configuration uses top-level native fields,
                    -- such as .file or .dsn. Do not reproduce the general linker.
                    local field = target.path:match("^%.?([%w_]+)$")
                    if field and field ~= "meta" then
                        local configuration = configurations[target.entry] or {}
                        if configuration[field] ~= nil and canonical.encode(configuration[field]) ~= canonical.encode(value) then
                            return nil, "conflicting migration database configuration for " .. target.entry .. "." .. field
                        end
                        configuration[field] = value
                        configurations[target.entry] = configuration
                    end
                end
            end
        end
    end
    local result: {Entry} = {}
    for _, entry in ipairs(entries) do
        local database = targets[entry.id]
        if database then
            local meta: {[string]: unknown} = {}
            for key, value in pairs(entry.meta) do meta[key] = value end
            meta.target_db = database
            result[#result + 1] = {id = entry.id, kind = entry.kind, meta = meta, data = entry.data}
        else
            local configuration = configurations[entry.id]
            if configuration then
                local original = bounds.object(entry.data)
                if not original then return nil, "invalid SQL resource configuration: " .. entry.id end
                local data: {[string]: unknown} = {}
                for key, value in pairs(original) do data[key] = value end
                for key, value in pairs(configuration) do data[key] = value end
                result[#result + 1] = {id = entry.id, kind = entry.kind, meta = entry.meta, data = data}
            else result[#result + 1] = entry end
        end
    end
    return result, nil
end
return M
