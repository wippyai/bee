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
local configuration = require("configuration")
local resolver = require("resolver")
local placement_types = require("placement_types")
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
    definition_ref: string,
    definition_digest: string,
    launch_id: string,
    binding_ref: string,
    binding_digest: string,
    profile_id: string,
    profile_digest: string,
    policy_ref: string,
    policy_digest: string,
    catalog_generation: integer,
    mode: string,
    plan_digest: string,
}
type Admitted = {
    plan: Plan, request: carrier.Request, requester: string,
    thread_id: string, action_id: string, attempt_id: string,
    session_ref: string?,
    carrier: string?, mode: string?, started_at: string?,
}
type Request = {
    request_id: string,
    definition_ref: string,
    workspace_id: string,
    brief: string,
    mode: string?,
    workdir: string?,
    thread_id: string?,
    expected_plan_digest: string?,
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
local function resolve(pinned: catalog.Pinned, launch: definition.Definition, mode: string?): (Plan?, Reply?)
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
    local launch_policy, policy_error = policy.decode(launch.policy_ref, policy_entry)
    if not launch_policy then return nil, fail("NOT_FOUND", policy_error or "policy") end
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
        provider = provider_digest, mode = chosen})
    if not plan_digest then return nil, fail("INVALID", digest_error or "plan") end
    return {definition_ref = definition_ref, definition_digest = launch.digest, launch_id = launch.launch_id, binding_ref = launch.binding_ref, binding_digest = binding_digest,
        profile_id = launch.profile_id, profile_digest = profile_digest, policy_ref = launch.policy_ref, policy_digest = launch_policy.digest,
        catalog_generation = snapshot.generation, mode = chosen, plan_digest = plan_digest}, nil
end
-- A caller composing a larger host plan can retain the same snapshot for
-- its other declarations; this read performs no registry mutation or admission.
function M.read(pinned: catalog.Pinned, definition_ref: string, mode: string?): (Plan?, Reply?)
    local launch, definition_error = read_definition(pinned, definition_ref)
    if not launch then return nil, fail("NOT_FOUND", definition_error or "definition") end
    return resolve(pinned, launch, mode)
end
function M.resolve(definition_ref: string, mode: string?): (Plan?, Reply?)
    local pinned, pin_error = catalog.pin()
    if not pinned then return nil, fail("UNAVAILABLE", pin_error or "pin the registry") end
    return M.read(pinned, definition_ref, mode)
