-- MIT. Apply already-authorized saved profile values to a host launch policy.
-- This helper is pure: it does not resolve profiles, registry entries or
-- permissions, and it never expands the host-selected authority.
local bounds = require("bounds")

local M = {}
-- Nine leaves room for one historical top-level option translated by the
-- profile owner while keeping the bounded scalar map small.
M.MAX_OPTIONS = 9
M.MAX_OPTION_VALUES = 32
M.MAX_OPTION_VALUE_BYTES = 512
M.MAX_MCP_TOOLS = 64
M.MAX_INSTRUCTIONS_BYTES = 4096

type Object = {[string]: unknown}
type Scalar = string | number | boolean
type Option = {kind: "enum", values: {Scalar}} | {kind: "text", max_bytes: integer}
type Value = {options: {[string]: Scalar}, mcp_tools: {string}, instructions: string}

local RESERVED_OPTIONS: {[string]: boolean} = {
    profile_id = true,
    brief = true,
    resume_ref = true,
    permission_exchange = true,
    gateway_tools = true,
    gateway_hooks = true,
}

local function scalar(value: unknown, label: string): (Scalar?, string?)
    local kind = type(value)
    if kind == "string" then
        local text = value :: string
        if #text > M.MAX_OPTION_VALUE_BYTES or text:find("%c") then
            return nil, label .. " must contain at most 512 printable bytes"
        end
        return text, nil
    end
    if kind == "number" then
        local number = value :: number
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

local function decode_options(value: unknown, label: string): ({[string]: Scalar}?, string?)
    local object = bounds.object(value)
    if not object then return nil, label .. " must be an object" end
    local result: {[string]: Scalar} = {}
    local count = 0
    for name, item in pairs(object) do
        count = count + 1
        if count > M.MAX_OPTIONS then return nil, label .. " exceeds 8 options" end
        if not option_name(name) then
            if RESERVED_OPTIONS[name] then return nil, label .. " contains reserved option " .. name end
            return nil, label .. " contains an invalid option name"
        end
        local selected, selected_error = scalar(item, label .. "." .. name)
        if selected == nil then return nil, selected_error end
        result[name] = selected
    end
    return result, nil
end

local function decode_allowed(value: unknown, name: string): ({Scalar}?, string?)
    if type(value) ~= "table" then return nil, "profile_options." .. name .. " must be a list" end
    local list = value :: {unknown}
    local count = 0
    local highest = 0
    for key in pairs(list) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return nil, "profile_options." .. name .. " must be dense"
        end
        count = count + 1
        if key > highest then highest = key end
    end
    if count == 0 then return nil, "profile_options." .. name .. " must be nonempty" end
    if count > M.MAX_OPTION_VALUES then return nil, "profile_options." .. name .. " exceeds 32 values" end
    if count ~= highest then return nil, "profile_options." .. name .. " must be dense" end
    local result: {Scalar} = {}
    for index = 1, count do
        local item, item_error = scalar(list[index], "profile_options." .. name .. "[" .. tostring(index) .. "]")
        if item == nil then return nil, item_error end
        result[index] = item
    end
    return result, nil
end

local function decode_option(value: unknown, name: string): (Option?, string?)
    if type(value) ~= "table" then
        return nil, "profile_options." .. name .. " must be an enum list or descriptor"
    end
    local object = value :: {[string]: unknown}
    if object.kind == nil then
        local values, values_error = decode_allowed(value, name)
        if not values then return nil, values_error end
        return {kind = "enum", values = values}, nil
    end
    local kind = bounds.member(object.kind, {"enum", "text"})
    if not kind then return nil, "profile_options." .. name .. ".kind must be enum or text" end
    if kind == "enum" then
        local extra = bounds.fields(object, {"kind", "values"})
        if extra then return nil, "profile_options." .. name .. ": " .. extra end
        local values, values_error = decode_allowed(object.values, name)
        if not values then return nil, values_error end
        return {kind = "enum", values = values}, nil
    end
    local extra = bounds.fields(object, {"kind", "max_bytes"})
    if extra then return nil, "profile_options." .. name .. ": " .. extra end
    local max_bytes = bounds.integer(object.max_bytes)
    if not max_bytes or max_bytes < 1 or max_bytes > M.MAX_OPTION_VALUE_BYTES then
        return nil, "profile_options." .. name .. ".max_bytes must be between 1 and " .. tostring(M.MAX_OPTION_VALUE_BYTES)
    end
    return {kind = "text", max_bytes = max_bytes}, nil
