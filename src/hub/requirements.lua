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
        local name, name_error = qualified_name(parameter.name, "parameters[" .. tostring(index) .. "].name")
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
        end
    end
    for _, parameter in ipairs(parameters) do
        local requirement_index = by_id[parameter.name]
        if not requirement_index then return nil, "parameter names no requirement " .. parameter.name end
        local requirement = requirements[requirement_index]
        requirement.selected = parameter.value
        requirement.has_selected = true
    end
    local missing: {string} = {}
    for _, requirement in ipairs(requirements) do
        if not requirement.has_selected and not requirement.has_default then missing[#missing + 1] = requirement.id end
    end
    return {requirements = requirements, missing = missing}, nil
end
return M
