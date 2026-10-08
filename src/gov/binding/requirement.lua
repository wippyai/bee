-- MIT. Host validation of requirement targets and application capabilities.
local bounds = require("bounds")
local capability_model = require("capability_model")
local agent_tool = require("agent_tool")
local drivers = require("drivers")
local driver_admission = require("driver_admission")
local requirements = require("requirements")
local canonical = require("canonical")
local hash = require("hash")
local M = {}
type Entry = {[string]: unknown}
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

function M.resolve(entry: Entry, package: string, final: {[string]: Entry}, owned: {[string]: boolean},
    catalog: capability_model.Vocabulary?): (preflight.Requirement?, string?)
    local data = object(entry.data) or entry
    local targets, targets_error = bounds.dense_list(data.targets, 64, "requirement targets")
    if not targets then return nil, targets_error end
    local result_targets: {string} = {}
    local selected: string? = nil
    local meta = object(entry.meta)
    local capability = meta and meta.capability or nil
    local configuration_digest: string? = nil
    if not capability and meta and (meta.schema ~= nil or meta.json_schema ~= nil) then
        local declarations, problem = requirements.read({{id = entry.id, kind = entry.kind, meta = entry.meta, data = entry.data}}, {})
        if not declarations then return nil, problem end
        if #declarations.missing > 0 then return nil, declarations.missing[1] .. " is required" end
        local bytes, invalid = canonical.encode({value = declarations.requirements[1].default,
            schema = declarations.requirements[1].schema, targets = targets})
        if not bytes then return nil, invalid end
        configuration_digest = hash.sha256(bytes)
        if not configuration_digest then return nil, "cannot measure requirement configuration" end
    end
    local capability_request: preflight.CapabilityRequest? = nil
    if capability ~= nil then
        if not meta or meta.value_kind ~= "security.policy" or type(capability) ~= "string"
            or not capability:match("^[a-z][a-z0-9_.-]*$") or #capability > 80
            or type(meta.reason) ~= "string" or #meta.reason == 0 or #meta.reason > 512
            or meta.reason:find("%c") or #targets ~= 1 or data.default ~= nil then
            return nil, "capability requirement metadata is invalid"
        end
        if not catalog then return nil, "host capability catalog is absent" end
        local normalized, normalize_error = capability_model.normalize(catalog, capability, meta.parameters)
        if not normalized then return nil, normalize_error or "capability parameters are invalid" end
        local catalog_revision, template_revision = capability_model.revisions(catalog, capability)
        if not catalog_revision or not template_revision then return nil, "host capability catalog is malformed" end
        local reason = bounds.text(meta.reason, 512)
        local capability_name = bounds.text(capability, 80)
        if not reason or not capability_name then return nil, "capability requirement metadata is invalid" end
        capability_request = {capability = capability_name, parameters = normalized, reason = reason,
            target = "", path = "",
            catalog_revision = catalog_revision, template_revision = template_revision}
    elseif meta and (meta.parameters ~= nil or meta.reason ~= nil) then
        return nil, "capability requirement metadata is incomplete"
    end
    -- An agent-launch request names the launch definitions the application may
    -- start. The generated policy pairs the sessions contract with the launch
    -- action on those names, so each name must be a real launch definition.
    if capability == "agents.launch" and capability_request then
        local params = capability_request.parameters
        local definitions = params.definitions
        if type(definitions) ~= "table" then return nil, "managed agent launch parameters are invalid" end
        for _, ref in ipairs(definitions) do
            local candidate = type(ref) == "string" and object(final[ref]) or nil
            local candidate_meta = candidate and object(candidate.meta) or nil
            if not candidate or candidate.kind ~= "registry.entry" or not candidate_meta
                or candidate_meta.type ~= "bee.launch_definition" then
                return nil, "managed agent launch definition " .. tostring(ref) .. " is not a launch definition"
            end
        end
    end
    -- An agent tools request names this artifact's own tool functions. Each
    -- decodes as a tool with schemas Bee advertises and declares no security
    -- of its own: it runs only with the application's scope.
    if capability == "agent.tools" and capability_request then
        local tools = capability_request.parameters.tools
        if type(tools) ~= "table" then return nil, "agent tool parameters are invalid" end
        local aliases: {[string]: string} = {}
        for _, ref in ipairs(tools) do
            local candidate = type(ref) == "string" and object(final[ref]) or nil
            if not candidate or not owned[ref] then
                return nil, "agent tool " .. tostring(ref) .. " is not this artifact's own tool function"
            end
            local decoded, decode_error = agent_tool.application(ref, candidate)
            if not decoded then return nil, decode_error end
            local prior = aliases[decoded.alias]
            if prior then return nil, "agent tools " .. prior .. " and " .. ref .. " share the alias " .. decoded.alias end
            aliases[decoded.alias] = ref
        end
    end
    -- A Hive exposure request names this artifact's own operations at the
    -- requested mode; the generated scope policy carries the enforcement, so
    -- the requirement appends to one of those operations instead of an app.
    local exposure: {[string]: boolean}? = nil
    if capability == "hive.expose" and capability_request then
        local params = capability_request.parameters
        local mode = params.mode
        local operations = params.operations
        if type(mode) ~= "string" or type(operations) ~= "table" then
            return nil, "Hive exposure parameters are invalid"
        end
        exposure = {}
        for _, ref in ipairs(operations) do
            local candidate = type(ref) == "string" and object(final[ref]) or nil
            local candidate_meta = candidate and object(candidate.meta) or nil
            if not candidate or candidate.kind ~= "function.lua" or not owned[ref]
                or not candidate_meta or candidate_meta.hive ~= mode then
                return nil, "Hive exposure operation " .. tostring(ref) .. " is not this artifact's " .. tostring(mode) .. " operation"
            end
            exposure[ref] = true
        end
    end
    for _, raw in ipairs(targets) do
        local target = object(raw)
        local target_id = target and bounds.id(target.entry) or nil
        if not target_id then return nil, "requirement target is invalid" end
        result_targets[#result_targets + 1] = target_id
        local destination = object(final[target_id])
        if not destination then return nil, "requirement target entry is absent: " .. target_id end
        local driver = drivers.source_of(package)
        if driver and not target_id:match("^" .. package:gsub("%.", "%%.") .. "[.:]") then
            local binding_id = driver_admission.append(entry, final)
            if capability_request or not binding_id then
                return nil, "workspace driver requirements may only append their own harness binding to host activation"
            end
            selected = binding_id
        elseif capability_request then
            if exposure then
                if target.path ~= ".security.policies +=" or not exposure[target_id] then
                    return nil, "Hive exposure requirement must append policies to one of its own operations"
                end
            else
                local target_meta = object(destination.meta)
                if target.path ~= ".security.policies +=" or not owned[target_id]
                    or destination.kind ~= "process.lua" or not target_meta or target_meta.type ~= "bee.app" then
                    return nil, "capability requirement must append policies to its own application"
                end
            end
            capability_request.target = target_id
            capability_request.path = target.path
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
        targets = result_targets, capability_request = capability_request, configuration_digest = configuration_digest}, nil
end

return M
