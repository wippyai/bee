-- MIT. Reads declared Hub requirement holes without resolving, linking, or
-- mutating them. The caller supplies already-decoded configuration values.
local bounds = require("bounds")
local canonical = require("canonical")
local json = require("json")
local json_schema = require("json_schema")
local limits = require("limits")
local M = {}
M.MAX_PACKAGE_ENTRIES = limits.MAX_PACKAGE_ENTRIES
M.MAX_REQUIREMENTS = 128
M.MAX_PARAMETERS = 128
M.MAX_TARGETS = 128
M.MAX_TARGET_PATH_BYTES = 512
M.MAX_PARAMETER_BYTES = 16384
type Parameter = {name: string, value: unknown}
type Target = {entry: string, path: string}
type Requirement = {
    id: string,
    default: unknown?,
    has_default: boolean,
    capability: string?,
    targets: {Target},
    selected: unknown?,
    has_selected: boolean,
    schema: {[string]: unknown}?,
    description: string?,
    schema_default: boolean?,
}
type Result = {requirements: {Requirement}, missing: {string}}

function M.defaults(schema: {[string]: unknown}, value: unknown): unknown
    if value == nil then value = schema.default end
    local properties = bounds.object(schema.properties)
    if properties and (value == nil or bounds.object(value)) then
        local result: {[string]: unknown} = {}
        for name, item in pairs(bounds.object(value) or {}) do result[name] = item end
        for name, raw in pairs(properties) do
            local child = bounds.object(raw)
            if child then result[name] = M.defaults(child, result[name]) end
        end
        if next(result) ~= nil or value ~= nil then return result end
    end
    local items = bounds.object(schema.items)
    if items and type(value) == "table" then
        local result: {unknown} = {}
        for index, item in ipairs(value) do result[index] = M.defaults(items, item) end
        return result
    end
    return value
end

