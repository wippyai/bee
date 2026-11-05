-- MIT. Launch admission: resolve a definition into a measured plan with no
-- effects, then admit a request for the authenticated requester, obtaining
-- attempt-bound grants and credential projections in that requester's own
-- authority, and start the carrier with a durable identity so a retry
-- after an ambiguous start recovers the same attempt.
local registry = require("registry")
local funcs = require("funcs")
local process = require("process")
local time = require("time")
local bounds = require("bounds")
local canonical = require("canonical")
local catalog = require("catalog")
local definition = require("definition")
local carrier = require("carrier")
local placement_types = require("placement_types")
local continuation = require("continuation")
local interrupted = require("interrupted")
local identity = require("identity")
local M = {}
local resolution = require("resolution")
local part_request = require("part_request")
M.MAX_BRIEF_BYTES = part_request.MAX_BRIEF_BYTES
type OriginView = part_request.OriginView
type Continuation = part_request.Continuation
type Request = part_request.Request
M.decode_request = part_request.decode_request
M.CARRIER = "bee.harness.service:carrier"
M.CARRIER_HOST_REF = "bee.harness.env:carrier_host_ref"
M.THREADS = "bee.threads.binding"
M.CARRIER_OPS = "bee.threads.binding"
M.RESOURCES = "bee.resources.binding"
M.CREDENTIALS = "bee.credentials.binding"
type Admitted = {
    plan: resolution.Plan, request: carrier.Request, requester: string,
    request_id: string, thread_id: string, action_id: string, attempt_id: string,
    session_ref: string?,
    carrier: string?, mode: string?, started_at: string?,
    saved_profile_revision: integer?,
    owner_component_revision: integer?,
}
local function succeed(value: unknown): resolution.Reply
    return {ok = true, error = nil, value = value}
end
local actor = identity.actor

local function call(target: string, request: unknown): ({[string]: unknown}?, resolution.Reply?)
    local raw, err = funcs.call(target, request)
    if err or type(raw) ~= "table" then return nil, resolution.fail("UNAVAILABLE", target .. " did not answer") end
    local reply = bounds.object(raw)
    if not reply then return nil, resolution.fail("UNAVAILABLE", target .. " did not answer") end
    if not reply.ok then
        local fault = bounds.object(reply.error)
        local code = fault and bounds.id(fault.code) or "DENIED"
        return nil, resolution.fail(code or "DENIED", target .. ": " .. tostring(fault and fault.message))
    end
    local value = reply.value
    if type(value) ~= "table" then return {}, nil end
    return value, nil
end
local digest_of = canonical.digest

local function resource_grant(value: {[string]: unknown}, workspace_id: string, name: string, purpose: placement_types.Purpose, audience: string, attempt_id: string): (placement_types.ResourceGrant?, string?)
    local grant_id, returned_workspace, returned_name = bounds.id(value.grant_id), bounds.id(value.workspace_id), bounds.id(value.name)
    local root_ref, returned_subject, returned_audience = bounds.id(value.root_ref), bounds.id(value.subject), bounds.id(value.audience)
    local subpath = bounds.subpath(value.subpath)
    if not grant_id or not returned_workspace or not returned_name or not root_ref or not returned_subject or not returned_audience or not subpath then
        return nil, "resource grant returned an invalid identity or subpath"
    end
    if returned_workspace ~= workspace_id or returned_name ~= name or returned_subject ~= audience or returned_audience ~= audience
        or value.access ~= "write" or value.purpose ~= purpose or value.attempt_id ~= attempt_id then
        return nil, "resource grant returned the wrong scope"
    end
    return {name = returned_name, grant_ref = grant_id, root_ref = root_ref, subpath = subpath, access = "write", purpose = purpose}, nil
end
function M.identities(request_id: string): {action_id: string, attempt_id: string}
    return {action_id = "action:" .. request_id, attempt_id = "attempt:" .. request_id}
end

