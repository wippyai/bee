-- MIT. Window-profile discovery from one immutable registry snapshot.
-- Choices contain presentation and measured identities only. Discovery never
-- creates work or grants launch authority; admission checks the chosen plan.
local catalog = require("catalog")
local definitions = require("definitions")
local admission = require("admission")
local bounds = require("bounds")
local policy = require("policy")
local profiles = require("profiles")
local funcs = require("funcs")
local registry = require("registry")
local M = {}
M.MAX_DEFINITIONS = 64
M.MAX_PROFILE_PAGES = 64
local PROFILE_CALL = "bee.harness.profiles:call"
type Choice = {definition_ref: string, title: string, launch_id: string, plan_digest: string, unavailable: string?, summary: string?, saved_profile_id: string?, saved_profile_revision: integer?}
type Choices = {items: {Choice}, unavailable: integer}
type Command = {definition_ref: string, fullscreen: boolean}

-- Command names are contributed by launch definitions, so installing a
-- harness can add a CLI route without changing the Terminal or Agent app.
-- This only resolves the declaration. The Agent actor resolves and fences the
-- measured plan again before setup or admission creates any work.
function M.command(name: string): (Command?, string?)
    if not bounds.id(name) or #name > 40 or not name:match("^[a-z][a-z0-9_-]*$") then
        return nil, "Invalid Bee command"
    end
    local found, find_error = registry.find({["meta.type"] = definitions.TYPE})
    if find_error or not found then return nil, "Agent commands could not be read" end
    if #found > M.MAX_DEFINITIONS then return nil, "Too many Agent commands to resolve" end
    local selected: Command? = nil
    for _, raw in ipairs(found) do
        local entry = bounds.object(raw)
        local ref = entry and bounds.id(entry.id) or nil
        local definition = entry and ref and definitions.decode(ref, entry) or nil
        if definition then
            for _, command in ipairs(definition.command_names) do
                if command == name then
                    if definition.default_mode ~= "window" then
                        return nil, "Bee command " .. name .. " does not select a window profile"
                    end
                    if selected then return nil, "Ambiguous Bee command: " .. name end
                    selected = {definition_ref = definition.ref, fullscreen = definition.presentation.fullscreen}
                end
            end
        end
    end
    return selected, nil
end

function M.read(pinned: catalog.Pinned): (Choices?, string?)
    local found, find_error = pinned:find({["meta.type"] = definitions.TYPE})
    if find_error or not found then return nil, "Agent profiles could not be read" end
    if #found > M.MAX_DEFINITIONS then return nil, "Too many agent profiles to list" end
    local result: Choices = {items = {}, unavailable = 0}
    for _, raw in ipairs(found) do
        local entry = bounds.object(raw)
        local ref = entry and bounds.id(entry.id) or nil
        if entry and ref then
            local definition = definitions.decode(ref, entry)
            if not definition then
                result.unavailable = result.unavailable + 1
            elseif definition.presentation.start_menu and definition.default_mode == "window" then
                local plan, refused = admission.read(pinned, ref, "window")
                if plan then
                    local policy_entry = catalog.entry(pinned, definition.policy_ref)
                    if not policy_entry then return nil, "Selected profile policy could not be read" end
                    local selected_policy, policy_error = policy.decode(definition.policy_ref, policy_entry)
                    if not selected_policy then return nil, policy_error or "Selected profile policy is invalid" end
                    local location = definition.workdir_policy.kind == "caller_workspace" and "Project folder" or
                        (definition.workdir_policy.kind == "declared_resource" and "Configured folder" or "Directory required")
                    local guidance = (selected_policy.instructions or selected_policy.instruction_builder) and "Profile instructions" or "No instructions"
                    local tools = #selected_policy.gateway_tools
                    local summary = location .. " · " .. guidance .. " · " .. tostring(tools) .. " tools configured"
                    result.items[#result.items + 1] = {definition_ref = ref, title = definition.title,
                        launch_id = definition.launch_id, plan_digest = plan.plan_digest, summary = summary}
                else
                    result.unavailable = result.unavailable + 1
                    local fault = refused and refused.error
                    result.items[#result.items + 1] = {definition_ref = ref, title = definition.title,
                        launch_id = definition.launch_id, plan_digest = "",
                        unavailable = fault and fault.message or "Profile is unavailable on this node"}
                end
            end
        else
            result.unavailable = result.unavailable + 1
        end
    end
    table.sort(result.items, function(left: Choice, right: Choice): boolean
        if left.title ~= right.title then return left.title < right.title end
        return left.definition_ref < right.definition_ref
    end)
    return result, nil
