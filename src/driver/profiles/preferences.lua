-- MIT. Apply already-authorized saved profile values to a host launch policy.
-- This helper is pure: it does not resolve profiles, registry entries or
-- permissions, and it never expands the host-selected authority.
local bounds = require("bounds")
local instructions = require("instructions")

local profile_access = require("profile_access")
local canonical = require("canonical")
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
type Value = {active_traits: {string}?, authority_grant_id: string?, docker_overrides: Object?, home: "private" | "machine"?, bee: Bee?, options: Object, mcp_tools: {string}, instructions: string}

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
    local unexpected = bounds.fields(object, {"options", "mcp_tools", "instructions", "bee", "home", "docker_overrides", "authority_grant_id", "active_traits"})
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
    return {active_traits = active_traits, authority_grant_id = authority,docker_overrides = docker_overrides, home = home, bee = bee, options = options, mcp_tools = mcp_tools, instructions = text}, nil
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

function M.apply(policy_data: Object, raw: unknown): (Object?, string?)
    local policy = bounds.object(policy_data)
    if not policy then return nil, "policy data must be an object" end
    local saved, saved_error = M.decode(raw)
    if not saved then return nil, saved_error end
    local profile_restrictions, profile_restrictions_error = decode_profile_restrictions(policy.profile_restrictions)
    if not profile_restrictions then return nil, profile_restrictions_error end
    local profile_instructions = policy.profile_instructions
    if profile_instructions == nil then profile_instructions = false end
    if type(profile_instructions) ~= "boolean" then return nil, "profile_instructions must be a boolean" end

    local prepare_options, prepare_options_error = M.decode_prepare_options(policy.prepare_options)
    if not prepare_options then return nil, prepare_options_error end
    for name, selected in pairs(saved.options) do
        local allowed = profile_restrictions[M.path(name)]
        if not allowed then return nil, "option " .. name .. " is not allowed by the host policy" end
        if not allowed_option(allowed, selected) then return nil, "option " .. name .. " has a value that is not allowed by the host policy" end
        prepare_options[name] = selected
    end

    local host_tools, host_tools_error = dense_tools(policy.gateway_tools, "gateway_tools")
    if not host_tools then return nil, host_tools_error end
    local host_tool_set: {[string]: boolean} = {}
    for _, tool in ipairs(host_tools) do host_tool_set[tool] = true end
    for _, tool in ipairs(saved.mcp_tools) do
        if not host_tool_set[tool] then return nil, "mcp_tools contains a tool outside host gateway_tools" end
    end

    local host_instructions, host_instructions_error = instructions.decode(policy.instructions, "host instructions", true)
    if not host_instructions then return nil, host_instructions_error end
    if not profile_instructions and saved.instructions ~= "" then
        return nil, "profile instructions are disabled by the host policy"
    end
    local combined = host_instructions
    if profile_instructions and saved.instructions ~= "" then
        if combined == "" then combined = saved.instructions else combined = combined .. "\n\n" .. saved.instructions end
        if #combined > M.MAX_INSTRUCTIONS_BYTES then return nil, "combined instructions must contain at most 4096 bytes" end
    end

    local result: Object = {}
    for key, value in pairs(policy) do result[key] = value end
    result.prepare_options = prepare_options
    result.instructions = combined ~= "" and combined or nil
    if policy.gateway_tools ~= nil then result.gateway_tools = saved.mcp_tools end
    return result, nil
end

return M