end

local function decode_profile_options(value: unknown): ({[string]: Option}?, string?)
    local object = bounds.object(value == nil and {} or value)
    if not object then return nil, "profile_options must be an object" end
    local result: {[string]: Option} = {}
    local count = 0
    for name, allowed in pairs(object) do
        count = count + 1
        if count > M.MAX_OPTIONS then return nil, "profile_options exceeds " .. tostring(M.MAX_OPTIONS) .. " options" end
        if not option_name(name) then
            if RESERVED_OPTIONS[name] then return nil, "profile_options contains reserved option " .. name end
            return nil, "profile_options contains an invalid option name"
        end
        local option, option_error = decode_option(allowed, name)
        if not option then return nil, option_error end
        result[name] = option
    end
    return result, nil
end

M.decode_profile_options = decode_profile_options

local function instructions(value: unknown, label: string, empty_allowed: boolean): (string?, string?)
    if value == nil then return "", nil end
    local text = bounds.text(value, M.MAX_INSTRUCTIONS_BYTES)
    if not text or (not empty_allowed and text == "") then
        return nil, label .. " must contain at most 4096 bytes"
    end
    for index = 1, #text do
        local byte = text:byte(index)
        if (byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 13) or byte == 127 then
            return nil, label .. " contain unsupported control bytes"
        end
    end
    return text, nil
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
    local unexpected = bounds.fields(object, {"options", "mcp_tools", "instructions"})
    if unexpected then return nil, unexpected end
    local options, options_error = decode_options(object.options == nil and {} or object.options, "options")
    if not options then return nil, options_error end
    local mcp_tools, tools_error = dense_tools(object.mcp_tools, "mcp_tools")
    if not mcp_tools then return nil, tools_error end
    local text, instructions_error = instructions(object.instructions, "instructions", true)
    if not text then return nil, instructions_error end
    return {options = options, mcp_tools = mcp_tools, instructions = text}, nil
end

local function allowed_value(values: {Scalar}, selected: Scalar): boolean
    for _, value in ipairs(values) do
        if type(value) == type(selected) and value == selected then return true end
    end
    return false
end

local function allowed_option(option: Option, selected: Scalar): boolean
    if option.kind == "enum" then return allowed_value(option.values, selected) end
    if type(selected) ~= "string" then return false end
    return #selected > 0 and #selected <= option.max_bytes and not selected:find("%c")
end

function M.apply(policy_data: Object, raw: unknown): (Object?, string?)
    local policy = bounds.object(policy_data)
    if not policy then return nil, "policy data must be an object" end
    local saved, saved_error = M.decode(raw)
    if not saved then return nil, saved_error end
    local profile_options, profile_options_error = decode_profile_options(policy.profile_options)
    if not profile_options then return nil, profile_options_error end
    local profile_instructions = policy.profile_instructions
    if profile_instructions == nil then profile_instructions = false end
    if type(profile_instructions) ~= "boolean" then return nil, "profile_instructions must be a boolean" end

    local host_options = bounds.object(policy.prepare_options == nil and {} or policy.prepare_options)
    if not host_options then return nil, "prepare_options must be an object" end
    local prepare_options: {[string]: unknown} = {}
    for name, value in pairs(host_options) do prepare_options[name] = value end
    for name, selected in pairs(saved.options) do
        local allowed = profile_options[name]
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

    local host_instructions, host_instructions_error = instructions(policy.instructions, "host instructions", true)
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
    result.gateway_tools = saved.mcp_tools
    return result, nil
end

return M
