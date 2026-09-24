-- MIT. A managed launch a caller starts on its own authority: an agent
-- through the gateway or an application through its facade. It resolves and
-- fences the measured plan, runs first-use setup (associating a chosen
-- folder as the working directory), and starts the child through the
-- ordinary launch admission and carrier path. Every acquisition underneath
-- keys on the caller's own actor and workspace; it mints no grant,
-- credential, trait or overlay authority of its own.
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local agent_launch = require("agent_launch")
local agent_protocol = require("agent_protocol")
local definitions = require("definitions")
local M = {}
M.START = "bee.harness.launch:start"
M.RESOLVE = "bee.harness.launch:resolve"
M.SETUP = "bee.harness.launch:setup"
M.EXECUTION_SCOPE = "bee.harness.launch:agent_launch_execution_scope"
type Reply = {ok: boolean, error: {code: string, message: string}?, value: unknown}
type Fault = {code: string, message: string}
-- identity keys the request: the same identity and retry key replay one
-- child. thread_id is the caller's own thread, used when the request names
-- none and the definition runs on the caller's thread.
type Caller = {workspace_id: string, identity: string, thread_id: string?, parent_action_id: string?,
    origin_view: {view_id: string, instance_id: string}?}
local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end
local function reply_of(value: unknown): ({[string]: unknown}?, Fault?)
    local object = bounds.object(value)
    if not object then return nil, {code = "INTERNAL", message = "the launch did not answer"} end
    if object.ok ~= true then
        local fault = bounds.object(object.error)
        return nil, {code = tostring(fault and fault.code or "REFUSED"), message = tostring(fault and fault.message or "the launch was refused")}
    end
    local admitted = bounds.object(object.value)
    if not admitted then return nil, {code = "INTERNAL", message = "the launch admission returned no value"} end
    return admitted, nil
end
-- The executor a facade runs the launch pipeline with: the caller's own
-- actor in the host-named launch scope. A caller launching into a workspace
-- other than the one it is bound to must hold the launch action on that
-- workspace in its own scope; the pipeline then runs as the same actor bound
-- to that workspace.
function M.executor(requested: string?, bound: string?): (funcs.Executor?, Fault?)
    local executor = funcs.new()
    if requested and requested ~= bound then
        if not security.can(agent_launch.LAUNCH_ACTION, requested) then
            return nil, {code = "DENIED", message = "this caller may not launch into workspace " .. requested}
        end
        local current = security.actor()
        local id = current and bounds.id(current:id())
        if not id then return nil, {code = "UNAUTHENTICATED", message = "the call has no actor"} end
        local actor, actor_error = security.new_actor(id, {workspace_id = requested})
        if not actor then return nil, {code = "DENIED", message = tostring(actor_error)} end
        local acted, acted_error = executor:with_actor(actor)
        if not acted then return nil, {code = "DENIED", message = tostring(acted_error)} end
        executor = acted
    end
    local scope, scope_error = security.named_scope(M.EXECUTION_SCOPE)
    if not scope then return nil, {code = "UNAVAILABLE", message = tostring(scope_error or "the agent launch scope is unavailable")} end
    local scoped, executor_error = executor:with_scope(scope)
    if not scoped then return nil, {code = "DENIED", message = tostring(executor_error or "the agent launch scope is denied")} end
    return scoped, nil
end
function M.start(caller: Caller, request: agent_protocol.Launch, definition: definitions.Definition): Reply
    if definition.default_mode == "window" then
        return fail("LAUNCH_MODE_UNSUPPORTED", "a window definition has no agent-launch carrier; launch a session or batch definition")
    end
    -- Resolve and fence the measured plan once, so the child starts under the
    -- exact plan the caller's authority admitted and not one that changed
    -- underneath.
    local resolved, resolve_error = funcs.call(M.RESOLVE, {definition_ref = request.definition_ref, mode = definition.default_mode, workspace_id = caller.workspace_id,
        saved_profile_id = request.saved_profile_id, saved_profile_revision = request.saved_profile_revision})
    if resolve_error then return fail("UNAVAILABLE", tostring(resolve_error)) end
    local plan, resolve_fault = reply_of(resolved)
    if not plan then return fail(resolve_fault.code, resolve_fault.message) end
    local plan_digest = bounds.text(plan.plan_digest, 64)
    if not plan_digest or #plan_digest ~= 64 then return fail("INTERNAL", "the launch plan has no digest") end
    local overrides = bounds.ids(plan.overrides, true)
    if not overrides then return fail("INTERNAL", "the launch plan has no overrides") end
    if request.workdir and not bounds.member("workdir", overrides) then
        return fail("FORBIDDEN", "the launch does not allow a workdir override")
    end
    -- First-use setup associates the definition's resource roots, and a
    -- chosen folder, in the caller's own workspace, exactly as a human launch
    -- does before admission; it grants nothing by itself.
    local folder: {[string]: unknown}? = nil
    local workdir = request.workdir
    if workdir and workdir.root_ref then folder = {root_ref = workdir.root_ref, path = workdir.path} end
    local setup, setup_error = funcs.call(M.SETUP, {workspace_id = caller.workspace_id, definition_ref = request.definition_ref, expected_plan_digest = plan_digest,
        saved_profile_id = request.saved_profile_id, saved_profile_revision = request.saved_profile_revision, workdir = folder})
    if setup_error then return fail("UNAVAILABLE", tostring(setup_error)) end
    local prepared = bounds.object(setup)
    if not prepared or prepared.ok ~= true then
        return fail("UNAVAILABLE", tostring(prepared and prepared.error or "the launch resource setup failed"))
    end
    local workdir_name: string? = workdir and workdir.resource or nil
    if folder then
        workdir_name = bounds.id(prepared.workdir)
        if not workdir_name then return fail("INTERNAL", "setup named no working directory for the chosen folder") end
    end
    local thread_id, thread_title = caller.thread_id, nil
    local thread = request.thread
    if thread then thread_id, thread_title = thread.thread_id, thread.title end
    -- The child request identity is the caller's identity plus the retry key:
    -- the same call replays one child action and attempt, and a changed brief
    -- under the same key conflicts instead of starting a second child.
    local request_id, identity_error = agent_launch.request_id(caller.identity, request.idempotency_key)
    if not request_id then return fail("INVALID", identity_error or "the request identity failed") end
    local started, start_error = funcs.call(M.START, {request_id = request_id, definition_ref = request.definition_ref, workspace_id = caller.workspace_id,
        brief = request.brief, thread_id = thread_id, thread_title = thread_title, workdir = workdir_name, placement = request.placement,
        saved_profile_id = request.saved_profile_id, saved_profile_revision = request.saved_profile_revision,
        parent_action_id = caller.parent_action_id, expected_plan_digest = plan_digest, origin_view = caller.origin_view})
    if start_error then return fail("UNAVAILABLE", tostring(start_error)) end
    local admitted, start_fault = reply_of(started)
    if not admitted then return fail(start_fault.code, start_fault.message) end
    local child_thread, child_action, child_attempt = bounds.id(admitted.thread_id), bounds.id(admitted.action_id), bounds.id(admitted.attempt_id)
    if not child_thread or not child_action or not child_attempt then return fail("INTERNAL", "the launch admission is incomplete") end
    -- The durable child identities together with the launch definition and
    -- the exact bounded brief that selected it, so a caller can label the
    -- child without re-resolving a registry entry.
    return {ok = true, error = nil, value = {thread_id = child_thread, action_id = child_action, attempt_id = child_attempt,
        definition_ref = definition.ref, title = definition.title, brief = request.brief}}
end
return M
