-- MIT. Launch admission: resolve a definition into a measured plan with no
-- effects, then admit a request for the authenticated requester, obtaining
-- attempt-bound grants and credential projections in that requester's own
-- authority, and start the carrier with a durable identity so a retry
-- after an ambiguous start recovers the same attempt.
local hash = require("hash")
local funcs = require("funcs")
local process = require("process")
local security = require("security")
local time = require("time")
local bounds = require("bounds")
local canonical = require("canonical")
local catalog = require("catalog")
local policy = require("policy")
local definition = require("definition")
local M = {}
M.CARRIER = "bee.harness.carrier:process"
M.CARRIER_HOST = "bee:workers"
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
type Request = {
    request_id: string,
    definition_ref: string,
    workspace_id: string,
    brief: string,
    mode: string?,
    workdir: string?,
    thread_id: string?,
    environment: {[string]: string},
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
-- resolve: the measured plan for a definition, with no effects. The plan
-- digest pins the definition, the binding and profile measurements and
-- the launch policy at one catalog generation.
function M.resolve(definition_ref: string, mode: string?): (Plan?, Reply?)
    local launch, definition_error = definition.load(definition_ref)
    if not launch then return nil, fail("NOT_FOUND", definition_error or "definition") end
    local chosen = launch.default_mode
    if mode and mode ~= chosen then
        if not definition.allows(launch, "mode") then return nil, fail("FORBIDDEN", "definition " .. definition_ref .. " does not allow a mode override") end
        if not bounds.member(mode, definition.MODES) then return nil, fail("INVALID", "mode must be window, session or batch") end
        chosen = mode
    end
    local snapshot, snapshot_error = catalog.snapshot()
    if not snapshot then return nil, fail("UNAVAILABLE", snapshot_error or "catalog") end
    local usable, usable_error = catalog.usable(snapshot)
    if not usable then return nil, fail("UNAVAILABLE", usable_error or "catalog") end
    local binding_digest, profile_digest = "", ""
    local supported = false
    for _, candidate in ipairs(usable) do
        if candidate.binding_id == launch.binding_ref then
            binding_digest = candidate.binding_digest.entry
            profile_digest = candidate.profile_digest.entry
            for _, profile in ipairs(candidate.profiles) do
                if profile.id == launch.profile_id and profile.supported and profile.mode == chosen then supported = true end
            end
        end
    end
    if binding_digest == "" then return nil, fail("UNAVAILABLE", "binding " .. launch.binding_ref .. " is not usable on this host") end
    if not supported then return nil, fail("UNSUPPORTED_CAPABILITY", "profile " .. launch.profile_id .. " of " .. launch.binding_ref .. " does not run in mode " .. chosen) end
    local launch_policy, policy_error = policy.load(launch.policy_ref)
    if not launch_policy then return nil, fail("NOT_FOUND", policy_error or "policy") end
    local plan_digest, digest_error = digest_of({definition = launch.digest, binding = binding_digest, profile = profile_digest, policy = launch_policy.digest, mode = chosen})
    if not plan_digest then return nil, fail("INVALID", digest_error or "plan") end
    return {definition_ref = definition_ref, definition_digest = launch.digest, launch_id = launch.launch_id, binding_ref = launch.binding_ref, binding_digest = binding_digest,
        profile_id = launch.profile_id, profile_digest = profile_digest, policy_ref = launch.policy_ref, policy_digest = launch_policy.digest,
        catalog_generation = snapshot.generation, mode = chosen, plan_digest = plan_digest}, nil
end
function M.decode_request(value: unknown): (Request?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local unknown_field = bounds.fields(object, {"request_id", "definition_ref", "workspace_id", "brief", "mode", "workdir", "thread_id", "environment"})
    if unknown_field then return nil, unknown_field end
    local request_id, definition_ref, workspace_id = bounds.id(object.request_id), bounds.id(object.definition_ref), bounds.id(object.workspace_id)
    if not request_id then return nil, "request_id is not an identifier" end
    if not definition_ref then return nil, "definition_ref is not an identifier" end
    if not workspace_id then return nil, "workspace_id is not an identifier" end
    local brief = bounds.text(object.brief, M.MAX_BRIEF_BYTES)
    if not brief or brief == "" then return nil, "brief must be nonempty bounded text" end
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
    local environment: {[string]: string} = {}
    if object.environment ~= nil then
        local declared = bounds.object(object.environment)
        if not declared then return nil, "environment must be an object" end
        for name, item in pairs(declared) do
            local text = bounds.text(item, 4096)
            if not name:match("^[A-Z_][A-Z0-9_]*$") or not text then return nil, "environment." .. name .. " is not a variable" end
            environment[name] = text
        end
    end
    return {request_id = request_id, definition_ref = definition_ref, workspace_id = workspace_id, brief = brief, mode = mode, workdir = workdir, thread_id = thread_id, environment = environment}, nil
end
-- The durable identities of a request: the same request id always names
-- the same action and attempt.
function M.identities(request_id: string): {action_id: string, attempt_id: string}
    return {action_id = "action:" .. request_id, attempt_id = "attempt:" .. request_id}
end
-- admit: for the authenticated requester, resolve the plan, settle the
-- thread, obtain the attempt-bound resource grant and credential
-- projections in the requester's own authority, and return the carrier
-- request. Every acquisition keys on the request id, so a retry replays.
function M.admit(value: unknown): Reply
    local request, decode_error = M.decode_request(value)
    if not request then return fail("INVALID", decode_error or "invalid request") end
    local requester = actor()
    if not requester then return fail("UNAUTHENTICATED", "no actor") end
    local launch, definition_error = definition.load(request.definition_ref)
    if not launch then return fail("NOT_FOUND", definition_error or "definition") end
    local plan, plan_refused = M.resolve(request.definition_ref, request.mode)
    if not plan then return plan_refused :: Reply end
    if request.workdir and not definition.allows(launch, "workdir") then return fail("FORBIDDEN", "definition does not allow a workdir override") end
    if request.thread_id and not definition.allows(launch, "thread") then return fail("FORBIDDEN", "definition does not allow a thread override") end
    local ids = M.identities(request.request_id)
    local thread_id = request.thread_id
    if launch.thread_policy.kind == "named" then thread_id = launch.thread_policy.thread_ref end
    if not thread_id then
        if launch.thread_policy.kind == "caller" then return fail("INVALID", "definition expects the caller's thread") end
        local created, create_refused = call(M.THREADS .. ":create", {thread_id = "thread:" .. request.request_id, idempotency_key = "launch:" .. request.request_id .. ":thread", title = launch.title})
        if not created then return create_refused :: Reply end
        thread_id = tostring(created.thread_id)
    end
    local resources: {{[string]: unknown}} = {}
    local working: string? = nil
    local workdir_name = request.workdir
    if launch.workdir_policy.kind == "declared_resource" then workdir_name = launch.workdir_policy.resource_ref end
    if launch.workdir_policy.kind == "required" and not workdir_name then return fail("INVALID", "definition requires a working directory resource") end
    if workdir_name then
        local granted, grant_refused = call(M.RESOURCES .. ":grant", {workspace_id = request.workspace_id, name = workdir_name, access = "write", purpose = "project",
            audience = requester, attempt_id = ids.attempt_id, idempotency_key = "launch:" .. request.request_id .. ":workdir"})
        if not granted then return grant_refused :: Reply end
        resources[1] = {name = workdir_name, grant_ref = tostring(granted.grant_id), root_ref = tostring(granted.root_ref), subpath = tostring(granted.subpath), access = "write", purpose = "project"}
        working = workdir_name
    end
    local projections: {string} = {}
    for index, credential in ipairs(launch.credentials) do
        local issued, issue_refused = call(M.CREDENTIALS .. ":issue_projection", {workspace_id = request.workspace_id, name = credential, audience = requester, attempt_id = ids.attempt_id,
            profile_id = plan.profile_id, profile_digest = plan.profile_digest, binding_digest = plan.binding_digest, launch_policy_digest = plan.policy_digest,
            idempotency_key = "launch:" .. request.request_id .. ":credential:" .. tostring(index)})
        if not issued then return issue_refused :: Reply end
        projections[index] = tostring(issued.projection_id)
    end
    local carrier_request: {[string]: unknown} = {thread_id = thread_id, action_id = ids.action_id, attempt_id = ids.attempt_id, owner_id = requester, owner_incarnation = 1,
        binding_ref = plan.binding_ref, profile_id = plan.profile_id, brief = request.brief, policy_ref = plan.policy_ref, resources = resources, environment = request.environment,
        working_directory = working, projections = projections}
    return succeed({plan = plan, request = carrier_request, requester = requester, thread_id = thread_id, action_id = ids.action_id, attempt_id = ids.attempt_id})
end
-- start: admit, then spawn the carrier as the requester. A retry with the
-- same request id finds the attempt's checkpoint and resumes it instead of
-- opening a second one.
function M.start(value: unknown): Reply
    local admitted = M.admit(value)
    if not admitted.ok then return admitted end
    local outcome = admitted.value :: {[string]: unknown}
    local carrier_request = outcome.request :: {[string]: unknown}
    local stored = call(M.CARRIER_OPS .. ":checkpoint", {thread_id = outcome.thread_id, attempt_id = outcome.attempt_id})
    local mode = "open"
    if stored then
        if stored.attempt_state == "ended" then return fail("CONFLICT", "request " .. tostring(outcome.attempt_id) .. " already settled") end
        if stored.checkpoint ~= nil then mode = "resume" end
    end
    -- The carrier outlives this call; whoever routes the launch monitors it.
    local pid, spawn_error = process.with_context({}):spawn(M.CARRIER, M.CARRIER_HOST, carrier_request, mode, process.pid())
    if not pid then return fail("UNAVAILABLE", "spawn carrier: " .. tostring(spawn_error)) end
    outcome.carrier = tostring(pid)
    outcome.mode = mode
    outcome.started_at = time.now():utc():format("2006-01-02T15:04:05.000Z07:00")
    return succeed(outcome)
end
return M
