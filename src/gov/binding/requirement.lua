-- MIT. Host validation of requirement targets.
local bounds = require("bounds")
local driver_admission = require("driver_admission")
local requirements = require("requirements")
local canonical = require("canonical")
local hash = require("hash")
local M = {}
type Entry = {[string]: unknown}
-- Bounded dependency references for Hub and private overlay entries.
function M.references(entry: Entry, captured: {Entry}?): ({string}?, string?)
    local found: {[string]: boolean} = {}
    -- Registry dependency fields contain qualified entry IDs.
    local scalar: {[string]: boolean} = {parent = true, config = true, fs = true, func = true,
        env = true, set = true, store = true, storage = true, bucket = true, host = true,
        process = true, driver = true, queue = true, client = true, server = true,
        router = true, network = true, token_store = true, contract = true}
    local collection: {[string]: boolean} = {depends_on = true, requires = true,
        imports = true, middleware = true, post_middleware = true, policies = true, methods = true}
    local function add(raw: unknown)
        if type(raw) ~= "string" then return end
        local reference = bounds.id(raw)
        if reference and reference:match("^[A-Za-z0-9][A-Za-z0-9_.-]*:[A-Za-z0-9][A-Za-z0-9_.-]*$") then
            found[reference] = true
        end
    end
    local function add_all(value: unknown): string?
        if type(value) ~= "table" then add(value); return nil end
        for key, child in pairs(value) do
            if type(key) ~= "string" and type(key) ~= "number" then return "entry reference structure is not encodable" end
            local problem = add_all(child)
            if problem then return problem end
        end
        return nil
    end
    local function scan(value: unknown, key: string?): string?
        if type(value) ~= "table" then
            if key and key ~= "operation_ref" and (scalar[key] or key:match("_ref$") or key:match("_env$")) then add(value) end
            return nil
        end
        for child_key, child in pairs(value) do
            if type(child_key) == "string" then
                local problem: string? = nil
                if collection[child_key] then problem = add_all(child)
                else problem = scan(child, child_key) end
                if problem then return problem end
            elseif type(child_key) == "number" then
                local problem = scan(child, key)
                if problem then return problem end
            else return "entry reference structure is not encodable" end
        end
        return nil
    end
    local problem = scan(entry, nil)
    if problem then return nil, problem end
    local function group_dependencies(raw: unknown): string?
        local security = bounds.object(raw)
        if not security or security.groups == nil or not captured then return nil end
        local groups = bounds.dense_list(security.groups, 64, "security groups")
        if not groups then return "security groups are malformed" end
        for _, group in ipairs(groups) do
            if type(group) ~= "string" then return "security group identity is malformed" end
            local matched = false
            for _, member in ipairs(captured) do
                if member.kind == "security.policy" or member.kind == "security.policy.expr" then
                    local data = bounds.object(member.data) or member
                    if type(data.groups) == "table" then
                        for _, declared in ipairs(data.groups) do
                            if declared == group then add(member.id); matched = true end
                        end
                    end
                end
            end
            if not matched then return "security group has no measured policies: " .. group end
        end
        return nil
    end
    local data = bounds.object(entry.data) or entry
    local lifecycle = bounds.object(data.lifecycle)
    local group_error = group_dependencies(data.security) or group_dependencies(lifecycle and lifecycle.security)
    if group_error then return nil, group_error end
    local result: {string} = {}
    for reference in pairs(found) do result[#result + 1] = reference end
    table.sort(result)
    if #result > 64 then return nil, "entry references exceed their bound" end
    return result, nil
end

local function object(value: unknown): Entry?
    return bounds.object(value)
end

local function path_value(entry: Entry, path: unknown): (unknown?, string?)
    if type(path) ~= "string" or not path:match("^%.[A-Za-z_][A-Za-z0-9_%.]*$") then
        return nil, "requirement target path is invalid"
    end
    local value: unknown = entry
    for name in path:gmatch("[A-Za-z_][A-Za-z0-9_]*") do
        local parent = object(value)
        if not parent then return nil, "requirement target path does not resolve" end
        value = parent[name]
    end
    return value, nil
end

function M.resolve(entry: Entry, package: string, final: {[string]: Entry}, owned: {[string]: boolean}): (preflight.Requirement?, string?)
    local data = object(entry.data) or entry
    local targets, targets_error = bounds.dense_list(data.targets, 64, "requirement targets")
    if not targets then return nil, targets_error end
    local result_targets: {string} = {}
    local selected: string? = nil
    local meta = object(entry.meta)
    local misplaced = requirements.capability_problem(entry.id, meta)
    if misplaced then return nil, misplaced end
    local configuration_digest: string? = nil
    if meta and (meta.schema ~= nil or meta.json_schema ~= nil) then
        local declarations, problem = requirements.read({{id = entry.id, kind = entry.kind, meta = entry.meta, data = entry.data}}, {})
        if not declarations then return nil, problem end
        if #declarations.missing > 0 then return nil, declarations.missing[1] .. " is required" end
        local bytes, invalid = canonical.encode({value = declarations.requirements[1].default,
            schema = declarations.requirements[1].schema, targets = targets})
        if not bytes then return nil, invalid end
        configuration_digest = hash.sha256(bytes)
        if not configuration_digest then return nil, "cannot measure requirement configuration" end
    end
    for _, raw in ipairs(targets) do
        local target = object(raw)
        local target_id = target and bounds.id(target.entry) or nil
        if not target_id then return nil, "requirement target is invalid" end
        result_targets[#result_targets + 1] = target_id
        local destination = object(final[target_id])
        if not destination then return nil, "requirement target entry is absent: " .. target_id end
        local default_id = bounds.id(data.default)
        local default_entry = default_id and object(final[default_id])
        local default_meta = default_entry and object(default_entry.meta)
        local driver = default_entry and default_entry.kind == "contract.binding" and default_meta and default_meta.type == "harness.driver"
        if driver and not target_id:match("^" .. package:gsub("%.", "%%.") .. "[.:]") then
            local binding_id = driver_admission.append(entry, final)
            if not binding_id then
                return nil, "workspace driver requirements may only append their own harness binding to host activation"
            end
            selected = binding_id
        elseif configuration_digest then
            if not owned[target_id] then return nil, "configuration must target an owned entry: " .. target_id end
            local names, invalid = requirements.configuration_path(target.path)
            if not names then return nil, invalid end
        else
            local binding, binding_error = path_value(destination, target.path)
            local value = bounds.id(binding)
            if not value then return nil, binding_error or "requirement target has no selected binding" end
            if selected and selected ~= value then return nil, "requirement targets disagree on the selected binding" end
            selected = value
        end
    end
    table.sort(result_targets)
    local expected = meta and bounds.id(meta.value_kind) or nil
    local id = bounds.id(entry.id)
    if not id then return nil, "requirement identity is invalid" end
    return {id = id, package = package, value = selected, expected_kind = expected,
        targets = result_targets, configuration_digest = configuration_digest}, nil
end

return M
