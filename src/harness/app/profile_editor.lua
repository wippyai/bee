-- MIT. Pure saved-agent profile editing for the Agent form.
--
-- The editor receives an already decoded profile and an explicit host
-- allowlist. It owns no persistence, registry, process, endpoint, or
-- permission behavior; the allowlist is only used to keep the draft inside
-- the host-selected preference boundary.
local bounds = require("bounds")
local preferences = require("preferences")
local protocol = require("protocol")
local budgets = require("budgets")

local json = require("json")
local canonical = require("canonical")
local M = {}
M.MAX_TITLE_BYTES = 80
M.MAX_INSTRUCTIONS_BYTES = preferences.MAX_INSTRUCTIONS_BYTES

type Scalar = string | number | boolean
type Profile = protocol.Profile
type Option = {kind: "enum", values: {Scalar}} | {kind: "text", max_bytes: integer} | {kind: "declared"}
-- workdir and thread: whether the launch admits choosing a folder and a
-- thread, as its definition and launch policy allow the override.
type Allowed = {
    options: {[string]: Option},
    mcp_tools: {string},
    instructions: boolean,
    workdir: boolean,
    thread: boolean,
    placements: {string}?,
    host_home: boolean?,
}
type Draft = {schema_revision: string, definition_ref: string, driver_binding_ref: string, name: string,
    provider: protocol.Provider, bee: protocol.Bee, placement: protocol.Placement?, presentation: "headless" | "window"?,
    budgets: budgets.Budgets?, supervision: budgets.Supervision?,
    workdir: protocol.Workdir?, thread: protocol.Thread?, agent_ref: string?, owner_component_revision: integer?, spec_digest: string?,
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
    return {profile_restrictions = preferences.restriction_paths(allowed.options), gateway_tools = allowed.mcp_tools,
        profile_instructions = allowed.instructions, prepare_options = {}}
end

local function decode_allowed(value: unknown): (Allowed?, string?)
    local raw = object(value)
    if not raw then return nil, "editor allowlist must be an object" end
    local extra = bounds.fields(raw, {"options", "mcp_tools", "instructions", "workdir", "thread", "placements", "host_home"})
    if extra then return nil, "editor allowlist: " .. extra end
    if raw.options == nil or raw.mcp_tools == nil then
        return nil, "editor allowlist needs options and mcp_tools"
    end
    if type(raw.instructions) ~= "boolean" then
        return nil, "editor allowlist.instructions must be a boolean"
    end
    if (raw.workdir ~= nil and type(raw.workdir) ~= "boolean") or (raw.thread ~= nil and type(raw.thread) ~= "boolean") then
        return nil, "editor allowlist.workdir and thread must be booleans"
    end
    -- preferences.apply owns the shared option, tool and instruction bounds.
    -- An empty candidate validates the host declaration without applying any
    -- caller value to it.
    local candidate, candidate_error = preferences.apply({profile_restrictions = preferences.restriction_paths(raw.options),
        gateway_tools = raw.mcp_tools, profile_instructions = raw.instructions,
        prepare_options = {}},
        {options = {}, mcp_tools = {}, instructions = ""})
    if not candidate then return nil, candidate_error or "editor allowlist is invalid" end

    local decoded_options, decoded_options_error = preferences.decode_profile_restrictions(preferences.restriction_paths(raw.options))
    if not decoded_options then return nil, decoded_options_error or "editor options are invalid" end
    local options: {[string]: Option} = {}
    local raw_options = raw.options
    for name in pairs(raw_options) do
        local declared = decoded_options[preferences.path(name)]
        if not declared then return nil, "editor option declaration is missing" end
        if declared.kind == "enum" then
            local copied: {Scalar} = {}
            for index, item in ipairs(declared.values) do copied[index] = item end
            options[name] = {kind = "enum", values = copied}
        elseif declared.kind == "text" then
            options[name] = {kind = "text", max_bytes = declared.max_bytes}
        else options[name] = {kind = "declared"} end
    end
    local tools: {string} = {}
    for index, tool in ipairs(raw.mcp_tools) do tools[index] = tool end
    local placements, placements_error = bounds.ids(raw.placements or {}, true)
    if not placements then return nil, placements_error end
    return {placements = placements, host_home = raw.host_home == true, options = options, mcp_tools = tools, instructions = raw.instructions,
        workdir = raw.workdir == true, thread = raw.thread == true}, nil
end

local function raw_profile(draft: Profile): {[string]: unknown}
    return {schema_revision = draft.schema_revision, name = draft.name, definition_ref = draft.definition_ref,
        driver_binding_ref = draft.driver_binding_ref, provider = draft.provider, bee = draft.bee, placement = draft.placement,
        presentation = draft.presentation, budgets = draft.budgets, supervision = draft.supervision,
        workdir = draft.workdir, thread = draft.thread, agent_ref = draft.agent_ref,
        owner_component_revision = draft.owner_component_revision, spec_digest = draft.spec_digest}
end
local function preference(profile: Profile): {[string]: unknown}
    return protocol.preferences(profile) or {}
end
local function option_value(provider: protocol.Provider, name: string): Scalar?
    if name == "model" then return provider.model end
    if name == "effort" then return provider.effort end
    if name == "permission_mode" then return provider.permission_mode end
    if name == "tool_allow" then return provider.tool_allow and canonical.encode(provider.tool_allow) end
    if name == "tool_deny" then return provider.tool_deny and canonical.encode(provider.tool_deny) end
    if name == "env" then return provider.env and canonical.encode(provider.env) end
    local value = (provider.options or {})[name]
    if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then return value end
    if type(value) == "table" then return canonical.encode(value) end
    return nil
end
local function set_option(provider: protocol.Provider, name: string, value: Scalar?)
    local text = type(value) == "string" and value or nil
    if name == "model" then provider.model = text
    elseif name == "effort" then provider.effort = text
    elseif name == "permission_mode" then provider.permission_mode = text
    else
        provider.options = provider.options or {}
        provider.options[name] = value
    end
end
function M.placement_ref(profile: Profile): string?
    local placement = profile.placement
    if not placement then return nil end
    if placement.kind == "native" then return "bee.placement.profiles:native" end
    return placement.profile_ref
end
local function result_for(draft: Draft): (Profile?, string?)
    if not draft._allowed then return nil, "editor allowlist is missing" end
    local profile, profile_error = protocol.profile(raw_profile(draft))
    if not profile then return nil, profile_error or "profile is invalid" end
    if M.placement_ref(profile) and not bounds.member(M.placement_ref(profile), draft._allowed.placements or {}) then return nil, "this launch does not admit that placement profile" end
    if profile.placement and profile.placement.kind == "native" and profile.placement.home == "machine" and not draft._allowed.host_home then return nil, "Machine home is not admitted by this host" end
    if profile.workdir and not draft._allowed.workdir then return nil, "this launch does not allow choosing a folder" end
    if profile.thread and not draft._allowed.thread then return nil, "this launch does not allow choosing a thread" end
    local _, preference_error = preferences.apply(policy(draft._allowed), preference(profile))
    if preference_error then return nil, preference_error end
    return profile, nil
end

local function current(draft: Draft): (Profile?, string?)
    return result_for(draft)
end

local function replace(draft: Draft, profile: Profile)
    draft.name, draft.definition_ref, draft.driver_binding_ref = profile.name, profile.definition_ref, profile.driver_binding_ref
    draft.provider, draft.bee, draft.placement = profile.provider, profile.bee, profile.placement
    draft.workdir, draft.thread = profile.workdir, profile.thread
    draft.presentation, draft.budgets, draft.supervision = profile.presentation, profile.budgets, profile.supervision
    draft.agent_ref, draft.owner_component_revision, draft.spec_digest = profile.agent_ref, profile.owner_component_revision, profile.spec_digest
end
function M.new(profile: Profile, raw_allowed: unknown): (Draft?, string?)
    local allowed, allowed_error = decode_allowed(raw_allowed)
    if not allowed then return nil, allowed_error end
    local decoded, profile_error = protocol.profile(profile)
    if not decoded then return nil, profile_error end
    local draft: Draft = {schema_revision = decoded.schema_revision, name = decoded.name,
        definition_ref = decoded.definition_ref, driver_binding_ref = decoded.driver_binding_ref,
        provider = decoded.provider, bee = decoded.bee, placement = decoded.placement,
        presentation = decoded.presentation, budgets = decoded.budgets, supervision = decoded.supervision,
        workdir = decoded.workdir, thread = decoded.thread, agent_ref = decoded.agent_ref,
        owner_component_revision = decoded.owner_component_revision, spec_digest = decoded.spec_digest, _allowed = allowed}
    local checked, checked_error = result_for(draft)
    if not checked then return nil, checked_error end
    return draft, nil
end

function M.cycle_home(draft: Draft): (boolean, string?)
    local placement = draft.placement
    if placement and placement.kind ~= "native" then return false, "Home selection requires native placement" end
    if not draft._allowed.host_home then return false, "Machine home is not admitted by this host" end
    draft.placement = {kind = "native", home = placement and placement.home == "machine" and "private" or "machine"}
    return true, nil
end
function M.cycle_placement(draft: Draft, delta: integer): (boolean, string?)
    local choices = draft._allowed.placements or {}
    if #choices == 0 then return false, "this launch admits no placement choices" end
    local selected = 0
    for index, choice in ipairs(choices) do if choice == M.placement_ref(draft) then selected = index end end
    selected = math.floor(((selected + delta - 1) % #choices) + 1)
    local ref = choices[selected]
    if ref == "bee.placement.profiles:native" then draft.placement = {kind = "native", home = "private"}
    else draft.placement = {kind = "docker", profile_ref = ref} end
    return true, nil
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
    draft.name = title
    return true, nil
end

function M.append_guidance(draft: Draft, value: unknown): (boolean, string?)
    local base, base_error = current(draft)
    if not base then return false, base_error end
    local addition = bounds.text(value, M.MAX_INSTRUCTIONS_BYTES)
    if not addition then return false, "guidance must contain at most 4096 bytes" end
    local joined = base.provider.system_prompt_append or ""
    if addition ~= "" then
        if joined == "" then joined = addition else joined = joined .. "\n\n" .. addition end
    end
    if #joined > M.MAX_INSTRUCTIONS_BYTES then
        return false, "combined guidance must contain at most 4096 bytes"
    end
    base.provider.system_prompt_append = joined
    local checked, checked_error = protocol.profile(raw_profile(base))
    if not checked then return false, checked_error or "guidance is invalid" end
    draft.provider.system_prompt_append = checked.provider.system_prompt_append
    return true, nil
end

function M.set_guidance(draft: Draft, value: unknown): (boolean, string?)
    local base, base_error = current(draft)
    if not base then return false, base_error end
    local guidance = bounds.text(value, M.MAX_INSTRUCTIONS_BYTES)
    if not guidance then return false, "guidance must contain at most 4096 bytes" end
    base.provider.system_prompt_append = guidance
    local checked, checked_error = protocol.profile(raw_profile(base))
    if not checked then return false, checked_error or "guidance is invalid" end
    local _, preference_error = preferences.apply(policy(draft._allowed), preference(checked))
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
    if declared.kind == "declared" then
        local text = bounds.text(value, 8192)
        if not text then return false, "option " .. name .. " requires bounded JSON" end
        local decoded: unknown = nil
        if text ~= "" then
            local err: unknown = nil
            decoded, err = json.decode(text)
            if err or decoded == nil then return false, "option " .. name .. " requires JSON" end
        end
        local raw: {[string]: unknown} = {}
        for key, item in pairs(base.provider) do raw[key] = item end
        if bounds.member(name, {"tool_allow", "tool_deny", "env"}) then raw[name] = decoded
        else
            local options: {[string]: unknown} = {}
            for key, item in pairs(base.provider.options or {}) do options[key] = item end
            options[name] = decoded; raw.options = options
        end
        local provider, err = protocol.provider(raw)
        if not provider then return false, err end
        base.provider = provider
        draft.provider = provider
        return true, nil
    end
    if declared.kind ~= "text" then return false, "option " .. name .. " is an enum" end
    local text = bounds.text(value, declared.max_bytes)
    if value == nil or text == "" then
        set_option(base.provider, name, nil)
    elseif text == nil then
        return false, "option " .. name .. " must contain 1 to " .. tostring(declared.max_bytes) .. " printable bytes"
    elseif text:find("%c") then
        return false, "option " .. name .. " must contain 1 to " .. tostring(declared.max_bytes) .. " printable bytes"
    else
        set_option(base.provider, name, text)
    end
    local checked, checked_error = protocol.profile(raw_profile(base))
    if not checked then return false, checked_error or "option is invalid" end
    local _, preference_error = preferences.apply(policy(draft._allowed), preference(checked))
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
    local selected = option_value(base.provider, name)
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
    set_option(base.provider, name, next_value)
    draft.provider = assert(base.provider)
    return true, nil
end

function M.toggle_tool(draft: Draft, tool: string): (boolean, string?)
    if not bounds.member(tool, draft._allowed.mcp_tools) then return false, "MCP tool is not allowed by the host" end
    local mcp = draft.bee.mcp or {}
    for index, item in ipairs(mcp) do
        if item.tool == tool then table.remove(mcp, index); draft.bee.mcp = mcp; return true, nil end
    end
    mcp[#mcp + 1] = {tool = tool, scope = {}}
    draft.bee.mcp = mcp
    return true, nil
end

type OptionSortKey = {name: string}
local function option_order(left: OptionSortKey, right: OptionSortKey): boolean
    return left.name < right.name
end

function M.options(draft: Draft): ({OptionRow}?, string?)
    local base, base_error = current(draft)
    if not base then return nil, base_error end
    local rows: {OptionRow} = {}
    for name, declared in pairs(draft._allowed.options) do
        if declared.kind == "enum" then
            local copied: {Scalar} = {}
            for index, value in ipairs(declared.values) do copied[index] = value end
            rows[#rows + 1] = {name = name, kind = "enum", values = copied, max_bytes = nil, value = option_value(base.provider, name)}
        else
            local value = option_value(base.provider, name)
            if declared.kind == "declared" and name ~= "tool_allow" and name ~= "tool_deny" and name ~= "env" then
                local raw = (base.provider.options or {})[name]
                if raw ~= nil then value = canonical.encode(raw) end
            end
            rows[#rows + 1] = {name = name, kind = "text", values = nil, max_bytes = declared.kind == "text" and declared.max_bytes or 8192, value = value}
        end
    end
    table.sort(rows, option_order)
    return rows, nil
end

function M.tools(draft: Draft): ({ToolRow}?, string?)
    local base, base_error = current(draft)
    if not base then return nil, base_error end
    local selected: {[string]: boolean} = {}
    for _, item in ipairs(base.bee.mcp or {}) do selected[item.tool] = true end
    local rows: {ToolRow} = {}
    for _, tool in ipairs(draft._allowed.mcp_tools) do
        rows[#rows + 1] = {name = tool, selected = selected[tool] == true}
    end
    table.sort(rows, function(left: ToolRow, right: ToolRow): boolean return left.name < right.name end)
    return rows, nil
end

-- The folder the launch works in: a path under an admitted root, or nil for
-- the definition's own folder.
function M.set_workdir(draft: Draft, root_ref: string?, path: string?): (boolean, string?)
    local base, base_error = current(draft)
    if not base then return false, base_error end
    if root_ref == nil then
        draft.workdir = nil
        return true, nil
    end
    if not draft._allowed.workdir then return false, "this launch does not allow choosing a folder" end
    base.workdir = {root_ref = root_ref, path = path or ""}
    local checked, checked_error = protocol.profile(raw_profile(base))
    if not checked then return false, checked_error or "folder is invalid" end
    draft.workdir = checked.workdir
    return true, nil
end

-- The thread the launch joins: an existing thread, or nil for a new one.
function M.set_thread(draft: Draft, thread_id: string?): (boolean, string?)
    local base, base_error = current(draft)
    if not base then return false, base_error end
    if thread_id == nil then
        draft.thread = nil
        return true, nil
    end
    if not draft._allowed.thread then return false, "this launch does not allow choosing a thread" end
    base.thread = {thread_id = thread_id}
    local checked, checked_error = protocol.profile(raw_profile(base))
    if not checked then return false, checked_error or "thread is invalid" end
    draft.thread = checked.thread
    return true, nil
end

function M.result(draft: Draft): (Profile?, string?)
    return result_for(draft)
end

return M
