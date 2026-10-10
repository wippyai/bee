-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local instructions = require("instructions")

local profile_access = require("profile_access")
local canonical = require("canonical")
local descriptors = require("descriptors")
local json = require("json")
local toml = require("toml")
local M = {}
M.MAX_OPTIONS = 64
M.MAX_OPTION_VALUES = 32
M.MAX_OPTION_VALUE_BYTES = 512
M.MAX_MCP_TOOLS = 64
M.MAX_INSTRUCTIONS_BYTES = instructions.MAX_BYTES

type Object = {[string]: unknown}
type Scalar = string | number | boolean
type Option = {kind: "enum", values: {Scalar}} | {kind: "text", max_bytes: integer} | {kind: "declared"}
type Bee = profile_access.Bee
type Value = {context: {[string]: unknown}?, requestable: {string}?, active_traits: {string}?, authority_grant_id: string?, docker_overrides: Object?, home: "private" | "machine"?, bee: Bee?, options: Object, mcp_tools: {string}, instructions: string}

local RESERVED_OPTIONS: {[string]: boolean} = {
    profile_id = true,
    brief = true,
    resume_ref = true,
    permission_exchange = true,
    gateway_tools = true,
    gateway_hooks = true,
    turn_budget = true,
    max_turns = true,
    max_steps = true,
}

local function scalar(value: unknown, label: string): (Scalar?, string?)
    local kind = type(value)
    if kind == "string" then
        local text = value
        if #text > M.MAX_OPTION_VALUE_BYTES or text:find("%c") then
            return nil, label .. " must contain at most 512 printable bytes"
        end
        return text, nil
    end
    if kind == "number" then
        local number = value
        if number ~= number or number == math.huge or number == -math.huge then
            return nil, label .. " must be finite"
        end
        return number, nil
    end
    if kind == "boolean" then return value, nil end
    return nil, label .. " must be a scalar"
end

