-- MIT. Launch request decoding.
local bounds = require("bounds")
local record_bounds = require("record_bounds")
local definition = require("definition")
local continuation = require("continuation")
local profiles = require("profiles")
local M = {}
M.MAX_BRIEF_BYTES = 16384
type OriginView = {view_id: string, instance_id: string}
type Continuation = {origin_request_id: string, previous_attempt_id: string, thread_id: string, reauthorize: boolean?}
type Request = {overrides: profiles.Overrides?,
    placement_override: profiles.Placement?,
    saved_profile_id: string?,
    saved_profile_revision: integer?,
    owner_component_revision: integer?,
    agent_ref: string?,
    spec_digest: string?,
    request_id: string,
    definition_ref: string,
    workspace_id: string,
    brief: string,
    mode: string?,
    workdir: string?,
    thread_id: string?,
    thread_title: string?,
    placement: string?,
    expected_plan_digest: string?,
    continuation: Continuation?,
    parent_action_id: string?,
    origin_view: OriginView?,
}
function M.decode_request(value: unknown): (Request?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local unknown_field = bounds.fields(object, {"request_id", "definition_ref", "workspace_id", "brief", "overrides", "mode", "workdir", "thread_id", "thread_title", "placement", "placement_override", "expected_plan_digest", "continuation", "saved_profile_id", "saved_profile_revision", "parent_action_id", "origin_view", "agent_ref", "owner_component_revision", "spec_digest"})
    if unknown_field then return nil, unknown_field end
    local spawn_overrides, override_error = profiles.overrides(object.overrides)
    if not spawn_overrides then return nil, override_error end
    local placement_override, placement_error = profiles.placement(object.placement_override)
    if placement_error then return nil, placement_error end
    local request_id, definition_ref, workspace_id = bounds.id(object.request_id), bounds.id(object.definition_ref), bounds.id(object.workspace_id)
    if not request_id then return nil, "request_id is not an identifier" end
    if not definition_ref then return nil, "definition_ref is not an identifier" end
    if not workspace_id then return nil, "workspace_id is not an identifier" end
    local saved_id, saved_revision = bounds.id(object.saved_profile_id), bounds.count(object.saved_profile_revision)
    if object.saved_profile_id ~= nil or object.saved_profile_revision ~= nil then
        if not saved_id or not saved_revision or saved_revision < 1 then return nil, "saved profile needs identity and positive revision" end
        if object.expected_plan_digest == nil then return nil, "saved profile needs the selected launch plan digest" end
    end
    local agent_ref: string? = nil
    if object.agent_ref ~= nil then
        agent_ref = bounds.id(object.agent_ref)
        if not agent_ref then return nil, "agent_ref is not an identifier" end
    end
    local owner_component_revision: integer? = nil
    if object.owner_component_revision ~= nil then
        local count = bounds.count(object.owner_component_revision)
        if not count or count < 1 then return nil, "owner_component_revision must be a positive integer" end
        owner_component_revision = count
    end
    local spec_digest: string? = nil
    if object.spec_digest ~= nil then
        local digest = bounds.text(object.spec_digest, 64)
        if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
            return nil, "spec_digest must be a lowercase SHA-256 hex digest"
        end
        spec_digest = digest
    end
    local brief = bounds.text(object.brief, M.MAX_BRIEF_BYTES)
    if not brief then return nil, "brief must be bounded text" end
    -- The causally parent action, when an agent started this launch. It is
    -- recorded on the child's admitted action and narrows nothing by itself.
    local parent_action_id: string? = nil
    if object.parent_action_id ~= nil then
        parent_action_id = bounds.id(object.parent_action_id)
        if not parent_action_id then return nil, "parent_action_id is not an identifier" end
    end
    local mode: string? = nil
    if object.mode ~= nil then
        mode = bounds.member(object.mode, definition.MODES)
        if not mode then return nil, "mode must be window, session or batch" end
    end
    local workdir: string? = nil
    if object.workdir ~= nil then
        workdir = bounds.id(object.workdir)
        if not workdir then return nil, "workdir is not an identifier" end
    end
    local thread_id: string? = nil
    if object.thread_id ~= nil then
        thread_id = bounds.id(object.thread_id)
        if not thread_id then return nil, "thread_id is not an identifier" end
    end
    -- A new thread under the caller's title, instead of an existing one.
    local thread_title: string? = nil
    if object.thread_title ~= nil then
        thread_title = bounds.line(object.thread_title, record_bounds.MAX_TITLE_BYTES)
        if not thread_title then return nil, "thread_title must be one line of bounded text" end
        if thread_id then return nil, "thread_id and thread_title are exclusive" end
    end
    local placement: string? = nil
    if object.placement ~= nil then
        placement = bounds.id(object.placement)
        if not placement then return nil, "placement is not an identifier" end
    end
    local origin_view: OriginView? = nil
    if object.origin_view ~= nil then
        local declared = bounds.object(object.origin_view)
        if not declared or bounds.fields(declared, {"view_id", "instance_id"}) then return nil, "origin_view must contain only view_id and instance_id" end
        local view_id, instance_id = bounds.id(declared.view_id), bounds.id(declared.instance_id)
        if not view_id or not instance_id then return nil, "origin_view needs view_id and instance_id identifiers" end
        origin_view = {view_id = view_id, instance_id = instance_id}
    end
    local expected_plan_digest: string? = nil
    if object.expected_plan_digest ~= nil then
        local digest = bounds.text(object.expected_plan_digest, 64)
        if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
            return nil, "expected_plan_digest must be a lowercase SHA-256 hex digest"
        end
        expected_plan_digest = digest
    end
    local previous: Continuation? = nil
    if object.continuation ~= nil then
        local source = bounds.object(object.continuation)
        if not source then return nil, "continuation must be an object" end
        local field = bounds.fields(source, {"origin_request_id", "previous_attempt_id", "thread_id", "reauthorize"})
        if field then return nil, "continuation: " .. field end
        local origin = bounds.id(source.origin_request_id)
        local attempt = bounds.id(source.previous_attempt_id)
        local thread = bounds.id(source.thread_id)
        if not origin or not attempt or not thread then return nil, "continuation needs bounded origin, attempt and thread identifiers" end
        if brief ~= "" then return nil, "window continuation cannot replay a brief" end
        if thread_id or thread_title then return nil, "continuation cannot override its thread" end
        if not expected_plan_digest then return nil, "continuation needs the saved launch plan digest" end
        if source.reauthorize ~= nil and type(source.reauthorize) ~= "boolean" then return nil, "continuation.reauthorize must be a boolean" end
        previous = {origin_request_id = origin, previous_attempt_id = attempt, thread_id = thread, reauthorize = source.reauthorize == true}
    end
    return {request_id = request_id, definition_ref = definition_ref, workspace_id = workspace_id, brief = brief, mode = mode, workdir = workdir, thread_id = thread_id,
        overrides = object.overrides ~= nil and spawn_overrides or nil, thread_title = thread_title, placement = placement, saved_profile_id = saved_id, saved_profile_revision = saved_revision,
        expected_plan_digest = expected_plan_digest, placement_override = placement_override, continuation = previous, parent_action_id = parent_action_id, origin_view = origin_view,
        agent_ref = agent_ref, owner_component_revision = owner_component_revision, spec_digest = spec_digest}, nil
end
return M
