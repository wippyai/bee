-- MIT. Pure saved-agent profile editing for the Agent form.
--
-- The editor receives an already decoded profile and an explicit host
-- allowlist. It owns no persistence, registry, process, endpoint, or
-- permission behavior; the allowlist is only used to keep the draft inside
-- the host-selected preference boundary.
local bounds = require("bounds")
local preferences = require("preferences")
local protocol = require("protocol")

local M = {}
M.MAX_TITLE_BYTES = 80
M.MAX_INSTRUCTIONS_BYTES = preferences.MAX_INSTRUCTIONS_BYTES

type Scalar = string | number | boolean
type Profile = {
    title: string,
    definition_ref: string,
    options: {[string]: Scalar},
    mcp_tools: {string},
    instructions: string,
}
type Option = {kind: "enum", values: {Scalar}} | {kind: "text", max_bytes: integer}
type Allowed = {
    options: {[string]: Option},
    mcp_tools: {string},
    instructions: boolean,
}
type Draft = {
    title: string,
    definition_ref: string,
    options: {[string]: Scalar},
    mcp_tools: {string},
    instructions: string,
    -- Kept out of the public result. It is copied at construction and is
    -- consulted on every edit and result validation.
    _allowed: Allowed,
}
type OptionRow = {name: string, kind: "enum" | "text", values: {Scalar}?, max_bytes: integer?, value: Scalar?}
type ToolRow = {name: string, selected: boolean}

local function object(value: unknown): {[string]: unknown}?
    return bounds.object(value)
end

local function scalar_equal(left: Scalar, right: Scalar): boolean
    return type(left) == type(right) and left == right
end

local function policy(allowed: Allowed): {[string]: unknown}
    return {profile_options = allowed.options, gateway_tools = allowed.mcp_tools,
        profile_instructions = allowed.instructions, prepare_options = {}}
end

local function decode_allowed(value: unknown): (Allowed?, string?)
    local raw = object(value)
    if not raw then return nil, "editor allowlist must be an object" end
    local extra = bounds.fields(raw, {"options", "mcp_tools", "instructions"})
    if extra then return nil, "editor allowlist: " .. extra end
    if raw.options == nil or raw.mcp_tools == nil then
        return nil, "editor allowlist needs options and mcp_tools"
    end
    if type(raw.instructions) ~= "boolean" then
        return nil, "editor allowlist.instructions must be a boolean"
    end
    -- preferences.apply owns the shared option, tool and instruction bounds.
    -- An empty candidate validates the host declaration without applying any
    -- caller value to it.
    local candidate, candidate_error = preferences.apply({profile_options = raw.options,
        gateway_tools = raw.mcp_tools, profile_instructions = raw.instructions,
        prepare_options = {}},
        {options = {}, mcp_tools = {}, instructions = ""})
    if not candidate then return nil, candidate_error or "editor allowlist is invalid" end

    local decoded_options, decoded_options_error = preferences.decode_profile_options(raw.options)
    if not decoded_options then return nil, decoded_options_error or "editor options are invalid" end
    local options: {[string]: Option} = {}
    local raw_options = raw.options :: {[string]: unknown}
    for name in pairs(raw_options) do
        local declared = decoded_options[name]
        if not declared then return nil, "editor option declaration is missing" end
        if declared.kind == "enum" then
            local copied: {Scalar} = {}
            for index, item in ipairs(declared.values) do copied[index] = item end
            options[name] = {kind = "enum", values = copied}
        else
            options[name] = {kind = "text", max_bytes = declared.max_bytes}
        end
    end
    local tools: {string} = {}
    for index, tool in ipairs(raw.mcp_tools :: {unknown}) do tools[index] = tool :: string end
    return {options = options, mcp_tools = tools, instructions = raw.instructions :: boolean}, nil
end

local function raw_profile(draft: Draft): {[string]: unknown}
    return {title = draft.title, definition_ref = draft.definition_ref, options = draft.options,
        mcp_tools = draft.mcp_tools, instructions = draft.instructions}
end