local function option_name(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > 80 or not value:match("^[a-z][a-z0-9_]*$") then
        return nil
    end
    if RESERVED_OPTIONS[value] then return nil end
    return value
end

local function decode_options(value: unknown, label: string): (Object?, string?)
    local object = bounds.object(value)
    if not object then return nil, label .. " must be an object" end
    local result: Object = {}
    local count = 0
    for name, item in pairs(object) do
        count = count + 1
        if count > M.MAX_OPTIONS then return nil, label .. " exceeds " .. tostring(M.MAX_OPTIONS) .. " options" end
        if not option_name(name) then
            if RESERVED_OPTIONS[name] then return nil, label .. " contains reserved option " .. name end
            return nil, label .. " contains an invalid option name"
        end
        if bounds.member(name, {"model", "effort", "permission_mode"}) and type(item) ~= "string" then return nil, label .. "." .. name .. " must be text" end
        local encoded = canonical.encode(item)
        if not encoded or #encoded > 8192 then return nil, label .. "." .. name .. " exceeds JSON value bounds" end
        result[name] = item
    end
    return result, nil
end

local function decode_allowed(value: unknown, name: string): ({Scalar}?, string?)
    if type(value) ~= "table" then return nil, "profile_restrictions." .. name .. " must be a list" end
    local list = value
    local count = 0
    local highest = 0
    for key in pairs(list) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return nil, "profile_restrictions." .. name .. " must be dense"
        end
        count = count + 1
        if key > highest then highest = key end
    end
    if count == 0 then return nil, "profile_restrictions." .. name .. " must be nonempty" end
    if count > M.MAX_OPTION_VALUES then return nil, "profile_restrictions." .. name .. " exceeds 32 values" end
    if count ~= highest then return nil, "profile_restrictions." .. name .. " must be dense" end
    local result: {Scalar} = {}
    for index = 1, count do
        local item, item_error = scalar(list[index], "profile_restrictions." .. name .. "[" .. tostring(index) .. "]")
        if item == nil then return nil, item_error end
        result[index] = item
    end
    return result, nil
end

local function decode_option(value: unknown, name: string): (Option?, string?)
    if type(value) ~= "table" then
        return nil, "profile_restrictions." .. name .. " must be an enum list or descriptor"
    end
    local object = value
    if object.kind == nil then
        local values, values_error = decode_allowed(value, name)
        if not values then return nil, values_error end
        return {kind = "enum", values = values}, nil
    end
    if object.kind == "declared" and not bounds.fields(object, {"kind"}) then return {kind = "declared"}, nil end
    local kind = bounds.member(object.kind, {"enum", "text"})
    if not kind then return nil, "profile_restrictions." .. name .. ".kind must be enum or text" end
    if kind == "enum" then
        local extra = bounds.fields(object, {"kind", "values"})
        if extra then return nil, "profile_restrictions." .. name .. ": " .. extra end
        local values, values_error = decode_allowed(object.values, name)
        if not values then return nil, values_error end
        return {kind = "enum", values = values}, nil
    end
    local extra = bounds.fields(object, {"kind", "max_bytes"})
    if extra then return nil, "profile_restrictions." .. name .. ": " .. extra end
    local max_bytes = bounds.integer(object.max_bytes)
    if not max_bytes or max_bytes < 1 or max_bytes > M.MAX_OPTION_VALUE_BYTES then
        return nil, "profile_restrictions." .. name .. ".max_bytes must be between 1 and " .. tostring(M.MAX_OPTION_VALUE_BYTES)
    end
    return {kind = "text", max_bytes = max_bytes}, nil
end

function M.path(name: string): string
    if bounds.member(name, {"model", "effort", "permission_mode", "tool_allow", "tool_deny", "system_prompt_append", "env"}) then return "provider." .. name end
    return "provider.options." .. name
end
function M.restriction_paths(raw: unknown): Object
    local values = bounds.object(raw) or {}
    local result: Object = {}
    for name, value in pairs(values) do result[M.path(name)] = value end
    return result
end
local function decode_profile_restrictions(value: unknown): ({[string]: Option}?, string?)
    local object = bounds.object(value == nil and {} or value)
    if not object then return nil, "profile_restrictions must be an object" end
    local result: {[string]: Option} = {}
    local count = 0
    for name, allowed in pairs(object) do
        count = count + 1
        if count > M.MAX_OPTIONS then return nil, "profile_restrictions exceeds " .. tostring(M.MAX_OPTIONS) .. " options" end
        local field = name:match("^provider%.options%.([a-z][a-z0-9_]*)$") or name:match("^provider%.([a-z][a-z0-9_]*)$")
        if not field or not option_name(field) or M.path(field) ~= name then return nil, "profile_restrictions must reference canonical descriptor paths" end
        local option, option_error = decode_option(allowed, name)
        if not option then return nil, option_error end
        result[name] = option
    end
    return result, nil
end

M.decode_profile_restrictions = decode_profile_restrictions

function M.decode_prepare_options(value: unknown): (Object?, string?)
    local object = bounds.object(value == nil and {} or value)
    if not object then return nil, "prepare_options must be an object" end
    local decoded, decode_error = decode_options(object, "prepare_options")
    if not decoded then return nil, decode_error end
    local result: Object = {}
    for name, selected in pairs(decoded) do result[name] = selected end
    return result, nil
end

local function dense_tools(value: unknown, label: string): ({string}?, string?)
    if value == nil then return {}, nil end
    local tools, tools_error = bounds.ids(value, true)
    if not tools then return nil, label .. ": " .. tostring(tools_error) end
    if #tools > M.MAX_MCP_TOOLS then return nil, label .. " exceeds 64 tools" end
    table.sort(tools)
    return tools, nil
end

function M.decode(value: unknown): (Value?, string?)
    local object = bounds.object(value)
    if not object then return nil, "saved preferences must be an object" end
    local unexpected = bounds.fields(object, {"options", "mcp_tools", "instructions", "bee", "home", "docker_overrides", "authority_grant_id", "active_traits", "requestable", "context"})
    if unexpected then return nil, unexpected end
    local options, options_error = decode_options(object.options == nil and {} or object.options, "options")
    if not options then return nil, options_error end
    local mcp_tools, tools_error = dense_tools(object.mcp_tools, "mcp_tools")
    if not mcp_tools then return nil, tools_error end
    local text, instructions_error = instructions.decode(object.instructions, "instructions", true)
    if not text then return nil, instructions_error end
    local bee: Bee? = nil
    if object.bee ~= nil then
        local decoded, err = profile_access.decode(object.bee)
        if not decoded then return nil, err end
        bee = decoded
    end
    local home: "private" | "machine"? = nil
    if object.home == "private" then home = "private"
    elseif object.home == "machine" then home = "machine"
    elseif object.home ~= nil then return nil, "home must be private or machine" end
    local docker_overrides = bounds.object(object.docker_overrides)
    if object.docker_overrides ~= nil and not docker_overrides then return nil, "docker_overrides must be an object" end
    local authority = bounds.id(object.authority_grant_id)
    if object.authority_grant_id ~= nil and not authority then return nil,"invalid profile authority grant" end
    local active_traits = object.active_traits == nil and nil or bounds.ids(object.active_traits, true)
    if object.active_traits ~= nil and not active_traits then return nil, "invalid active_traits" end
    local requestable: {string}? = nil
    if object.requestable ~= nil then
        requestable = bounds.ids(object.requestable, true)
        if not requestable or #requestable > 16 then return nil, "invalid requestable traits" end
    end
    local context = bounds.object(object.context)
    if object.context ~= nil and not context then return nil, "context must be an object" end
    return {context = context, requestable = requestable, active_traits = active_traits, authority_grant_id = authority,docker_overrides = docker_overrides, home = home, bee = bee, options = options, mcp_tools = mcp_tools, instructions = text}, nil
end

local function allowed_value(values: {Scalar}, selected: Scalar): boolean
    for _, value in ipairs(values) do
        if type(value) == type(selected) and value == selected then return true end
    end
    return false
end

local function allowed_option(option: Option, selected: unknown): boolean
    if option.kind == "declared" then return canonical.encode(selected) ~= nil end
    if option.kind == "enum" then
        if type(selected) ~= "string" and type(selected) ~= "number" and type(selected) ~= "boolean" then return false end
        return allowed_value(option.values, selected)
    end
    if type(selected) ~= "string" then return false end
    return #selected > 0 and #selected <= option.max_bytes and not selected:find("%c")
end

local function compile_scope(policy: Object, saved: Value?): ({string}?, string?, string?)
    local profile_instructions = policy.profile_instructions
    if profile_instructions == nil then profile_instructions = false end
    if type(profile_instructions) ~= "boolean" then return nil, nil, "profile_instructions must be a boolean" end
    local host_tools, host_tools_error = dense_tools(policy.gateway_tools, "gateway_tools")
    if not host_tools then return nil, nil, host_tools_error end
    local host_tool_set: {[string]: boolean} = {}
    for _, tool in ipairs(host_tools) do host_tool_set[tool] = true end
    for _, tool in ipairs((saved and saved.mcp_tools or host_tools)) do
        if not host_tool_set[tool] then return nil, nil, "mcp_tools contains a tool outside host gateway_tools" end
    end

    local host_instructions, host_instructions_error = instructions.decode(policy.instructions, "host instructions", true)
    if not host_instructions then return nil, nil, host_instructions_error end
    if not profile_instructions and (saved and saved.instructions or "") ~= "" then
        return nil, nil, "profile instructions are disabled by the host policy"
    end
    local combined = host_instructions
    if profile_instructions and (saved and saved.instructions or "") ~= "" then
        if combined == "" then combined = (saved and saved.instructions or "") else combined = combined .. "\n\n" .. (saved and saved.instructions or "") end
        if #combined > M.MAX_INSTRUCTIONS_BYTES then return nil, nil, "combined instructions must contain at most 4096 bytes" end
    end

    return saved and saved.mcp_tools or host_tools, combined ~= "" and combined or nil, nil
end

type Capability = {supported: boolean, reason: string?}
type EffectiveOption = {declaration: Object, default: unknown, default_source: string, locked_reason: string?, allowed: Option?}
type Effective = {fields: {[string]: EffectiveOption}, values: Object, provenance: {[string]: string}, gateway_tools: {string}, instructions: string?}

local function subset(selected: {string}, ceiling: {string}): boolean
    for _, right in ipairs(selected) do if not bounds.member(right, ceiling) then return false end end
    return true
end

local function ceiling_value(field: Object, value: unknown, constraint: Object): (unknown, string?)
    local capabilities = bounds.object(field.capabilities)
    local rights = capabilities and type(value) == "string" and bounds.ids(capabilities[value], true)
    local ceiling = bounds.ids(constraint.capabilities or field.ceiling, true)
    if capabilities and (not rights or not ceiling or not subset(rights, ceiling)) then return nil, "permission capabilities exceed the host ceiling" end
    if constraint.rights ~= nil then
        local selected, allowed = bounds.ids(value, true), bounds.ids(constraint.rights, true)
        if not selected or not allowed or not subset(selected, allowed) then return nil, "rights exceed the host ceiling" end
    end
    if constraint.denies ~= nil then
        local selected, denied = bounds.ids(value, true), bounds.ids(constraint.denies, true)
        if not selected or not denied then return nil, "denies must be identifier lists" end
        for _, item in ipairs(denied) do if not bounds.member(item, selected) then selected[#selected + 1] = item end end
        table.sort(selected)
        value = selected
    end
    if constraint.maximum ~= nil then
        if type(value) ~= "number" or type(constraint.maximum) ~= "number" then return nil, "limit must be numeric" end
        value = math.min(value, constraint.maximum)
    end
    return value, nil
end

function M.compile(descriptor: descriptors.Descriptor, policy: Object?, capabilities: {[string]: Capability}?, values: Object?, writer: string?, selection: Value?, provenance: Object?): (Effective?, string?)
    local declared = bounds.object(descriptor.options.fields) or {}
    local restrictions, restriction_error = decode_profile_restrictions(policy and policy.profile_restrictions)
    if not restrictions then return nil, restriction_error end
    local constraints = policy and bounds.object(policy.option_constraints) or {}
    local prepared = policy and bounds.object(policy.prepare_options) or {}
    if policy and policy.option_constraints ~= nil and not constraints then return nil, "option_constraints must be an object" end
    for name, raw in pairs(constraints or {}) do
        if declared[name] == nil then return nil, "Constraint names undeclared option " .. name end
        local constraint = bounds.object(raw)
        if not constraint or bounds.fields(constraint, {"rights", "denies", "maximum", "capabilities", "locked", "reason"}) then return nil, "Invalid option constraint " .. name end
        for _, key in ipairs({"rights", "denies", "capabilities"}) do
            if constraint[key] ~= nil and not bounds.ids(constraint[key], true) then return nil, "Constraint " .. key .. " must be an identifier list" end
        end
        if constraint.maximum ~= nil and (type(constraint.maximum) ~= "number" or constraint.maximum < 0 or constraint.maximum ~= constraint.maximum or constraint.maximum == math.huge) then return nil, "Constraint maximum must be finite and nonnegative" end
        if constraint.locked ~= nil and type(constraint.locked) ~= "boolean" then return nil, "Constraint locked must be boolean" end
        if constraint.reason ~= nil and not bounds.text(constraint.reason, 512) then return nil, "Constraint reason must be bounded text" end
    end
    for name in pairs(prepared or {}) do if declared[name] == nil then return nil, "Host default names undeclared option " .. name end end
    local tools, text, scope_error = compile_scope(policy or {}, selection)
    if not tools then return nil, scope_error end
    local result: Effective = {fields = {}, values = {}, provenance = {}, gateway_tools = tools, instructions = text}
    for name, raw in pairs(declared) do
        local field = bounds.object(raw) or {}
        local path = bounds.id(field.path)
        local constraint = bounds.object((constraints or {})[name]) or {}
        local default: unknown = field.default
        local default_ceiling_error: string? = nil
        local source = default == nil and "CLI" or "driver schema"
        if prepared and prepared[name] ~= nil then default = prepared[name]; source = "host policy" end
        if default ~= nil then
            local _, invalid = descriptors.decode_option(name, field, default)
            if invalid then return nil, invalid end
            local constrained, ceiling_error = ceiling_value(field, default, constraint)
            default_ceiling_error = ceiling_error
            if not ceiling_error then
                local _, constrained_error = descriptors.decode_option(name, field, constrained)
                if constrained_error then return nil, constrained_error end
                if canonical.encode(constrained) ~= canonical.encode(default) then source = "host ceiling" end
                default = constrained
            end
        end
        local allowed = path and restrictions[path] or nil
        local reason: string? = nil
        local capability = path and capabilities and capabilities[path]
        if path and capabilities and (not capability or not capability.supported) then reason = capability and capability.reason or "Installed CLI support is not established" end
        if path and policy and not allowed and not (name == "system_prompt_append" and policy.profile_instructions == true) then reason = "Disabled by host policy" end
        local trust_mapping = bounds.object(field.trust)
        if trust_mapping and trust_mapping.unsupported == true then reason = "Driver does not support folder trust" end
        if capabilities and path and default ~= nil and (not capability or not capability.supported)
            and not (trust_mapping and trust_mapping.unsupported == true) then
            return nil, name .. ": default lacks installed CLI support"
        end
        if constraint.locked == true then reason = bounds.text(constraint.reason, 512) or "Locked by host policy" end
        if field.security_class == "person-only" and writer and writer ~= "person" then reason = "Requires a person write with consent provenance" end
        local row: EffectiveOption = {declaration = field, default = default, default_source = source, locked_reason = reason, allowed = allowed}
        if allowed and allowed.kind == "enum" then
            local admitted: {Scalar} = {}
            for _, candidate in ipairs(allowed.values) do
                local valid, invalid = descriptors.decode_option(name, field, candidate)
                local _, ceiling_error = ceiling_value(field, valid, constraint)
                if not invalid and not ceiling_error then admitted[#admitted + 1] = candidate end
            end
            row.allowed = {kind = "enum", values = admitted}
            if #admitted == 0 then row.locked_reason = "No values are admitted by the host ceiling" end
        elseif allowed and allowed.kind == "declared" then
            local spec = descriptors.runtime_spec(field)
            local enums = bounds.array(spec.values, 64)
            if enums then
                local admitted: {Scalar} = {}
                for _, candidate in ipairs(enums) do
                    local _, err = ceiling_value(field, candidate, constraint)
                    if not err and (type(candidate) == "string" or type(candidate) == "number" or type(candidate) == "boolean") then admitted[#admitted + 1] = candidate end
                end
                row.allowed = {kind = "enum", values = admitted}
            end
        end
        if default ~= nil and (default_ceiling_error or (row.allowed and not allowed_option(row.allowed, default))) then
            local replacement: unknown = nil
            if row.allowed and row.allowed.kind == "enum" then
                local rights = bounds.object(field.capabilities)
                for _, candidate in ipairs(row.allowed.values) do
                    local least = #row.allowed.values == 1
                    if rights and type(candidate) == "string" then
                        local candidate_rights = bounds.ids(rights[candidate], true)
                        least = candidate_rights ~= nil
                        for _, other in ipairs(row.allowed.values) do
                            local other_rights = type(other) == "string" and bounds.ids(rights[other], true)
                            if not candidate_rights or not other_rights or not subset(candidate_rights, other_rights) then least = false end
                        end
                    end
                    if least then replacement = candidate; break end
                end
            end
            if replacement == nil then return nil, name .. ": policy excludes the default and declares no least-capability allowed value" end
            default, source = replacement, "host policy"
            row.default, row.default_source = default, source
        end
        result.fields[name] = row
        local explicit = values and values[name] ~= nil
        local value: unknown = explicit and values and values[name] or default
        if explicit and values then value = values[name] end
        if value ~= nil and not (trust_mapping and trust_mapping.unsupported == true and not explicit) then
            if explicit and reason then return nil, name .. ": " .. reason end
            local _, err = descriptors.decode_option(name, field, value)
            if err then return nil, err end
            if policy and path and allowed and not allowed_option(allowed, value) then return nil, "option " .. name .. " has a value that is not allowed by the host policy" end
            local constrained, ceiling_error = ceiling_value(field, value, constraint)
            if ceiling_error then return nil, name .. ": " .. ceiling_error end
            local compiled_value, constrained_error = descriptors.decode_option(name, field, constrained)
            if constrained_error then return nil, constrained_error end
            result.values[name] = compiled_value
            result.provenance[name] = provenance and bounds.member(provenance[name], {"explicit", "driver schema", "host policy", "host ceiling", "CLI"}) or (explicit and "explicit" or source)
        end
    end
    for name in pairs(values or {}) do if not result.fields[name] then return nil, "Undeclared option " .. name end end
    for name, row in pairs(result.fields) do
        if result.values[name] ~= nil then
            for _, dependency in ipairs(bounds.ids(row.declaration.dependencies, true) or {}) do
                if result.values[dependency] == nil then return nil, name .. " requires " .. dependency end
            end
            for _, conflict in ipairs(bounds.ids(row.declaration.conflicts, true) or {}) do
                if result.values[conflict] ~= nil then return nil, name .. " conflicts with " .. conflict end
            end
        end
    end
    return result, nil
end

local function authority_key(key: string): boolean
    local normalized = key:lower():gsub("[^a-z]", "")
    for _, namespace in ipairs({"network", "mcp", "provider", "sandbox", "approval", "permission", "env", "hook", "trust", "plugin", "tool", "project", "profile", "baseurl", "endpoint", "apikey", "auth", "token", "command", "socket", "proxy"}) do
        if normalized:find(namespace, 1, true) then return true end
    end
    return false
end

function M.check_config(descriptor: descriptors.Descriptor, policy: Object, filename: string, content: string): string?
    local format = filename:match("%.(json)$") or filename:match("%.(toml)$")
    if not format then return nil end
    local document: unknown = nil
    if format == "json" then document = json.decode(content) else document = toml.decode(content) end
    local root = bounds.object(document)
    if format == "toml" and content:match("^%s*$") then root = {} end
    if not root then return "Configuration is not an object: " .. filename end
    local compiled, invalid = M.compile(descriptor, policy)
    if not compiled then return invalid end
    local mappings: {[string]: string} = {}
    for name, row in pairs(compiled.fields) do
        for _, raw_alias in ipairs(bounds.array(row.declaration.config_aliases, 8) or {}) do
            local alias = bounds.object(raw_alias) or {}
            local path = bounds.ids(alias.path, true)
            if alias.format == format and path then mappings[table.concat(path, ".")] = name end
        end
        for _, raw_render in ipairs(bounds.array(row.declaration.render, 32) or {}) do
            local render = bounds.object(raw_render) or {}
            local path = bounds.ids(render.path, true)
            if render.kind == "config" and render.format == format and path then mappings[table.concat(path, ".")] = name end
        end
    end
    local selections: Object = {}
    local paths: {[string]: string} = {}
    local function inspect(object: Object, prefix: string, authority: boolean): string?
        for key, value in pairs(object) do
            local path = prefix == "" and key or prefix .. "." .. key
            local name = mappings[path]
            if name then
                local row = compiled.fields[name]
                if row.locked_reason then
                    if canonical.encode(value) ~= canonical.encode(row.default) then return filename .. ": " .. path .. " has no admitted mapping: " .. row.locked_reason end
                else
                    if selections[name] ~= nil and canonical.encode(selections[name]) ~= canonical.encode(value) then
                        return filename .. ": conflicting configuration mapping " .. path
                    end
                    selections[name], paths[name] = value, path
                end
            else
                local restricted = authority or authority_key(key)
                local child = bounds.object(value)
                if child and next(child) ~= nil then
                    local err = inspect(child, path, restricted)
                    if err then return err end
                elseif restricted then
                    return filename .. ": authority-bearing key " .. path .. " has no admitted mapping"
                end
            end
        end
        return nil
    end
    local inspection_error = inspect(root, "", false)
    if inspection_error then return inspection_error end
    local checked, check_error = M.compile(descriptor, policy, nil, selections)
    if not checked then return filename .. ": " .. tostring(check_error) end
    for name, value in pairs(selections) do
        local decoded, decode_error = descriptors.decode_option(name, assert(compiled.fields[name].declaration), value)
        if decode_error then return filename .. ": " .. paths[name] .. ": " .. decode_error end
        if canonical.encode(checked.values[name]) ~= canonical.encode(decoded) then return filename .. ": " .. paths[name] .. " exceeds host limits or denies" end
    end
    return nil
end

function M.apply(policy_data: Object, raw: unknown, descriptor: descriptors.Descriptor?): (Object?, string?)
    local policy = bounds.object(policy_data)
    if not policy then return nil, "policy data must be an object" end
    local saved, saved_error = M.decode(raw)
    if not saved then return nil, saved_error end
    local profile_restrictions, profile_restrictions_error = decode_profile_restrictions(policy.profile_restrictions)
    if not profile_restrictions then return nil, profile_restrictions_error end

    local prepare_options, prepare_options_error = M.decode_prepare_options(policy.prepare_options)
    if not prepare_options then return nil, prepare_options_error end
    for name, selected in pairs(saved.options) do
        local allowed = profile_restrictions[M.path(name)]
        if not descriptor then
            if not allowed then return nil, "option " .. name .. " is not allowed by the host policy" end
            if not allowed_option(allowed, selected) then return nil, "option " .. name .. " has a value that is not allowed by the host policy" end
        end
        prepare_options[name] = selected
    end

    local value_provenance: Object = {}
    local tools: {string}? = nil
    local combined: string? = nil
    if descriptor then
        local values: Object = {}
        for name, value in pairs(saved.options) do values[name] = value end
        if saved.instructions ~= "" then values.system_prompt_append = saved.instructions end
        local compiled, compile_error = M.compile(descriptor, policy, nil, values, nil, saved)
        if not compiled then return nil, compile_error end
        value_provenance = compiled.provenance
        tools, combined = compiled.gateway_tools, compiled.instructions
        for name, value in pairs(compiled.values) do
            local row = compiled.fields[name]
            if row.declaration.path and name ~= "system_prompt_append" then prepare_options[name] = value end
        end
    else
        local scope_error: string? = nil
        tools, combined, scope_error = compile_scope(policy, saved)
        if not tools then return nil, scope_error end
    end
    local result: Object = {}
    for key, value in pairs(policy) do result[key] = value end
    result.option_provenance = value_provenance
    result.prepare_options = prepare_options
    result.instructions = combined
    if policy.gateway_tools ~= nil then result.gateway_tools = tools end
    return result, nil
end

return M