end
function M.snapshot(workspace_id: string?): (Choices?, string?)
    if workspace_id ~= nil then return M.workspace(workspace_id) end
    local pinned = catalog.pin()
    if not pinned then return nil, "Agent profiles could not be read" end
    return M.read(pinned)
end

type ProfileRow = {workspace_id: string, profile_id: string, revision: integer, tombstone: boolean, profile: profiles.Profile?}
type ProfilePage = {workspace_id: string, items: {ProfileRow}, cursor: integer, next_key: string?, complete: boolean}

local function workspace_failure(defaults: Choices, message: string): (Choices?, string?)
    return defaults, "Saved profiles could not be read: " .. message
end

local function fault_message(reply: {[string]: unknown}): string
    local code = bounds.id(reply.code)
    local message = bounds.text(reply.message, 512)
    if code and message then return code .. ": " .. message end
    if code then return code end
    return "profile store returned an invalid refusal"
end

local function dense_rows(value: unknown): {unknown}?
    if type(value) ~= "table" then return nil end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then return nil end
        count = count + 1
    end
    local rows: {unknown} = {}
    for index = 1, count do
        if value[index] == nil then return nil end
        rows[index] = value[index]
    end
    return rows
end

local function decode_row(workspace: string, raw: unknown): (ProfileRow?, string?)
    local object = bounds.object(raw)
    if not object then return nil, "profile snapshot row is not an object" end
    local extra = bounds.fields(object, {"workspace_id", "profile_id", "revision", "tombstone", "profile"})
    if extra then return nil, "profile snapshot row: " .. extra end
    local row_workspace, profile_id, revision = bounds.id(object.workspace_id), bounds.id(object.profile_id), bounds.count(object.revision)
    if not row_workspace or not profile_id or not revision or revision < 1 then return nil, "profile snapshot row identity is invalid" end
    if row_workspace ~= workspace then return nil, "profile snapshot row belongs to another workspace" end
    if type(object.tombstone) ~= "boolean" then return nil, "profile snapshot row tombstone is invalid" end
    if object.tombstone then
        if object.profile ~= nil then return nil, "profile tombstone contains a value" end
        return {workspace_id = row_workspace, profile_id = profile_id, revision = revision, tombstone = true, profile = nil}, nil
    end
    if object.profile == nil then return nil, "profile snapshot row has no profile" end
    local profile, profile_error = profiles.profile(object.profile)
    if not profile then return nil, profile_error or "profile snapshot value is invalid" end
    return {workspace_id = row_workspace, profile_id = profile_id, revision = revision, tombstone = false, profile = profile}, nil
end