local function result_for(draft: Draft): (Profile?, string?)
    if not draft._allowed then return nil, "editor allowlist is missing" end
    local profile, profile_error = protocol.profile(raw_profile(draft))
    if not profile then return nil, profile_error or "profile is invalid" end
    local _, preference_error = preferences.apply(policy(draft._allowed), {
        options = profile.options, mcp_tools = profile.mcp_tools, instructions = profile.instructions,
    })
    if preference_error then return nil, preference_error end
    return profile, nil
end

local function current(draft: Draft): (Profile?, string?)
    return result_for(draft)
end

local function replace(draft: Draft, profile: Profile)
    draft.title = profile.title
    draft.definition_ref = profile.definition_ref
    draft.options = profile.options
    draft.mcp_tools = profile.mcp_tools
    draft.instructions = profile.instructions
end

function M.new(profile: Profile, raw_allowed: unknown): (Draft?, string?)
    local allowed, allowed_error = decode_allowed(raw_allowed)
    if not allowed then return nil, allowed_error end
    local decoded, profile_error = protocol.profile(profile)
    if not decoded then return nil, profile_error or "profile is invalid" end
    local draft: Draft = {title = decoded.title, definition_ref = decoded.definition_ref,
        options = decoded.options, mcp_tools = decoded.mcp_tools, instructions = decoded.instructions,
        _allowed = allowed}
    local _, invalid = result_for(draft)
    if invalid then return nil, invalid end
    return draft, nil
end

function M.set_title(draft: Draft, value: unknown): (boolean, string?)
    local base, base_error = current(draft)
    if not base then return false, base_error end
    local title = bounds.line(value, M.MAX_TITLE_BYTES)
    if not title or title:match("^%s*$") then
        return false, "title must contain 1 to 80 printable bytes"
    end
    -- `current` has already copied and validated every other field. Keep the
    -- assignment direct so the checker retains the protocol's profile type.
    draft.title = title
    return true, nil
end

function M.append_guidance(draft: Draft, value: unknown): (boolean, string?)
    local base, base_error = current(draft)
    if not base then return false, base_error end
    local addition = bounds.text(value, M.MAX_INSTRUCTIONS_BYTES)
    if not addition then return false, "guidance must contain at most 4096 bytes" end
    local joined = base.instructions
    if addition ~= "" then
        if joined == "" then joined = addition else joined = joined .. "\n\n" .. addition end
    end
    if #joined > M.MAX_INSTRUCTIONS_BYTES then
        return false, "combined guidance must contain at most 4096 bytes"
    end
    base.instructions = joined
    local checked, checked_error = protocol.profile(raw_profile(base))
    if not checked then return false, checked_error or "guidance is invalid" end
    draft.instructions = checked.instructions
    return true, nil
end

function M.set_guidance(draft: Draft, value: unknown): (boolean, string?)
    local base, base_error = current(draft)
    if not base then return false, base_error end
    local guidance = bounds.text(value, M.MAX_INSTRUCTIONS_BYTES)
    if not guidance then return false, "guidance must contain at most 4096 bytes" end
    base.instructions = guidance
    local checked, checked_error = protocol.profile(raw_profile(base))
    if not checked then return false, checked_error or "guidance is invalid" end
    local _, preference_error = preferences.apply(policy(draft._allowed), {
        options = checked.options, mcp_tools = checked.mcp_tools, instructions = checked.instructions,
    })
    if preference_error then return false, preference_error end
    replace(draft, checked)
    return true, nil
end

function M.set_text_option(draft: Draft, raw_name: unknown, value: unknown): (boolean, string?)
    local base, base_error = current(draft)
    if not base then return false, base_error end
    local name = bounds.id(raw_name)
    if not name then return false, "option name is not an identifier" end
    local declared = draft._allowed.options[name]
    if not declared then return false, "option " .. name .. " is not allowed by the host" end
    if declared.kind ~= "text" then return false, "option " .. name .. " is an enum" end
    local text = bounds.text(value, declared.max_bytes)
    if value == nil or text == "" then
        base.options[name] = nil
    elseif text == nil then
        return false, "option " .. name .. " must contain 1 to " .. tostring(declared.max_bytes) .. " printable bytes"
    elseif text:find("%c") then
        return false, "option " .. name .. " must contain 1 to " .. tostring(declared.max_bytes) .. " printable bytes"
    else
        base.options[name] = text
    end
    local checked, checked_error = protocol.profile(raw_profile(base))
    if not checked then return false, checked_error or "option is invalid" end
    local _, preference_error = preferences.apply(policy(draft._allowed), {
        options = checked.options, mcp_tools = checked.mcp_tools, instructions = checked.instructions,
    })
    if preference_error then return false, preference_error end
    replace(draft, checked)
    return true, nil