function M.validate(requirement: Requirement, value: unknown): string?
    if requirement.capability then return requirement.id .. ": capability grants are selected by the host" end
    local problem = json_schema.validate(requirement.schema or {}, value)
    return problem and requirement.id .. ": " .. problem or nil
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
    local raw, raw_error = bounds.dense_list(value, M.MAX_PARAMETERS, "parameters")
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
    local raw, raw_error = bounds.dense_list(value, M.MAX_TARGETS, label)
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
    local raw_entries, entries_error = bounds.dense_list(entries, M.MAX_PACKAGE_ENTRIES, "package entries")
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
            local meta = bounds.object(entry.meta) or {}
            local raw_schema = meta.schema or meta.json_schema
            if type(raw_schema) == "string" then
                local decoded, problem = json.decode(raw_schema)
                if problem then return nil, id .. ": invalid declared schema" end
                raw_schema = decoded
            end
            local schema = raw_schema == nil and {} or bounds.object(raw_schema)
            if not schema then return nil, id .. ": invalid declared schema" end
            local fallback = M.defaults(schema, data.default)
            local schema_default = canonical.encode(fallback) ~= canonical.encode(data.default)
            local has_default = fallback ~= nil
            if has_default then
                local encoded, encode_error = canonical.encode(fallback)
                if not encoded or #encoded > M.MAX_PARAMETER_BYTES then
                    return nil, encode_error or "requirement default exceeds its bound"
                end
            end
            local capability = bounds.text(meta.capability, 80)
            local description = bounds.text(schema.description or meta.description or meta.comment, 4096)
            local requirement: Requirement = {capability = capability, id = id, default = fallback, has_default = has_default,
                targets = targets, has_selected = false, schema = schema, description = description, schema_default = schema_default}
            if has_default and not capability then
                local problem = M.validate(requirement, fallback)
                if problem then return nil, problem end
            end
            requirements[#requirements + 1] = requirement
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
            local problem = M.validate(requirement, M.defaults(requirement.schema or {}, parameter.value))
            if problem then return nil, problem end
            requirement.selected = M.defaults(requirement.schema or {}, parameter.value)
            requirement.has_selected = true
        end
    end
    local missing: {string} = {}
    for _, requirement in ipairs(requirements) do
        if not requirement.capability and not requirement.has_selected and not requirement.has_default then missing[#missing + 1] = requirement.id end
    end
    return {requirements = requirements, missing = missing}, nil
end
-- Project migration database references and top-level SQL configuration holes.
-- Native linking still owns general paths and is verified after publication.
type Entry = {id: string, kind: string, meta: {[string]: unknown}, data: unknown}
function M.migration_targets(raw: unknown, selected: Result): ({Entry}?, string?)
    local supplied, supplied_error = bounds.dense_list(raw, M.MAX_PACKAGE_ENTRIES, "migration package entries")
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
    local bindings: {[string]: Requirement} = {}
    for _, requirement in ipairs(selected.requirements) do bindings[requirement.id] = requirement end
    for _, entry in ipairs(entries) do
        local binding = bindings[entry.id]
        if binding and not binding.capability and (binding.has_selected or binding.schema_default) then
            local original = bounds.object(entry.data)
            if not original then return nil, "invalid requirement configuration: " .. entry.id end
            local data: {[string]: unknown} = {}
            for key, value in pairs(original) do data[key] = value end
            data.default = binding.default
            if binding.has_selected then data.default = binding.selected end
            entry = {id = entry.id, kind = entry.kind, meta = entry.meta, data = data}
        end
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

function M.configuration_path(path: unknown): ({string}?, string?)
    if type(path) ~= "string" or not path:match("^%.[A-Za-z_][A-Za-z0-9_%.]*$") then
        return nil, "configuration target path is invalid"
    end
    if path == ".data" or path == ".meta" then return nil, "configuration cannot replace an entry envelope" end
    local names: {string} = {}
    for name in path:gmatch("[A-Za-z_][A-Za-z0-9_]*") do
        if name == "id" or name == "kind" or name == "security" or name == "policies" or name == "imports"
            or name == "modules" or name == "registry" or name == "lifecycle" then
            return nil, "configuration cannot select execution authority: " .. path
        end
        names[#names + 1] = name
    end
    if names[1] ~= "meta" and names[1] ~= "data" then table.insert(names, 1, "data") end
    return names, nil
end

function M.configuration_targets(entries: {Entry}, selected: Result): ({Entry}?, string?)
    local copied: {Entry} = {}
    local owned: {[string]: {[string]: unknown}} = {}
    for _, entry in ipairs(entries) do
        local encoded, problem = json.encode(entry)
        if not encoded then return nil, tostring(problem) end
        local decoded, invalid = json.decode(encoded)
        local value = bounds.object(decoded)
        if not value then return nil, tostring(invalid) end
        owned[entry.id] = value
        copied[#copied + 1] = value :: Entry
    end
    local assigned: {[string]: string} = {}
    for _, requirement in ipairs(selected.requirements) do
        if not requirement.capability and requirement.schema and next(requirement.schema) ~= nil then
            local value = requirement.default
            if requirement.has_selected then value = requirement.selected end
            if value == nil then return nil, requirement.id .. " is required" end
            for _, target in ipairs(requirement.targets) do
                local destination = owned[target.entry]
                if not destination then return nil, "configuration must target an owned entry: " .. target.entry end
                local names, invalid = M.configuration_path(target.path)
                if not names then return nil, invalid end
                local address = target.entry .. target.path
                local measured = assert(canonical.encode(value))
                if assigned[address] and assigned[address] ~= measured then return nil, "conflicting configuration: " .. address end
                assigned[address] = measured
                local parent = destination
                for index = 1, #names - 1 do
                    local child = bounds.object(parent[names[index]])
                    if not child then
                        if parent[names[index]] ~= nil then return nil, "configuration target is not an object: " .. address end
                        child = {}; parent[names[index]] = child
                    end
                    parent = child
                end
                parent[names[#names]] = value
            end
        end
    end
    return copied, nil
end

function M.frozen_parameters(raw: unknown): ({Parameter}?, string?)
    local declarations, problem = M.read(raw, {})
    if not declarations then return nil, problem end
    local parameters: {Parameter} = {}
    for _, requirement in ipairs(declarations.requirements) do
        if not requirement.capability and requirement.has_default then
            parameters[#parameters + 1] = {name = requirement.id, value = requirement.default}
        end
    end
    table.sort(parameters, function(a: Parameter, b: Parameter): boolean return a.name < b.name end)
    return parameters, nil
end
return M