local function decode_page(workspace: string, raw: unknown, expected_limit: integer, expected_cursor: integer?, previous_key: string?): (ProfilePage?, string?)
    local object = bounds.object(raw)
    if not object then return nil, "profile snapshot is not an object" end
    local extra = bounds.fields(object, {"workspace_id", "items", "cursor", "next_key", "complete"})
    if extra then return nil, "profile snapshot: " .. extra end
    local page_workspace, cursor = bounds.id(object.workspace_id), bounds.count(object.cursor)
    local complete = object.complete
    if not page_workspace or page_workspace ~= workspace then return nil, "profile snapshot belongs to another workspace" end
    if not cursor or type(complete) ~= "boolean" then return nil, "profile snapshot envelope is invalid" end
    if expected_cursor ~= nil and cursor ~= expected_cursor then return nil, "profile snapshot cursor changed" end
    local raw_rows = dense_rows(object.items)
    if not raw_rows then return nil, "profile snapshot items are not a dense list" end
    if #raw_rows > expected_limit or #raw_rows > M.MAX_DEFINITIONS then return nil, "profile snapshot page exceeds its bound" end
    local rows: {ProfileRow} = {}
    local last_key = previous_key
    for _, raw_row in ipairs(raw_rows) do
        local row, row_error = decode_row(workspace, raw_row)
        if not row then return nil, row_error end
        if last_key and row.profile_id <= last_key then return nil, "profile snapshot keys are not strictly ordered" end
        rows[#rows + 1] = row
        last_key = row.profile_id
    end
    local next_key: string? = nil
    if complete then
        if object.next_key ~= nil then return nil, "complete profile snapshot has a continuation" end
    else
        next_key = bounds.id(object.next_key)
        if not next_key or #rows == 0 or next_key ~= rows[#rows].profile_id then
            return nil, "profile snapshot continuation is invalid"
        end
    end
    return {workspace_id = page_workspace, items = rows, cursor = cursor, next_key = next_key, complete = complete}, nil
end

local function plan_digest(plan: unknown, definition_ref: string, profile_id: string, revision: integer): string?
    local object = bounds.object(plan)
    if not object or object.definition_ref ~= definition_ref or object.mode ~= "window"
        or object.saved_profile_id ~= profile_id or object.saved_profile_revision ~= revision then return nil end
    local digest = bounds.text(object.plan_digest, 64)
    if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return nil end
    return digest
end

local function saved_choice(pinned: catalog.Pinned, workspace: string, row: ProfileRow): (Choice?, string?)
    if row.tombstone or not row.profile then return nil, nil end
    local profile = row.profile
    local definition_ref = profile.definition_ref
    local entry = catalog.entry(pinned, definition_ref)
    if not entry then return nil, nil end
    local definition, definition_error = definitions.decode(definition_ref, entry)
    if not definition then return nil, nil end
    if definition.default_mode ~= "window" or not definition.presentation.start_menu then return nil, nil end
    local plan, refused = admission.resolve(definition_ref, "window", workspace, row.profile_id, row.revision)
    local digest = plan_digest(plan, definition_ref, row.profile_id, row.revision)
    local detail = "Saved profile · " .. definition.title
    if profile.config_profile then detail = detail .. " · Codex " .. profile.config_profile end
    if digest then
        return {definition_ref = definition_ref, title = profile.title, launch_id = definition.launch_id, plan_digest = digest,
            saved_profile_id = row.profile_id, saved_profile_revision = row.revision, summary = detail}, nil
    end
    local reason = "Profile is unavailable on this node"
    if refused then
        local fault = bounds.object(refused.error)
        if fault then
            local message = bounds.text(fault.message, 512)
            if message then reason = message end
        end
    end
    return {definition_ref = definition_ref, title = profile.title, launch_id = definition.launch_id, plan_digest = "",
        unavailable = reason, saved_profile_id = row.profile_id, saved_profile_revision = row.revision,
        summary = detail}, nil
end

-- Extends the registry defaults with authorized, workspace-scoped saved
-- profiles. The store cursor pins one snapshot; malformed or changing pages
-- are refused without exposing partial saved state.
function M.workspace(workspace_id: string): (Choices?, string?)
    local workspace = bounds.id(workspace_id)
    if not workspace then return nil, "workspace_id must be an identifier" end
    local pinned, pin_error = catalog.pin()
    if not pinned then return nil, "Agent profiles could not be read" end
    local defaults, defaults_error = M.read(pinned)
    if not defaults then return nil, defaults_error or "Agent profiles could not be read" end
    local rows: {ProfileRow} = {}
    local seen: {[string]: boolean} = {}
    local after_key = ""
    local expected_cursor: integer? = nil
    local pages = 0
    while true do
        pages = pages + 1
        if pages > M.MAX_PROFILE_PAGES then return workspace_failure(defaults, "profile snapshot has too many pages") end
        local request: {[string]: unknown} = {operation = "list", workspace_id = workspace, limit = M.MAX_DEFINITIONS}
        if after_key ~= "" then request.after_key = after_key; request.expected_cursor = expected_cursor end
        local raw, call_error = funcs.call(PROFILE_CALL, request)
        if call_error then return workspace_failure(defaults, tostring(call_error)) end
        local reply = bounds.object(raw)
        if not reply or reply.ok ~= true then
            return workspace_failure(defaults, reply and fault_message(reply) or "profile store returned an invalid reply")
        end
        local page, page_error = decode_page(workspace, reply.value, M.MAX_DEFINITIONS, expected_cursor, after_key ~= "" and after_key or nil)
        if not page then return workspace_failure(defaults, page_error or "invalid profile snapshot") end
        expected_cursor = expected_cursor or page.cursor
        for _, row in ipairs(page.items) do
            if seen[row.profile_id] then return workspace_failure(defaults, "profile snapshot repeats a profile") end
            seen[row.profile_id] = true
            rows[#rows + 1] = row
        end
        if page.complete then break end
        after_key = page.next_key :: string
    end
    local merged: Choices = {items = {}, unavailable = defaults.unavailable}
    for _, item in ipairs(defaults.items) do merged.items[#merged.items + 1] = item end
    for _, row in ipairs(rows) do
        local choice = saved_choice(pinned, workspace, row)
        if choice then
            if #merged.items >= M.MAX_DEFINITIONS then return workspace_failure(defaults, "too many agent profiles to list") end
            merged.items[#merged.items + 1] = choice
            if choice.unavailable then merged.unavailable = merged.unavailable + 1 end
        end
    end
    table.sort(merged.items, function(left: Choice, right: Choice): boolean
        if left.title ~= right.title then return left.title < right.title end
        if left.definition_ref ~= right.definition_ref then return left.definition_ref < right.definition_ref end
        return (left.saved_profile_id or "") < (right.saved_profile_id or "")
    end)
    return merged, nil
end
return M