end

function M.cycle_option(draft: Draft, raw_name: unknown, raw_direction: number?): (boolean, string?)
    local base, base_error = current(draft)
    if not base then return false, base_error end
    local name = bounds.id(raw_name)
    if not name then return false, "option name is not an identifier" end
    local declared = draft._allowed.options[name]
    if not declared then return false, "option " .. name .. " is not allowed by the host" end
    if declared.kind ~= "enum" then return false, "option " .. name .. " is a text value" end
    local values = declared.values
    local direction_value = raw_direction or 1
    local direction = bounds.integer(direction_value)
    if not direction or direction == 0 then return false, "option direction must be a nonzero integer" end
    local selected = base.options[name]
    local index: integer? = nil
    if selected ~= nil then
        for position, value in ipairs(values) do
            if scalar_equal(value, selected) then index = position; break end
        end
    elseif direction_value < 0 then
        -- An unset option enters at the end when cycling backwards.
        index = 1
    else
        -- An unset option enters at the beginning when cycling forwards.
        index = 0
    end
    if not index then return false, "option " .. name .. " has a value that is not allowed by the host" end
    local next_index: integer = ((index - 1 + direction_value) % #values) + 1
    local next_value = values[next_index]
    if next_value == nil then return false, "option " .. name .. " has no next value" end
    base.options[name] = next_value
    draft.options = base.options
    return true, nil
end

function M.toggle_tool(draft: Draft, raw_tool: unknown): (boolean, string?)
    local base, base_error = current(draft)
    if not base then return false, base_error end
    local tool = bounds.id(raw_tool)
    if not tool then return false, "MCP tool is not an identifier" end
    local allowed = false
    for _, candidate in ipairs(draft._allowed.mcp_tools) do
        if candidate == tool then allowed = true; break end
    end
    if not allowed then return false, "MCP tool is not allowed by the host" end
    for index, selected in ipairs(base.mcp_tools) do
        if selected == tool then
            table.remove(base.mcp_tools, index)
            draft.mcp_tools = base.mcp_tools
            return true, nil
        end
    end
    base.mcp_tools[#base.mcp_tools + 1] = tool
    draft.mcp_tools = base.mcp_tools
    return true, nil
end

function M.options(draft: Draft): ({OptionRow}?, string?)
    local base, base_error = current(draft)
    if not base then return nil, base_error end
    local rows: {OptionRow} = {}
    for name, declared in pairs(draft._allowed.options) do
        if declared.kind == "enum" then
            local copied: {Scalar} = {}
            for index, value in ipairs(declared.values) do copied[index] = value end
            rows[#rows + 1] = {name = name, kind = "enum", values = copied, max_bytes = nil, value = base.options[name]}
        else
            rows[#rows + 1] = {name = name, kind = "text", values = nil, max_bytes = declared.max_bytes, value = base.options[name]}
        end
    end
    table.sort(rows, function(left: OptionRow, right: OptionRow): boolean return left.name < right.name end)
    return rows, nil
end

function M.tools(draft: Draft): ({ToolRow}?, string?)
    local base, base_error = current(draft)
    if not base then return nil, base_error end
    local selected: {[string]: boolean} = {}
    for _, tool in ipairs(base.mcp_tools) do selected[tool] = true end
    local rows: {ToolRow} = {}
    for _, tool in ipairs(draft._allowed.mcp_tools) do
        rows[#rows + 1] = {name = tool, selected = selected[tool] == true}
    end
    table.sort(rows, function(left: ToolRow, right: ToolRow): boolean return left.name < right.name end)
    return rows, nil
end

function M.result(draft: Draft): (Profile?, string?)
    return result_for(draft)
end

return M