end
function M.decode_request(value: unknown): (Request?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local unknown_field = bounds.fields(object, {"request_id", "definition_ref", "workspace_id", "brief", "mode", "workdir", "thread_id", "expected_plan_digest"})
    if unknown_field then return nil, unknown_field end
    local request_id, definition_ref, workspace_id = bounds.id(object.request_id), bounds.id(object.definition_ref), bounds.id(object.workspace_id)
    if not request_id then return nil, "request_id is not an identifier" end
    if not definition_ref then return nil, "definition_ref is not an identifier" end
    if not workspace_id then return nil, "workspace_id is not an identifier" end
    local brief = bounds.text(object.brief, M.MAX_BRIEF_BYTES)
    if not brief then return nil, "brief must be bounded text" end
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
    return {request_id = request_id, definition_ref = definition_ref, workspace_id = workspace_id, brief = brief, mode = mode, workdir = workdir, thread_id = thread_id,
        expected_plan_digest = expected_plan_digest}, nil
end
-- The durable identities of a request: the same request id always names
-- the same action and attempt.
function M.identities(request_id: string): {action_id: string, attempt_id: string}
    return {action_id = "action:" .. request_id, attempt_id = "attempt:" .. request_id}
end

-- Configuration is deliberately deferred until a user has selected a plan.
-- Listing reads declarations only; it never invokes provider code.  Admission
-- runs this existing empty-scope boundary before it creates a thread, attempt,
-- credential projection or native PTY.
local function preflight_configuration(pinned: catalog.Pinned, plan: Plan): Reply?
    local configure_target, configure_error = resolver.configure(pinned, plan.binding_ref)
    if not configure_target then return fail("UNAVAILABLE", configure_error or "binding configure") end
    local policy_entry = catalog.entry(pinned, plan.policy_ref)
    if not policy_entry then return fail("NOT_FOUND", "launch policy " .. plan.policy_ref .. " is not in the registry") end
    local launch_policy, policy_error = policy.decode(plan.policy_ref, policy_entry)
    if not launch_policy then return fail("NOT_FOUND", policy_error or "policy") end
    local provider_entry = nil
    if launch_policy.provider_ref then
        provider_entry = catalog.entry(pinned, launch_policy.provider_ref)
        if not provider_entry then return fail("UNAVAILABLE", "provider " .. launch_policy.provider_ref .. " is not in the registry") end
    end
    local _, configuration_error = configuration.call(configure_target, {
        provider_ref = launch_policy.provider_ref,
        provider = provider_entry,
        fixture = launch_policy.fixture,
    })
    if configuration_error then return fail("UNAVAILABLE", "launch policy " .. plan.policy_ref .. " configuration: " .. configuration_error) end
    return nil
end
-- admit: for the authenticated requester, resolve the plan, settle the
-- thread, obtain the attempt-bound resource grant and credential
-- projections in the requester's own authority, and return the carrier
-- request. Every acquisition keys on the request id, so a retry replays.
function M.admit_request(value: unknown): (Admitted?, Reply?)
    local request, decode_error = M.decode_request(value)
    if not request then return nil, fail("INVALID", decode_error or "invalid request") end
    local requester = actor()
    if not requester then return nil, fail("UNAUTHENTICATED", "no actor") end
    local pinned, pin_error = catalog.pin()
    if not pinned then return nil, fail("UNAVAILABLE", pin_error or "pin the registry") end
    local launch, definition_error = read_definition(pinned, request.definition_ref)
    if not launch then return nil, fail("NOT_FOUND", definition_error or "definition") end
    local plan, plan_refused = resolve(pinned, launch, request.mode)
    if not plan then return nil, plan_refused end
    if request.expected_plan_digest and request.expected_plan_digest ~= plan.plan_digest then
        return nil, fail("CONFLICT", "the selected launch plan changed; resolve it again before starting")
    end
    local configuration_refused = preflight_configuration(pinned, plan)
    if configuration_refused then return nil, configuration_refused end
    if request.brief == "" and plan.mode ~= "window" then return nil, fail("INVALID", "a structured launch needs a nonempty brief") end
    if request.workdir and not definition.allows(launch, "workdir") then return nil, fail("FORBIDDEN", "definition does not allow a workdir override") end
    if request.thread_id and not definition.allows(launch, "thread") then return nil, fail("FORBIDDEN", "definition does not allow a thread override") end
    local ids = M.identities(request.request_id)
    local thread_id = request.thread_id
    if launch.thread_policy.kind == "named" then thread_id = launch.thread_policy.thread_ref end
    if not thread_id and launch.thread_policy.kind == "caller" then return nil, fail("INVALID", "definition expects the caller's thread") end
    local workdir_name = request.workdir
    if launch.workdir_policy.kind == "declared_resource" then workdir_name = launch.workdir_policy.resource_ref end
    if launch.workdir_policy.kind == "required" and not workdir_name then return nil, fail("INVALID", "definition requires a working directory resource") end
    local session_resource = launch.session_resource
    if session_resource and workdir_name == session_resource then
        return nil, fail("INVALID", "workdir resource duplicates the session resource")
    end
    -- Session authority is selected by the host definition. A retained
    -- session gets one stable digest-derived identity per launch request, while the
    -- default remains ephemeral and receives no session grant.
    local resources: {placement_types.ResourceGrant} = {}
    local session_ref: string? = nil
    if session_resource then
        local session_digest, session_error = digest_of({workspace_id = request.workspace_id, request_id = request.request_id})
        if not session_digest then return nil, fail("UNAVAILABLE", tostring(session_error or "derive retained session identity")) end
        session_ref = "session:" .. session_digest
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
    local carrier_request: carrier.Request = {thread_id = thread_id, action_id = ids.action_id, attempt_id = ids.attempt_id, owner_id = requester, owner_incarnation = 1,
        binding_ref = plan.binding_ref, profile_id = plan.profile_id, brief = request.brief, policy_ref = plan.policy_ref, resources = resources, environment = {},
        working_directory = working, projections = projections, workspace_id = request.workspace_id, session_ref = session_ref}
    return {plan = plan, request = carrier_request, requester = requester, thread_id = thread_id, action_id = ids.action_id, attempt_id = ids.attempt_id, session_ref = session_ref}, nil
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
