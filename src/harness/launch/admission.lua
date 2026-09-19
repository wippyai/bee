-- MIT. Launch admission: resolve a definition into a measured plan with no
-- effects, then admit a request for the authenticated requester, obtaining
-- attempt-bound grants and credential projections in that requester's own
-- authority, and start the carrier with a durable identity so a retry
-- after an ambiguous start recovers the same attempt.
local hash = require("hash")
local registry = require("registry")
local funcs = require("funcs")
local process = require("process")
local security = require("security")
local time = require("time")
local bounds = require("bounds")
local canonical = require("canonical")
local catalog = require("catalog")
local policy = require("policy")
local definition = require("definition")
local carrier = require("carrier")
local placement_types = require("placement_types")
local placement_resolver = require("placement_resolver")
local continuation = require("continuation")
local interrupted = require("interrupted")
local profiles = require("profiles")
local M = {}
M.CARRIER = "bee.harness.carrier:process"
M.CARRIER_HOST_REF = "bee.harness:carrier_host_ref"
M.THREADS = "bee.threads.service"
M.CARRIER_OPS = "bee.threads.carrier"
M.RESOURCES = "bee.resources"
M.CREDENTIALS = "bee.credentials"
M.MAX_BRIEF_BYTES = 16384
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown}
type Plan = {
    saved_profile_id: string?,
    saved_profile_revision: integer?,
    title: string,
    definition_ref: string,
    definition_digest: string,
    launch_id: string,
    binding_ref: string,
    binding_digest: string,
    profile_id: string,
    profile_digest: string,
    policy_ref: string,
    policy_digest: string,
    placement_binding_ref: string,
    placement_binding_digest: string,
    placement_methods: {[string]: string},
    catalog_generation: integer,
    mode: string,
    plan_digest: string,
}
type Admitted = {
    plan: Plan, request: carrier.Request, requester: string,
    request_id: string, thread_id: string, action_id: string, attempt_id: string,
    session_ref: string?,
    carrier: string?, mode: string?, started_at: string?,
}
type Continuation = {origin_request_id: string, previous_attempt_id: string, thread_id: string, reauthorize: boolean?}
type Request = {
    saved_profile_id: string?,
    saved_profile_revision: integer?,
    request_id: string,
    definition_ref: string,
    workspace_id: string,
    brief: string,
    mode: string?,
    workdir: string?,
    thread_id: string?,
    expected_plan_digest: string?,
    continuation: Continuation?,
    parent_action_id: string?,
}
local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end
local function succeed(value: unknown): Reply
    return {ok = true, error = nil, value = value}
end
local function actor(): string?
    local current = security.actor()
    if not current then return nil end
    return bounds.id(current:id())
end
local function call(target: string, request: unknown): ({[string]: unknown}?, Reply?)
    local raw, err = funcs.call(target, request)
    if err or type(raw) ~= "table" then return nil, fail("UNAVAILABLE", target .. " did not answer") end
    local reply = raw :: Reply
    if not reply.ok then return nil, fail(reply.error and reply.error.code or "DENIED", target .. ": " .. tostring(reply.error and reply.error.message)) end
    local value = reply.value
    if type(value) ~= "table" then return {}, nil end
    return value :: {[string]: unknown}, nil