-- Plan selection reads declarations. Placement invokes driver configuration
-- once it can supply the selected gateway and actual private HOME; a partial
-- render here would reject drivers requiring those host-owned inputs.
-- admit: for the authenticated requester, resolve the plan, settle the
-- thread, obtain the attempt-bound resource grant and credential
-- projections in the requester's own authority, and return the carrier
-- request. Every acquisition keys on the request id, so a retry replays.
function M.admit_request(value: unknown, session_operation_key: string?): (Admitted?, resolution.Reply?)
    local request, decode_error = M.decode_request(value)
    if not request then return nil, resolution.fail("INVALID", decode_error or "invalid request") end
    local requester = actor()
    if not requester then return nil, resolution.fail("UNAUTHENTICATED", "no actor") end
    local selected: resolution.Selected? = nil
    if request.saved_profile_id and request.saved_profile_revision then
        local found, refused = resolution.selected_profile(request.workspace_id, request.saved_profile_id, request.saved_profile_revision, request.definition_ref)
        if not found then return nil, refused end
        if request.owner_component_revision and found.profile.owner_component_revision and found.profile.owner_component_revision ~= request.owner_component_revision then
            return nil, resolution.fail("CONFLICT", "saved profile owner component revision changed; select it again")
        end
        if request.spec_digest and found.profile.spec_digest and found.profile.spec_digest ~= request.spec_digest then
            return nil, resolution.fail("CONFLICT", "saved profile spec digest changed; select it again")
        end
        selected = found
    end
    local pinned, pin_error = catalog.pin()
    if not pinned then return nil, resolution.fail("UNAVAILABLE", pin_error or "pin the registry") end
    local launch, definition_error = resolution.read_definition(pinned, request.definition_ref)
    if not launch then return nil, resolution.fail("NOT_FOUND", definition_error or "definition") end
    local plan, plan_refused, preferences = resolution.resolve_pinned(pinned, launch, request.mode, selected, request.agent_ref, request.owner_component_revision, request.spec_digest, request.placement_override, request.overrides)
    if not plan then return nil, plan_refused end
    if request.expected_plan_digest and request.expected_plan_digest ~= plan.plan_digest then
        return nil, resolution.fail("CONFLICT", "the selected launch plan changed; resolve it again before starting")
    end
    if request.brief == "" and plan.mode ~= "window" then return nil, resolution.fail("INVALID", "a structured launch needs a nonempty brief") end
    if request.workdir and not resolution.overrides(plan, "workdir") then return nil, resolution.fail("FORBIDDEN", "the launch does not allow a workdir override") end
    local defined_thread = launch.thread_policy.kind == "named" and request.thread_id == launch.thread_policy.thread_ref
    local thread_override = request.thread_title ~= nil
        or (request.thread_id ~= nil and launch.thread_policy.kind ~= "caller" and not defined_thread)
    if thread_override and not resolution.overrides(plan, "thread") then return nil, resolution.fail("FORBIDDEN", "the launch does not allow a thread override") end
    if request.placement and request.placement ~= plan.placement_kind then
        if not resolution.overrides(plan, "placement") then return nil, resolution.fail("FORBIDDEN", "the launch does not allow a placement override") end
        return nil, resolution.fail("PLACEMENT_UNAVAILABLE", "this host admits no " .. request.placement .. " placement for " .. launch.ref .. "; it places it " .. plan.placement_kind)
    end
    if plan.placement_kind == "docker" and plan.placement_profile_ref then
        local prepared, prepare_error = call("bee.placement.docker.binding:prepare_environment", {placement_profile_ref = plan.placement_profile_ref,
            workspace_id = request.workspace_id, progress_recipient = tostring(process.pid())})
        if not prepared then return nil, prepare_error end
    end
    local ids = M.identities(request.request_id)
    local previous = request.continuation
    if previous and (#request.workspace_id ~= 32 or request.workspace_id:find("[^0-9a-f]")) then
        return nil, resolution.fail("CONFLICT", "saved windows belong to their canonical home workspace")
    end
    if previous and plan.mode ~= "window" then return nil, resolution.fail("INVALID", "launch continuation requires a window profile") end
    local thread_id = request.thread_id
    if launch.thread_policy.kind == "named" and not thread_override then thread_id = launch.thread_policy.thread_ref end
    if previous then
        if thread_id and thread_id ~= previous.thread_id then return nil, resolution.fail("CONFLICT", "the saved thread differs from the launch definition") end
        thread_id = previous.thread_id
        ids.action_id = M.identities(previous.origin_request_id).action_id
    end
    if not thread_id and not request.thread_title and launch.thread_policy.kind == "caller" then return nil, resolution.fail("INVALID", "definition expects the caller's thread") end
    local workdir_name = request.workdir
    if not workdir_name and launch.workdir_policy.kind == "declared_resource" then workdir_name = launch.workdir_policy.resource_ref end
    if launch.workdir_policy.kind == "required" and not workdir_name then return nil, resolution.fail("INVALID", "definition requires a working directory resource") end
    local session_resource = launch.session_resource
    if previous and not session_resource then return nil, resolution.fail("CONFLICT", "the launch definition has no retained session resource") end
    if session_resource and workdir_name == session_resource then
        return nil, resolution.fail("INVALID", "workdir resource duplicates the session resource")
    end
    -- A caller-selected or host-named existing thread is useful for fan-out,
    -- but it must be authorized before any session, project or credential
    -- resource is acquired. Carrier commits check membership again; this
    -- earlier read prevents a refused launch from leaving admission effects.
    if thread_id and not previous then
        local visible, thread_refused = call(M.THREADS .. ":get", {thread_id = thread_id})
        if not visible then return nil, thread_refused or resolution.fail("DENIED", "caller is not a member of the selected thread") end
        local membership = bounds.object(visible.membership)
        -- Threads authenticates this read as the caller and may resolve an attested application family to its active member.
        if not membership or membership.active ~= true then
            return nil, resolution.fail("DENIED", "caller is not an active member of the selected thread")
        end
    end
    -- Session authority is selected by the host definition. A retained
    -- session gets one stable digest-derived identity per launch request, while the
    -- default remains ephemeral and receives no session grant.
    local interactive_session: string? = nil
    if plan.mode == "window" and previous then
        local attached, attach_error = call("bee.threads.sessions.binding:attach", {definition = request.definition_ref, thread_id = thread_id,
            plan_digest = plan.plan_digest, overrides = request.overrides, saved_profile_id = request.saved_profile_id, saved_profile_revision = request.saved_profile_revision,
            attempt_id = previous.previous_attempt_id, origin_request_id = previous.origin_request_id,
            operation_key = session_operation_key or "window-session:" .. previous.origin_request_id})
        if not attached then return nil, attach_error end
        interactive_session = bounds.id(attached.session)
        if not interactive_session then return nil, resolution.fail("UNAVAILABLE", "interactive session owner omitted its ref") end
    end
    local resources: {placement_types.ResourceGrant} = {}
    local session_ref: string? = nil
    -- A previous attempt the thread never recorded was admitted but never
    -- started: this window is the session's first start, not a continuation.
    local first_start = false
    if session_resource then
        local session_digest, session_error = digest_of({workspace_id = request.workspace_id,
            request_id = previous and previous.origin_request_id or request.request_id})
        if not session_digest then return nil, resolution.fail("UNAVAILABLE", tostring(session_error or "derive retained session identity")) end
        session_ref = interactive_session or "session:" .. session_digest
        if previous then
            -- Saved references grant nothing. Existing owner operations verify
            -- membership, exact producer/session, driver pins and completed
            -- cleanup before this request obtains any fresh grants.
            local recovery_request: continuation.Request = {thread_id = previous.thread_id,
                action_id = ids.action_id, attempt_id = ids.attempt_id, previous_attempt_id = previous.previous_attempt_id,
                owner_id = requester, session_ref = assert(session_ref), binding_ref = plan.binding_ref,
                binding_digest = plan.binding_digest, profile_id = plan.profile_id, profile_digest = plan.profile_digest,
                placement_binding_ref = plan.placement_binding_ref, placement_binding_digest = plan.placement_binding_digest,
                placement_methods = plan.placement_methods, reauthorize = previous.reauthorize}
            local recovered, recovery_error = interrupted.recover(recovery_request)
            if not recovered then return nil, resolution.fail("CONFLICT", "cannot recover saved window: " .. tostring(recovery_error)) end
            local resume, resume_error = continuation.resolve_window(function(target: string, input: unknown): (unknown, string?)
                local reply, err = funcs.call(target, input)
                if err then return nil, tostring(err) end
                return reply, nil
            end, recovery_request)
            first_start = resume_error == continuation.NEVER_RECORDED
            if not resume and resume_error ~= continuation.NO_CONVERSATION and not first_start then
                return nil, resolution.fail("CONFLICT", "cannot resume saved window: " .. tostring(resume_error))
            end
        end
        local granted, grant_refused = call(M.RESOURCES .. ":grant", {workspace_id = request.workspace_id, name = session_resource, access = "write", purpose = "session",
            audience = requester, attempt_id = ids.attempt_id, idempotency_key = "launch:" .. request.request_id .. ":session"})
        if not granted then return nil, grant_refused end
        local typed, grant_error = resource_grant(granted, request.workspace_id, session_resource, "session", requester, ids.attempt_id)
        if not typed then return nil, resolution.fail("UNAVAILABLE", grant_error or "resource grant is invalid") end
        resources[#resources + 1] = typed
    end
    for _, ref in ipairs(plan.effective_profile and plan.effective_profile.bee.approval_leases or {}) do
        local _, refused = call("bee.approvals.binding:runtime_lease", {operation = "check", lease_ref = ref, workspace_id = request.workspace_id})
        if refused then return nil, refused end
    end
    if not thread_id then
        local created, create_refused = call(M.THREADS .. ":create", {thread_id = "thread:" .. request.request_id, idempotency_key = "launch:" .. request.request_id .. ":thread", title = request.thread_title or plan.title})
        if not created then return nil, create_refused end
        thread_id = tostring(created.thread_id)
    end
    if plan.mode == "window" then
        local attached, attach_error = call("bee.threads.sessions.binding:attach", {definition = request.definition_ref, thread_id = thread_id,
            plan_digest = plan.plan_digest, overrides = request.overrides, saved_profile_id = request.saved_profile_id, saved_profile_revision = request.saved_profile_revision,
            attempt_id = ids.attempt_id, origin_request_id = previous and previous.origin_request_id or request.request_id,
            operation_key = session_operation_key or "window-session:" .. (previous and previous.origin_request_id or request.request_id)})
        if not attached then return nil, attach_error end
        interactive_session = bounds.id(attached.session)
        if not interactive_session then return nil, resolution.fail("UNAVAILABLE", "interactive session owner omitted its ref") end
        session_ref = interactive_session
    end
    local working: string? = nil
    if workdir_name then
        local granted, grant_refused = call(M.RESOURCES .. ":grant", {workspace_id = request.workspace_id, name = workdir_name, access = "write", purpose = "project",
            audience = requester, attempt_id = ids.attempt_id, idempotency_key = "launch:" .. request.request_id .. ":workdir"})
        if not granted then return nil, grant_refused end
        local typed, grant_error = resource_grant(granted, request.workspace_id, workdir_name, "project", requester, ids.attempt_id)
        if not typed then return nil, resolution.fail("UNAVAILABLE", grant_error or "resource grant is invalid") end
        resources[#resources + 1] = typed
        working = workdir_name
    end
    local profile_grants: {carrier.ProfileGrant} = {}
    for index, file in ipairs(plan.effective_profile and plan.effective_profile.bee.files or {}) do
        local granted, refused = call(M.RESOURCES .. ":grant", {workspace_id = file.workspace_id, name = file.resource, subpath = file.subpath,
            access = file.access, purpose = "project", audience = requester, attempt_id = ids.attempt_id,
            idempotency_key = "launch:" .. request.request_id .. ":file:" .. tostring(index)})
        if not granted then return nil, refused end
        local grant_id, root = bounds.id(granted.grant_id), bounds.id(granted.root_ref)
        if not grant_id or not root or granted.subpath ~= file.subpath or granted.workspace_id ~= file.workspace_id or granted.name ~= file.resource
            or granted.access ~= file.access or granted.attempt_id ~= ids.attempt_id or granted.audience ~= requester then return nil, resolution.fail("UNAVAILABLE", "bee.files: owner returned a different grant") end
        profile_grants[#profile_grants + 1] = {workspace_id = file.workspace_id, name = file.resource, subpath = file.subpath, access = file.access, grant_ref = grant_id}
    end
    local projections: {string} = {}
    local credentials = launch.credentials
    for index, credential in ipairs(credentials) do
        local issued, issue_refused = call(M.CREDENTIALS .. ":issue_projection", {workspace_id = request.workspace_id, name = credential, audience = requester, attempt_id = ids.attempt_id,
            profile_id = plan.profile_id, profile_digest = plan.profile_digest, binding_digest = plan.binding_digest, launch_policy_digest = plan.policy_digest,
            idempotency_key = "launch:" .. request.request_id .. ":credential:" .. tostring(index)})
        if not issued then return nil, issue_refused end
        if selected then
            for name, value in pairs(selected.profile.provider.env or {}) do
                if value.kind == "credential" and value.credential_ref == credential and (issued.projection_kind ~= "environment" or issued.destination ~= name) then
                    return nil, resolution.fail("DENIED", "provider.env." .. name .. ": credential broker destination differs; references cannot retarget credentials")
                elseif value.kind == "literal" and issued.projection_kind == "environment" and issued.destination == name then
                    return nil, resolution.fail("DENIED", "provider.env." .. name .. ": literal conflicts with an admitted credential projection")
                end
            end
        end
        projections[index] = tostring(issued.projection_id)
    end
    local carrier_request: carrier.Request = {profile_grants = profile_grants, thread_id = thread_id, action_id = ids.action_id, attempt_id = ids.attempt_id, owner_id = requester, owner_incarnation = 1, parent_action_id = request.parent_action_id,
        preferences = preferences or resolution.preference_value(selected),
        binding_ref = plan.binding_ref, profile_id = plan.profile_id, brief = request.brief, policy_ref = plan.policy_ref,
        placement_profile_ref = plan.placement_profile_ref, placement_profile_digest = plan.placement_profile_digest, placement_binding_ref = plan.placement_binding_ref, placement_binding_digest = plan.placement_binding_digest, placement_methods = plan.placement_methods, resources = resources, environment = {},
        working_directory = working, projections = projections, workspace_id = request.workspace_id, session_ref = session_ref,
        previous_attempt_id = previous and not first_start and previous.previous_attempt_id or nil, reauthorize = previous and not first_start and previous.reauthorize or nil, origin_view = request.origin_view,
        options = launch.options}
    return {plan = plan, request = carrier_request, requester = requester, request_id = request.request_id,
        thread_id = thread_id, action_id = ids.action_id, attempt_id = ids.attempt_id, session_ref = session_ref,
        saved_profile_revision = plan.saved_profile_revision,
        owner_component_revision = plan.owner_component_revision}, nil
end
-- External callers keep the operation reply; local execution paths consume
-- the typed admitted request without decoding our own value a second time.
function M.admit(value: unknown): resolution.Reply
    local admitted, refused = M.admit_request(value)
    if not admitted then return refused or resolution.fail("UNAVAILABLE", "launch admission did not return a result") end
    return succeed(admitted)
end
local function carrier_host(): (string?, resolution.Reply?)
    local linked = registry.get(M.CARRIER_HOST_REF)
    local data = linked and bounds.object(linked.data) or nil
    local host = data and bounds.id(data.host_ref) or nil
    if not host then return nil, resolution.fail("UNAVAILABLE", "carrier process host is not linked") end
    local target = registry.get(host)
    if not target or target.kind ~= "process.host" then return nil, resolution.fail("UNAVAILABLE", "carrier process host is unavailable") end
    return host, nil
end
local function start_admitted(outcome: Admitted, host: string): resolution.Reply
    local carrier_request = outcome.request
    local stored = call(M.CARRIER_OPS .. ":checkpoint", {thread_id = outcome.thread_id, attempt_id = outcome.attempt_id})
    local mode = "open"
    if stored then
        if stored.attempt_state == "ended" then
            if carrier_request.brief == "" then
                return resolution.fail("CONFLICT", "request " .. tostring(outcome.attempt_id) .. " already settled")
            end
            local grant_refs: {string} = {}
            for index, grant in ipairs(carrier_request.resources) do grant_refs[index] = grant.grant_ref end
            local admitted = carrier.admitted_action(carrier_request, outcome.plan.binding_ref,
                outcome.plan.binding_digest, outcome.plan.policy_ref, grant_refs, carrier_request.brief)
            local checked, replay_refused = call(M.THREADS .. ":admit_action", {thread_id = outcome.thread_id,
                idempotency_key = "launch:" .. outcome.attempt_id .. ":admit",
                action_id = outcome.action_id, admitted = admitted})
            if not checked then
                return replay_refused or resolution.fail("CONFLICT", "settled launch does not match this request")
            end
            outcome.mode = "settled"
            return succeed(outcome)
        end
        if stored.checkpoint ~= nil then mode = "resume" end
    end
    -- The carrier outlives this call; whoever routes the launch monitors it.
    local pid, spawn_error = process.with_context({}):spawn(M.CARRIER, host, carrier_request, mode, process.pid())
    if not pid then return resolution.fail("UNAVAILABLE", "spawn carrier: " .. tostring(spawn_error)) end
    outcome.carrier = tostring(pid)
    outcome.mode = mode
    outcome.started_at = time.now():utc():format("2006-01-02T15:04:05.000Z07:00")
    return succeed(outcome)
end
function M.start_admitted(outcome: Admitted): resolution.Reply
    local host, refused = carrier_host()
    if not host then return refused or resolution.fail("UNAVAILABLE", "carrier process host is unavailable") end
    return start_admitted(outcome, host)
end
function M.start(value: unknown): resolution.Reply
    local host, host_error = carrier_host()
    if not host then return host_error or resolution.fail("UNAVAILABLE", "carrier process host is unavailable") end
    local outcome, refused = M.admit_request(value)
    if not outcome then return refused or resolution.fail("UNAVAILABLE", "launch admission did not return a result") end
    return start_admitted(outcome, host)
end
return M
