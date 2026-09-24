-- MIT. Load and save Agent form values through the existing profile authority.
-- Saving preferences never starts a harness or creates a thread.
local funcs = require("funcs")
local uuid = require("uuid")
local bounds = require("bounds")
local catalog = require("catalog")
local definition = require("definition")
local protocol = require("protocol")
local editor = require("editor")
local selection = require("selection")
local M = {}
type Form = {workspace_id: string, profile_id: string, revision: integer, draft: editor.Draft,
    save_key: string, remove_key: string, pending: string?, submitted: protocol.Profile?}

local function call(request: unknown): ({[string]: unknown}?, string?)
    local raw, err = funcs.call("bee.harness.profiles:call", request)
    if err then return nil, tostring(err) end
    local reply = bounds.object(raw)
    if not reply then return nil, "Profile store returned an invalid reply" end
    if reply.ok ~= true then
        local code = bounds.id(reply.code) or "UNAVAILABLE"
        return nil, code .. ": " .. (bounds.text(reply.message, 512) or "Profile operation refused")
    end
    local value = bounds.object(reply.value)
    if not value then return nil, "Profile store returned no value" end
    return value, nil
end

function M.load(workspace: string, choice: selection.Choice, duplicate: boolean): (Form?, string?)
    local pinned = catalog.pin()
    if not pinned then return nil, "Agent definitions could not be read" end
    local entry = catalog.entry(pinned, choice.definition_ref)
    if not entry then return nil, "Agent definition is no longer available" end
    local decoded, decode_error = definition.decode(choice.definition_ref, entry)
    if not decoded then return nil, decode_error end
    local policy_entry = catalog.entry(pinned, decoded.policy_ref)
    local policy_data = policy_entry and bounds.object(policy_entry.data) or nil
    if not policy_data then return nil, "Agent policy could not be read" end
    local tools, tools_error = bounds.ids(policy_data.gateway_tools or {}, true)
    if not tools then return nil, tools_error end
    local profile: protocol.Profile = {title = choice.title, definition_ref = choice.definition_ref,
        options = {}, mcp_tools = tools, instructions = ""}
    local id, revision = choice.saved_profile_id or "", choice.saved_profile_revision or 0
    if choice.saved_profile_id then
        local saved, read_error = call({operation = "get", workspace_id = workspace, profile_id = id})
        if not saved then return nil, read_error end
        if saved.workspace_id ~= workspace or saved.profile_id ~= id or saved.revision ~= revision or saved.tombstone ~= false then
            return nil, "Profile changed. Refresh and select it again."
        end
        local value, value_error = protocol.profile(saved.profile)
        if not value then return nil, value_error end
        if value.definition_ref ~= choice.definition_ref then return nil, "Profile definition changed" end
        profile = value
    end
    if duplicate or id == "" then
        local fresh, fresh_error = uuid.v7()
        if not fresh then return nil, tostring(fresh_error) end
        id, revision = fresh, 0
    end
    -- A folder or thread choice is offered only where the definition and its
    -- launch policy both allow the override; admission checks it again.
    local admitted = bounds.ids(policy_data.allowed_overrides or {}, true) or {}
    local function allows(name: string): boolean
        return definition.allows(decoded, name) and bounds.member(name, admitted) ~= nil
    end
    local draft, draft_error = editor.new(profile, {options = policy_data.profile_options or {},
        mcp_tools = tools, instructions = policy_data.profile_instructions == true, workdir = allows("workdir"), thread = allows("thread")})
    if not draft then return nil, draft_error end
    local save_key, save_error = uuid.v7()
    local remove_key, remove_error = uuid.v7()
    if not save_key or not remove_key then return nil, tostring(save_error or remove_error) end
    return {workspace_id = workspace, profile_id = id, revision = revision, draft = draft,
        save_key = save_key, remove_key = remove_key}, nil
end

function M.save(form: Form): (boolean, string?)
    if form.pending == "remove" then return false, "Resolve profile removal before saving" end
    local profile, err = editor.result(form.draft)
    if form.submitted then profile = form.submitted end
    if not profile then return false, err end
    form.pending, form.submitted = "save", profile
    local saved, save_error = call({operation = "put", workspace_id = form.workspace_id,
        profile_id = form.profile_id, expected_revision = form.revision, idempotency_key = form.save_key, profile = profile})
    if not saved then return false, save_error end
    if saved.workspace_id ~= form.workspace_id or saved.profile_id ~= form.profile_id
        or saved.revision ~= form.revision + 1 or saved.tombstone ~= false then
        return false, "Profile save returned an unexpected identity"
    end
    return true, nil
end

function M.remove(form: Form): (boolean, string?)
    if form.pending == "save" then return false, "Resolve profile saving before removing" end
    if form.revision < 1 then return false, "This profile has not been saved" end
    form.pending = "remove"
    local saved, err = call({operation = "remove", workspace_id = form.workspace_id,
        profile_id = form.profile_id, expected_revision = form.revision, idempotency_key = form.remove_key})
    if not saved then return false, err end
    if saved.workspace_id ~= form.workspace_id or saved.profile_id ~= form.profile_id
        or saved.revision ~= form.revision + 1 or saved.tombstone ~= true then
        return false, "Profile removal returned an unexpected identity"
    end
    return true, nil
end
return M