end
local function digest_of(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest failed" end
    return sum, nil
end
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
-- resolve: the measured plan for a definition, with no effects. The plan
-- digest pins the definition, the binding and profile measurements and
-- the launch policy at one catalog generation.
local function read_definition(pinned: catalog.Pinned, definition_ref: string): (definition.Definition?, string?)
    local entry = catalog.entry(pinned, definition_ref)
    if not entry then return nil, "launch definition " .. definition_ref .. " is not in the registry" end
    return definition.decode(definition_ref, entry)
end
type Selected = {profile_id: string, revision: integer, profile: profiles.Profile}
local function selected_profile(workspace: string, id: string, revision: integer, definition_ref: string): (Selected?, Reply?)
    local raw, err = funcs.call("bee.harness.profiles:call", {operation = "get", workspace_id = workspace, profile_id = id})
    if err then return nil, fail("UNAVAILABLE", "saved profile did not answer") end
    local reply = bounds.object(raw)
    if not reply then return nil, fail("UNAVAILABLE", "invalid saved profile reply") end
    if reply.ok ~= true then return nil, fail(bounds.id(reply.code) or "DENIED", "saved profile is unavailable") end
    local value = bounds.object(reply.value)
    if not value or value.workspace_id ~= workspace or value.profile_id ~= id then return nil, fail("UNAVAILABLE", "saved profile identity differs") end
    if value.tombstone ~= false or value.revision ~= revision then return nil, fail("CONFLICT", "saved profile changed; select it again") end
    local profile, profile_error = profiles.profile(value.profile)
    if not profile then return nil, fail("UNAVAILABLE", profile_error or "invalid saved profile") end
    if profile.definition_ref ~= definition_ref then return nil, fail("CONFLICT", "saved profile selects a different launch definition") end
    return {profile_id = id, revision = revision, profile = profile}, nil
end
local function preference_value(selected: Selected?): placement_types.Preferences?
    if not selected then return nil end
    local value: placement_types.Preferences = {options = selected.profile.options, mcp_tools = selected.profile.mcp_tools, instructions = selected.profile.instructions}
    -- A named Codex config profile is host policy, not a general option: it
    -- travels with the saved profile so the same profile launches identically
    -- from the picker and from a future MCP call.
    if selected.profile.config_profile then value.config_profile = selected.profile.config_profile end
    return value
end
local function resolve(pinned: catalog.Pinned, launch: definition.Definition, mode: string?, selected: Selected?): (Plan?, Reply?)
    local definition_ref = launch.ref
    local chosen = launch.default_mode
    if mode and mode ~= chosen then
        if not definition.allows(launch, "mode") then return nil, fail("FORBIDDEN", "definition " .. definition_ref .. " does not allow a mode override") end
        if not bounds.member(mode, definition.MODES) then return nil, fail("INVALID", "mode must be window, session or batch") end
        chosen = mode
    end
    local snapshot, snapshot_error = catalog.read(pinned, nil)
    if not snapshot then return nil, fail("UNAVAILABLE", snapshot_error or "catalog") end
    local usable, usable_error = catalog.usable(snapshot)
    if not usable then return nil, fail("UNAVAILABLE", usable_error or "catalog") end
    local binding_digest, profile_digest = "", ""
    local binding = nil
    local supported = false
    for _, candidate in ipairs(usable) do
        if candidate.binding_id == launch.binding_ref then
            binding = candidate
            binding_digest = candidate.binding_digest.entry
            profile_digest = candidate.profile_digest.entry
            for _, profile in ipairs(candidate.profiles) do
                if profile.id == launch.profile_id and profile.supported and profile.mode == chosen then supported = true end
            end
        end
    end
    if binding_digest == "" then return nil, fail("UNAVAILABLE", "binding " .. launch.binding_ref .. " is not usable on this host") end
    if not supported then return nil, fail("UNSUPPORTED_CAPABILITY", "profile " .. launch.profile_id .. " of " .. launch.binding_ref .. " does not run in mode " .. chosen) end
    local policy_entry = catalog.entry(pinned, launch.policy_ref)
    if not policy_entry then return nil, fail("NOT_FOUND", "launch policy " .. launch.policy_ref .. " is not in the registry") end
    local launch_policy, policy_error = policy.decode(launch.policy_ref, policy_entry, nil, preference_value(selected))
    if not launch_policy then return nil, fail("NOT_FOUND", policy_error or "policy") end
    -- Resolve placement alongside the driver and policy from this immutable
    -- registry snapshot. The policy may select an implementation; absent that
    -- field the resolver's native host default is used.
    local placement, placement_error = placement_resolver.resolve(pinned, launch_policy.placement_binding)
    if not placement then return nil, fail("UNAVAILABLE", placement_error or "placement binding") end
    if not binding then return nil, fail("UNAVAILABLE", "binding " .. launch.binding_ref .. " is not usable on this host") end
    -- A listed profile needs a host-selected executable, but this passive
    -- read cannot know the driver's eventual launch.executable. The carrier
    -- binds that prepared name to this policy's exact key before placement.
    local has_absolute_executable = false
    for _, executable in pairs(launch_policy.executables) do
        if executable:sub(1, 1) == "/" then has_absolute_executable = true end
    end
    if not has_absolute_executable then
        return nil, fail("UNAVAILABLE", "launch policy " .. launch.policy_ref .. " has no absolute executable binding")
    end
    -- Provider data selects part of the generated private-home configuration.
    -- Its exact registry entry therefore belongs to the displayed plan fence,
    -- even though the driver decodes it only after a user selects the plan.
    local provider_digest: string? = nil
    if launch_policy.provider_ref then
        local provider_entry = catalog.entry(pinned, launch_policy.provider_ref)
        if not provider_entry then return nil, fail("NOT_FOUND", "provider " .. launch_policy.provider_ref .. " is not in the registry") end
        local measured, provider_error = digest_of(provider_entry)
        if not measured then return nil, fail("INVALID", "provider " .. launch_policy.provider_ref .. ": " .. tostring(provider_error)) end
        provider_digest = measured
    end
    local plan_digest, digest_error = digest_of({definition = launch.digest, binding = binding_digest, profile = profile_digest, policy = launch_policy.digest,
        placement_binding_ref = placement.binding_id, placement_binding_digest = placement.binding_digest, placement_methods = placement.methods,
        provider = provider_digest, mode = chosen, saved_profile = selected})
    if not plan_digest then return nil, fail("INVALID", digest_error or "plan") end
    return {title = launch.title, definition_ref = definition_ref, definition_digest = launch.digest, launch_id = launch.launch_id, binding_ref = launch.binding_ref, binding_digest = binding_digest,
        profile_id = launch.profile_id, profile_digest = profile_digest, policy_ref = launch.policy_ref, policy_digest = launch_policy.digest,
        placement_binding_ref = placement.binding_id, placement_binding_digest = placement.binding_digest,
        placement_methods = placement.methods,
        catalog_generation = snapshot.generation, mode = chosen, plan_digest = plan_digest,
        saved_profile_id = selected and selected.profile_id or nil, saved_profile_revision = selected and selected.revision or nil}, nil
end
-- A caller composing a larger host plan can retain the same snapshot for
-- its other declarations; this read performs no registry mutation or admission.
function M.read(pinned: catalog.Pinned, definition_ref: string, mode: string?): (Plan?, Reply?)
    local launch, definition_error = read_definition(pinned, definition_ref)
    if not launch then return nil, fail("NOT_FOUND", definition_error or "definition") end
    return resolve(pinned, launch, mode)
end
function M.resolve(definition_ref: string, mode: string?, workspace: string?, saved_id: string?, saved_revision: integer?): (Plan?, Reply?)
    local selected: Selected? = nil
    if saved_id or saved_revision then
        if not workspace or not saved_id or not saved_revision or saved_revision < 1 then return nil, fail("INVALID", "saved profile needs workspace, identity and revision") end
        local found, refused = selected_profile(workspace, saved_id, saved_revision, definition_ref)
        if not found then return nil, refused end
        selected = found
    end
    local pinned, pin_error = catalog.pin()
    if not pinned then return nil, fail("UNAVAILABLE", pin_error or "pin the registry") end
    local launch, definition_error = read_definition(pinned, definition_ref)
    if not launch then return nil, fail("NOT_FOUND", definition_error or "definition") end
    return resolve(pinned, launch, mode, selected)
end
function M.decode_request(value: unknown): (Request?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local unknown_field = bounds.fields(object, {"request_id", "definition_ref", "workspace_id", "brief", "mode", "workdir", "thread_id", "expected_plan_digest", "continuation", "saved_profile_id", "saved_profile_revision", "parent_action_id"})
    if unknown_field then return nil, unknown_field end
    local request_id, definition_ref, workspace_id = bounds.id(object.request_id), bounds.id(object.definition_ref), bounds.id(object.workspace_id)
    if not request_id then return nil, "request_id is not an identifier" end
    if not definition_ref then return nil, "definition_ref is not an identifier" end
    if not workspace_id then return nil, "workspace_id is not an identifier" end
    local saved_id, saved_revision = bounds.id(object.saved_profile_id), bounds.count(object.saved_profile_revision)
    if object.saved_profile_id ~= nil or object.saved_profile_revision ~= nil then
        if not saved_id or not saved_revision or saved_revision < 1 then return nil, "saved profile needs identity and positive revision" end
        if object.expected_plan_digest == nil then return nil, "saved profile needs the selected launch plan digest" end
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
        if thread_id then return nil, "continuation cannot override its thread" end
        if not expected_plan_digest then return nil, "continuation needs the saved launch plan digest" end
        if source.reauthorize ~= nil and type(source.reauthorize) ~= "boolean" then return nil, "continuation.reauthorize must be a boolean" end
        previous = {origin_request_id = origin, previous_attempt_id = attempt, thread_id = thread, reauthorize = source.reauthorize == true}
    end
    return {request_id = request_id, definition_ref = definition_ref, workspace_id = workspace_id, brief = brief, mode = mode, workdir = workdir, thread_id = thread_id,
        saved_profile_id = saved_id, saved_profile_revision = saved_revision,
        expected_plan_digest = expected_plan_digest, continuation = previous, parent_action_id = parent_action_id}, nil
end
-- The durable identities of a request: the same request id always names
-- the same action and attempt.
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
function M.admit_request(value: unknown): (Admitted?, Reply?)
    local request, decode_error = M.decode_request(value)
    if not request then return nil, fail("INVALID", decode_error or "invalid request") end
    local requester = actor()
    if not requester then return nil, fail("UNAUTHENTICATED", "no actor") end
    local selected: Selected? = nil
    if request.saved_profile_id and request.saved_profile_revision then
        local found, refused = selected_profile(request.workspace_id, request.saved_profile_id, request.saved_profile_revision, request.definition_ref)
        if not found then return nil, refused end
        selected = found
    end
    local pinned, pin_error = catalog.pin()
    if not pinned then return nil, fail("UNAVAILABLE", pin_error or "pin the registry") end
    local launch, definition_error = read_definition(pinned, request.definition_ref)
    if not launch then return nil, fail("NOT_FOUND", definition_error or "definition") end
    local plan, plan_refused = resolve(pinned, launch, request.mode, selected)
    if not plan then return nil, plan_refused end
    if request.expected_plan_digest and request.expected_plan_digest ~= plan.plan_digest then
        return nil, fail("CONFLICT", "the selected launch plan changed; resolve it again before starting")
    end
    if request.brief == "" and plan.mode ~= "window" then return nil, fail("INVALID", "a structured launch needs a nonempty brief") end
    if request.workdir and not definition.allows(launch, "workdir") then return nil, fail("FORBIDDEN", "definition does not allow a workdir override") end
    if request.thread_id and not definition.allows(launch, "thread") then return nil, fail("FORBIDDEN", "definition does not allow a thread override") end
    local ids = M.identities(request.request_id)
    local previous = request.continuation
    if previous and plan.mode ~= "window" then return nil, fail("INVALID", "launch continuation requires a window profile") end
    local thread_id = request.thread_id
    if launch.thread_policy.kind == "named" then thread_id = launch.thread_policy.thread_ref end
    if previous then
        if thread_id and thread_id ~= previous.thread_id then return nil, fail("CONFLICT", "the saved thread differs from the launch definition") end
        thread_id = previous.thread_id
        ids.action_id = M.identities(previous.origin_request_id).action_id
    end
    if not thread_id and launch.thread_policy.kind == "caller" then return nil, fail("INVALID", "definition expects the caller's thread") end
    local workdir_name = request.workdir
    if launch.workdir_policy.kind == "declared_resource" then workdir_name = launch.workdir_policy.resource_ref end
    if launch.workdir_policy.kind == "required" and not workdir_name then return nil, fail("INVALID", "definition requires a working directory resource") end
    local session_resource = launch.session_resource
    if previous and not session_resource then return nil, fail("CONFLICT", "the launch definition has no retained session resource") end
    if session_resource and workdir_name == session_resource then
        return nil, fail("INVALID", "workdir resource duplicates the session resource")
    end
    -- A caller-selected or host-named existing thread is useful for fan-out,
    -- but it must be authorized before any session, project or credential
    -- resource is acquired. Carrier commits check membership again; this
    -- earlier read prevents a refused launch from leaving admission effects.
    if thread_id and not previous then
        local visible, thread_refused = call(M.THREADS .. ":get", {thread_id = thread_id})
        if not visible then return nil, thread_refused or fail("DENIED", "caller is not a member of the selected thread") end
        local membership = bounds.object(visible.membership)
        if not membership or membership.member_id ~= requester or membership.active ~= true then
            return nil, fail("DENIED", "caller is not an active member of the selected thread")
        end
    end
    -- Session authority is selected by the host definition. A retained
    -- session gets one stable digest-derived identity per launch request, while the
    -- default remains ephemeral and receives no session grant.
    local resources: {placement_types.ResourceGrant} = {}
    local session_ref: string? = nil
    if session_resource then
        local session_digest, session_error = digest_of({workspace_id = request.workspace_id,
            request_id = previous and previous.origin_request_id or request.request_id})
        if not session_digest then return nil, fail("UNAVAILABLE", tostring(session_error or "derive retained session identity")) end
        session_ref = "session:" .. session_digest
        if previous then
            -- Saved references grant nothing. Existing owner operations verify
            -- membership, exact producer/session, driver pins and completed
            -- cleanup before this request obtains any fresh grants.
            local recovered, recovery_error = interrupted.recover({thread_id = previous.thread_id,
                action_id = ids.action_id, attempt_id = ids.attempt_id, previous_attempt_id = previous.previous_attempt_id,
                owner_id = requester, session_ref = session_ref, binding_ref = plan.binding_ref,
                binding_digest = plan.binding_digest, profile_id = plan.profile_id, profile_digest = plan.profile_digest,
                placement_binding_ref = plan.placement_binding_ref, placement_binding_digest = plan.placement_binding_digest,
                placement_methods = plan.placement_methods, reauthorize = previous.reauthorize})
            if not recovered then return nil, fail("CONFLICT", "cannot recover saved window: " .. tostring(recovery_error)) end
            local resume, resume_error = continuation.resolve_window(function(target: string, input: unknown): (unknown, string?)
                local reply, err = funcs.call(target, input)
                if err then return nil, tostring(err) end
                return reply, nil
            end, {thread_id = previous.thread_id, action_id = ids.action_id, attempt_id = ids.attempt_id,
                previous_attempt_id = previous.previous_attempt_id, owner_id = requester, session_ref = session_ref,
                binding_ref = plan.binding_ref, binding_digest = plan.binding_digest,
                profile_id = plan.profile_id, profile_digest = plan.profile_digest,
                placement_binding_ref = plan.placement_binding_ref, placement_binding_digest = plan.placement_binding_digest,
                placement_methods = plan.placement_methods, reauthorize = previous.reauthorize})
            if not resume then return nil, fail("CONFLICT", "cannot resume saved window: " .. tostring(resume_error)) end
        end
        local granted, grant_refused = call(M.RESOURCES .. ":grant", {workspace_id = request.workspace_id, name = session_resource, access = "write", purpose = "session",
            audience = requester, attempt_id = ids.attempt_id, idempotency_key = "launch:" .. request.request_id .. ":session"})
        if not granted then return nil, grant_refused end
        local typed, grant_error = resource_grant(granted, request.workspace_id, session_resource, "session", requester, ids.attempt_id)
        if not typed then return nil, fail("UNAVAILABLE", grant_error or "resource grant is invalid") end
        resources[#resources + 1] = typed
    end
    if not thread_id then
        local created, create_refused = call(M.THREADS .. ":create", {thread_id = "thread:" .. request.request_id, idempotency_key = "launch:" .. request.request_id .. ":thread", title = launch.title})
        if not created then return nil, create_refused end
        thread_id = tostring(created.thread_id)
    end
    local working: string? = nil
    if workdir_name then
        local granted, grant_refused = call(M.RESOURCES .. ":grant", {workspace_id = request.workspace_id, name = workdir_name, access = "write", purpose = "project",
            audience = requester, attempt_id = ids.attempt_id, idempotency_key = "launch:" .. request.request_id .. ":workdir"})
        if not granted then return nil, grant_refused end
        local typed, grant_error = resource_grant(granted, request.workspace_id, workdir_name, "project", requester, ids.attempt_id)
        if not typed then return nil, fail("UNAVAILABLE", grant_error or "resource grant is invalid") end
        resources[#resources + 1] = typed
        working = workdir_name
    end
    local projections: {string} = {}
    for index, credential in ipairs(launch.credentials) do
        local issued, issue_refused = call(M.CREDENTIALS .. ":issue_projection", {workspace_id = request.workspace_id, name = credential, audience = requester, attempt_id = ids.attempt_id,
            profile_id = plan.profile_id, profile_digest = plan.profile_digest, binding_digest = plan.binding_digest, launch_policy_digest = plan.policy_digest,
            idempotency_key = "launch:" .. request.request_id .. ":credential:" .. tostring(index)})
        if not issued then return nil, issue_refused end
        projections[index] = tostring(issued.projection_id)
    end
    local carrier_request: carrier.Request = {thread_id = thread_id, action_id = ids.action_id, attempt_id = ids.attempt_id, owner_id = requester, owner_incarnation = 1, parent_action_id = request.parent_action_id,
        preferences = preference_value(selected),
        binding_ref = plan.binding_ref, profile_id = plan.profile_id, brief = request.brief, policy_ref = plan.policy_ref,
        placement_binding_ref = plan.placement_binding_ref, placement_binding_digest = plan.placement_binding_digest, placement_methods = plan.placement_methods, resources = resources, environment = {},
        working_directory = working, projections = projections, workspace_id = request.workspace_id, session_ref = session_ref,
        previous_attempt_id = previous and previous.previous_attempt_id or nil, reauthorize = previous and previous.reauthorize or nil}
    return {plan = plan, request = carrier_request, requester = requester, request_id = request.request_id,
        thread_id = thread_id, action_id = ids.action_id, attempt_id = ids.attempt_id, session_ref = session_ref}, nil
end
-- External callers keep the operation reply; local execution paths consume
-- the typed admitted request without decoding our own value a second time.
function M.admit(value: unknown): Reply
    local admitted, refused = M.admit_request(value)
    if not admitted then return refused or fail("UNAVAILABLE", "launch admission did not return a result") end
    return succeed(admitted)
end
-- start: admit, then spawn the carrier as the requester. A retry with the
-- same request id finds the attempt's checkpoint and resumes it instead of
-- opening a second one.
function M.start(value: unknown): Reply
    local linked = registry.get(M.CARRIER_HOST_REF)
    local data = linked and bounds.object(linked.data) or nil
    local host = data and bounds.id(data.host_ref) or nil
    if not host then return fail("UNAVAILABLE", "carrier process host is not linked") end
    local target = registry.get(host)
    if not target or target.kind ~= "process.host" then return fail("UNAVAILABLE", "carrier process host is unavailable") end
    local outcome, refused = M.admit_request(value)
    if not outcome then return refused or fail("UNAVAILABLE", "launch admission did not return a result") end
    local carrier_request = outcome.request
    local stored = call(M.CARRIER_OPS .. ":checkpoint", {thread_id = outcome.thread_id, attempt_id = outcome.attempt_id})
    local mode = "open"
    if stored then
        if stored.attempt_state == "ended" then return fail("CONFLICT", "request " .. tostring(outcome.attempt_id) .. " already settled") end
        if stored.checkpoint ~= nil then mode = "resume" end
    end
    -- The carrier outlives this call; whoever routes the launch monitors it.
    local pid, spawn_error = process.with_context({}):spawn(M.CARRIER, host, carrier_request, mode, process.pid())
    if not pid then return fail("UNAVAILABLE", "spawn carrier: " .. tostring(spawn_error)) end
    outcome.carrier = tostring(pid)
    outcome.mode = mode
    outcome.started_at = time.now():utc():format("2006-01-02T15:04:05.000Z07:00")
    return succeed(outcome)
end
return M
