-- MIT. Sessions owns admission and the public session operations; Threads
-- remains the only durable store.
local bounds = require("bounds")
local json = require("json")
local journal = require("journal")
local admission = require("admission")
local catalog_service = require("catalog_service")
local hash = require("hash")
local canonical = require("canonical")
local profile_values = require("profile_values")
local security = require("security")
local funcs = require("funcs")
local cancellation = require("cancellation")
local time = require("time")
local logger = require("logger")
local session_protocol = require("session_protocol")
local record_values = require("record_values")
local remote = require("remote")
local system = require("system")
local M = {}

type Object = {[string]: unknown}
type Reply = {ok: boolean, value?: unknown, error?: Object}

local function object(value: unknown): Object?
    return bounds.object(value)
end

local function fail(code: string, message: string, operation_key: string?): Reply
    local error: Object = {code = code, message = message, retry = "never"}
    if operation_key then error.operation_key = operation_key end
    return {ok = false, error = error}
end

local function unavailable(message: string, operation_key: string?): Reply
    local reply = fail("UNAVAILABLE", message, operation_key)
    local failure = reply.error
    if failure then failure.retry = "refresh" end
    return reply
end

local function succeed(value: unknown): Reply
    return {ok = true, value = value}
end

local function request_input(request: unknown): (Object?, Reply?)
    local input = object(request)
    if not input then return nil, fail("INVALID", "request must be an object", nil) end
    return input, nil
end

local function identity(): (string?, string?)
    local caller = security.actor()
    if not caller then return nil, nil end
    local id = bounds.id(caller:id())
    local meta = object(caller:meta())
    local workspace = meta and bounds.id(meta.workspace_id)
    if not id or not workspace then return nil, nil end
    return id, workspace
end

local function key(value: unknown): string?
    if type(value) ~= "string" or #value < 1 or #value > 128 or value:find("%c") then return nil end
    return value
end

local function ref(value: unknown): string?
    if type(value) ~= "string" or #value < 1 or #value > 256 or value:find("%c") then return nil end
    return value
end

local function snapshot(value: unknown): (Object?, string?)
    local row = object(value)
    if not row or type(row.session) ~= "string" or type(row.title) ~= "string"
        or type(row.state) ~= "string" or type(row.revision) ~= "number" then
        return nil, "Threads returned a malformed session snapshot"
    end
    local queued = type(row.queued) == "number" and row.queued or 0
    local lifecycle = row.state
    if lifecycle ~= "active" and lifecycle ~= "suspended" and lifecycle ~= "closing" and lifecycle ~= "closed" then
        return nil, "Threads returned an unsupported session lifecycle"
    end
    local activity = row.activity
    if activity ~= "idle" and activity ~= "working" and activity ~= "blocked" and activity ~= "stalled" then
        return nil, "Threads returned an unsupported session activity"
    end
    local activity_evidence: Object? = nil
    if row.activity_evidence ~= nil then
        local evidence = object(row.activity_evidence)
        local turn = evidence and ref(evidence.turn)
        local last = evidence and bounds.count(evidence.last_progress_at_ms)
        local quiet_period = evidence and bounds.count(evidence.quiet_period_ms)
        local quiet_for = evidence and bounds.count(evidence.quiet_for_ms)
        if not evidence or bounds.fields(evidence, {"kind", "turn", "last_progress_at_ms", "quiet_period_ms", "quiet_for_ms"})
            or evidence.kind ~= "quiet" or not turn or not last or not quiet_period or quiet_period < 1
            or not quiet_for or quiet_for < quiet_period then
            return nil, "Threads returned malformed quiet-period evidence"
        end
        activity_evidence = {kind = "quiet", turn = turn, last_progress_at_ms = last,
            quiet_period_ms = quiet_period, quiet_for_ms = quiet_for}
    end
    local at = type(row.updated_at) == "string" and row.updated_at or row.created_at
    if type(at) ~= "string" then return nil, "Threads omitted the session timestamp" end
    local route = object(row.route) or {}
    local saved_profile: Object? = nil
    if route.saved_profile_id ~= nil or route.saved_profile_revision ~= nil then
        local id, revision = ref(route.saved_profile_id), bounds.integer(route.saved_profile_revision)
        if not id or not revision or revision < 1 then return nil, "Session saved profile is malformed" end
        saved_profile = {id = id, revision = revision}
    end
    local limits: Object = table.create(0, 1)
    for name, limit in pairs(object(route.budgets) or {}) do limits[name] = limit end
    return {terminal = route.delivery == "hook", session = row.session, thread_ref = row.thread_ref, workspace = row.workspace,
        driver = route.driver_binding_ref, provider = route.provider, definition = route.definition, last_result = row.last_result,
        revision = row.revision, incarnation = 1, title = row.title,
        lifecycle = lifecycle, activity = activity, activity_evidence = activity_evidence,
        execution = {state = row.execution_running == true and "running" or "quiescent", evidence_at = at, stale = false},
        queue_count = queued, effective_limits = limits,
        saved_profile = saved_profile, effective_profile = profile_values.upgrade(route.effective_profile), profile_digest = route.profile_digest, budget_consumption = row.budget_consumption, continuity = {mode = "provider_resume"}, actions = {}}, nil
end

local finish_closing: (string, string) -> string?
local deliver: (string, string) -> string?
local TYPE = "bee.harness.binding:present_type"
local RESUME = "bee.harness.binding:present_restore"
local ACTIVITY = "bee.harness.binding:present_activity"

local function describe(session: string): (Object?, string?)
    local value, err = journal.invoke("session_describe", {session = session})
    if err or not value then return nil, err or "Threads returned no session" end
    return snapshot(value)
end

function M.source_identity(raw: unknown): Reply
    local asked = bounds.object(raw)
    if not asked or bounds.fields(asked, {}) then return fail("INVALID", "source identity takes no fields", nil) end
    local actor, workspace = identity()
    if not actor or not actor:match("^bs:") then return succeed({}) end
    local stored, err = journal.invoke("session_describe", {session = actor})
    local value = bounds.object(stored)
    if not value or err then return fail("DENIED", "source session is unavailable", nil) end
    return succeed({session = actor, thread_id = value.thread_ref, workspace_id = workspace})
end

-- open starts a session: the agent's own program runs in a terminal that
-- Bee keeps whether or not anyone watches it. Messages are typed into it;
-- the person opens its terminal from Sessions.
function M.open(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local operation_key = key(request.operation_key)
    local spec = object(request.spec)
    if not operation_key or not spec or bounds.fields(spec, {"definition", "profile", "workdir", "workspace", "overrides"}) then
        return fail("INVALID", "open requires a definition, optional profile/workdir/workspace, and operation_key", operation_key)
    end
    local copied: Object = {}
    for name, value in pairs(spec) do copied[name] = value end
    spec = copied
    local overrides, override_error = profile_values.overrides(spec.overrides)
    if not overrides then return fail("INVALID", override_error or "invalid spawn overrides", operation_key) end
    if overrides.workdir and spec.workdir ~= nil then return fail("INVALID", "workdir is specified twice", operation_key) end
    if overrides.workspace and spec.workspace ~= nil then return fail("INVALID", "workspace is specified twice", operation_key) end
    spec.workdir = overrides.workdir or spec.workdir
    spec.workspace = overrides.workspace or spec.workspace
    if spec.overrides ~= nil then
        local normalized: {[string]: unknown} = {}
        for key, value in pairs(overrides) do if key ~= "workspace" and key ~= "workdir" then normalized[key] = value end end
        spec.overrides = normalized
    end
    local definition = ref(spec.definition)
    if not definition then return fail("INVALID", "definition is not a ref", operation_key) end
    local profile = object(spec.profile)
    if spec.profile ~= nil then
        local profile_id = profile and ref(profile.id)
        local profile_revision = profile and bounds.integer(profile.revision)
        if not profile or bounds.fields(profile, {"id", "revision"}) or not profile_id or not profile_revision or profile_revision < 1 then
            return fail("INVALID", "profile is malformed", operation_key)
        end
    end
    local workdir: profile_values.Workdir? = nil
    if spec.workdir ~= nil then
        workdir = profile_values.workdir(spec.workdir)
        if not workdir then return fail("INVALID", "workdir must be {root_ref, path} with a path inside the root", operation_key) end
    end
    local owner_id, workspace = identity()
    if not owner_id or not workspace then return fail("DENIED", "the authenticated caller has no workspace identity", operation_key) end
    if not security.can("bee.harness.launch", definition) then
        return fail("DENIED", "opening " .. definition .. " requires a launch grant for that definition", operation_key)
    end
    if spec.workspace ~= nil then
        local target_workspace = bounds.id(spec.workspace)
        if not target_workspace or #target_workspace ~= 32 or target_workspace:find("[^0-9a-f]") then return fail("INVALID", "workspace must be a canonical workspace ID", operation_key) end
        if target_workspace ~= workspace then
            if not security.can("bee.sessions.workspace.open", target_workspace) then return fail("DENIED", "opening in another workspace requires its host grant", operation_key) end
            local actor, actor_error = security.new_actor(owner_id, {workspace_id = target_workspace})
            if not actor then return unavailable(tostring(actor_error), operation_key) end
            local executor, executor_error = funcs.new():with_actor(actor)
            if not executor then return unavailable(tostring(executor_error), operation_key) end
            local raw, call_error = executor:call("bee.threads.sessions.binding:open", {spec = {definition = definition, profile = profile, workdir = workdir, overrides = spec.overrides}, operation_key = operation_key})
            if call_error then return unavailable(tostring(call_error), operation_key) end
            local reply = object(raw)
            if not reply or type(reply.ok) ~= "boolean" then return unavailable("cross-workspace owner returned a malformed reply", operation_key) end
            return {ok = reply.ok, value = reply.value, error = object(reply.error)}
        end
    end
    local prior_raw, prior_error = journal.invoke("operation_lookup", {operation_key = operation_key})
    local prior = object(prior_raw)
    if prior_error or not prior then return unavailable(prior_error or "open operation lookup unavailable", operation_key) end
    if prior.found == true and prior.operation ~= "session_create" then return fail("CONFLICT", "open key belongs to another operation", operation_key) end
    local raw, call_error = funcs.call("bee.harness.binding:present", {spec = {definition = definition, profile = profile, workdir = workdir, overrides = spec.overrides}, operation_key = operation_key})
    local reply = object(raw)
    if call_error or not reply or reply.ok ~= true then
        local fault = reply and object(reply.error)
        return fail(fault and tostring(fault.code) or "UNAVAILABLE", tostring(call_error or (fault and fault.message) or "the session's terminal is unavailable"), operation_key)
    end
    local receipt = object(reply.value)
    local session = receipt and ref(receipt.session)
    if not session or not receipt then return unavailable("the session's terminal omitted its session", operation_key) end
    local current, err = describe(session)
    if not current then return unavailable(err or "session snapshot unavailable", operation_key) end
    if overrides.input ~= nil then
        local sent = M.send({session = session, input = overrides.input, operation_key = "open-input:" .. assert(hash.sha256(operation_key))})
        if not sent.ok then return sent end
    end
    return succeed({session = session, operation = receipt.operation, snapshot = current})
end

function M.attach(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local operation_key = key(request.operation_key)
    local definition, thread = ref(request.definition), bounds.id(request.thread_id)
    local origin = bounds.id(request.origin_request_id)
    if not operation_key or not definition or not thread or not origin or bounds.fields(request, {"operation_key", "definition", "thread_id", "plan_digest", "saved_profile_id", "saved_profile_revision", "attempt_id", "origin_request_id", "overrides"}) then return fail("INVALID", "interactive attach identities are incomplete", operation_key) end
    if not security.can("bee.sessions.attach", definition) then return fail("DENIED", "interactive attach requires a host grant", operation_key) end
    local _, workspace = identity()
    if not workspace then return fail("DENIED", "interactive attach has no workspace", operation_key) end
    local profile_id = request.saved_profile_id == nil and nil or ref(request.saved_profile_id)
    local revision = request.saved_profile_revision == nil and nil or bounds.integer(request.saved_profile_revision)
    local pinned, refused = admission.resolve(definition, "window", workspace, profile_id, revision, nil, nil, nil, nil, request.overrides)
    local plan = object(pinned)
    if not plan then return unavailable(tostring(refused and refused.error and refused.error.message or "interactive plan is unavailable"), operation_key) end
    if plan.plan_digest ~= request.plan_digest or plan.mode ~= "window" then return fail("CONFLICT", "interactive attach plan changed", operation_key) end
    local driver = ref(plan.binding_ref)
    if not driver then return unavailable("interactive plan omitted its driver", operation_key) end
    local prior_raw, lookup_error = journal.invoke("operation_lookup", {operation_key = operation_key})
    local prior = object(prior_raw)
    if lookup_error or not prior then return unavailable(lookup_error or "interactive operation lookup unavailable", operation_key) end
    local created: unknown = nil
    local err: string? = nil
    if prior.found == true then
        if prior.operation ~= "session_create" then return fail("CONFLICT", "interactive key belongs to another operation", operation_key) end
        created = prior.receipt
        local receipt = object(created)
        local existing, read_error = journal.invoke("session_describe", {session = receipt and receipt.session})
        local stored = object(existing)
        local route = stored and object(stored.route)
        if read_error or not stored or stored.thread_ref ~= thread or not route or route.definition ~= definition
            or route.driver_binding_ref ~= driver or route.profile_id ~= plan.profile_id then
            return fail("CONFLICT", "interactive key belongs to another admitted window", operation_key)
        end
    else
        created, err = journal.invoke("session_create", {thread_id = thread, operation_key = operation_key,
            title = plan.title or definition, route = {trait_ceiling = plan.trait_ceiling, definition = definition, plan_digest = plan.plan_digest,
                delivery = "hook", driver_binding_ref = driver, provider = bounds.id(plan.driver_id), effective_profile = plan.effective_profile, profile_digest = plan.effective_profile_digest, overrides = request.overrides,
                saved_profile_id = profile_id, saved_profile_revision = revision, profile_id = plan.profile_id, placement_methods = plan.placement_methods,
                origin_request_id = origin, operation_key = operation_key}})
        if err or not created then return unavailable(err or "interactive session is unavailable", operation_key) end
    end
    local receipt = object(created)
    local existing, existing_error = journal.invoke("session_describe", {session = receipt and receipt.session})
    local current = object(existing)
    local previous = current and object(current.route)
    local active = current and object(current.active_turn)
    if existing_error then return unavailable(existing_error, operation_key) end
    -- A turn the replaced terminal accepted ends without a proven result. A
    -- reserved turn reached no agent; it waits for the new terminal to start.
    if active and active.phase == "accepted" and previous and previous.native_attempt_id ~= request.attempt_id then
        local recovered, recovery_error = journal.invoke("turn_recover", {turn = active.turn,
            operation_key = "attach-recover:" .. tostring(request.attempt_id)})
        local claim = object(recovered)
        if recovery_error or not claim then return unavailable(recovery_error or "interactive recovery unavailable", operation_key) end
        local _, mark_error = journal.invoke("work_uncertain", {turn = active.turn, claim = claim.claim,
            operation_key = "attach-uncertain:" .. tostring(request.attempt_id),
            evidence = {summary = "interactive attachment ended without a proven turn result", artifacts = {}}})
        if mark_error then return unavailable(mark_error, operation_key) end
    end
    local attached, attach_error = journal.invoke("session_attach", {session = receipt and receipt.session, attempt_id = request.attempt_id, operation_key = "attach:" .. tostring(request.attempt_id)})
    if attach_error or not attached then return unavailable(attach_error or "native attachment failed", operation_key) end
    return succeed(created)
end

-- restore reports what reopens a window session whose terminal is gone: the
-- admitted definition and plan, the saved profile, the request that first
-- admitted it, the operation key that created it, its last native attempt and
-- its thread. A window app resumes
-- the native conversation from these facts through admission's continuation.
function M.restore(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local session = ref(request.session)
    if not session or bounds.fields(request, {"session"}) then return fail("INVALID", "restore needs one session ref") end
    local raw, read_error = journal.invoke("session_describe", {session = session})
    local stored = object(raw)
    local route = stored and object(stored.route)
    if read_error or not stored or not route then return unavailable(read_error or "session is unavailable", nil) end
    if route.delivery ~= "hook" then return fail("INVALID", "only a window session has a terminal to restore") end
    local definition = ref(route.definition)
    if not definition then return unavailable("window session omits its definition", nil) end
    if not security.can("bee.sessions.attach", definition) then return fail("DENIED", "window restore requires a host grant") end
    local origin, attempt = bounds.id(route.origin_request_id), bounds.id(route.native_attempt_id)
    local plan_digest, thread, operation_key = bounds.text(route.plan_digest, 128), bounds.id(stored.thread_ref), key(route.operation_key)
    if not origin or not attempt or not plan_digest or not thread or not operation_key then
        return unavailable("window session records no admitted continuation to restore", nil)
    end
    local value: Object = {trait_ceiling = route.trait_ceiling, overrides = route.overrides, session = session, definition_ref = definition, plan_digest = plan_digest,
        origin_request_id = origin, previous_attempt_id = attempt, thread_id = thread, operation_key = operation_key}
    if route.saved_profile_id ~= nil then
        value.saved_profile_id = ref(route.saved_profile_id)
        value.saved_profile_revision = bounds.integer(route.saved_profile_revision)
    end
    return succeed(value)
end

function M.detach(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local session, attempt, operation_key = ref(request.session), bounds.id(request.attempt_id), key(request.operation_key)
    if not session or not attempt or not operation_key or bounds.fields(request, {"session", "attempt_id", "operation_key"}) then
        return fail("INVALID", "interactive detach identities are incomplete", operation_key)
    end
    local raw, read_error = journal.invoke("session_describe", {session = session})
    local stored = object(raw)
    local route = stored and object(stored.route)
    if read_error or not stored or not route then return unavailable(read_error or "interactive session unavailable", operation_key) end
    if not security.can("bee.sessions.attach", tostring(route.definition)) then return fail("DENIED", "interactive detach requires a host grant", operation_key) end
    if route.delivery ~= "hook" or route.native_attempt_id ~= attempt then return fail("STALE", "detach belongs to another attachment", operation_key) end
    local methods = object(route.placement_methods)
    local target = methods and ref(methods.reconcile)
    if not target then return unavailable("interactive route omits placement reconciliation", operation_key) end
    local placement_raw, call_error = funcs.call(target, {attempt_id = attempt})
    local placement = object(placement_raw)
    local value = placement and object(placement.value)
    local evidence = value and (object(value.attempt) or value)
    if call_error or not placement or placement.ok ~= true or not evidence or evidence.attempt_id ~= attempt then
        return unavailable("interactive exit cannot be reconciled", operation_key)
    end
    if evidence.execution_state ~= "exited" or evidence.exit_source == nil then
        return fail("CONFLICT", "interactive attachment has no proven process exit", operation_key)
    end
    local active = object(stored.active_turn)
    if active then
        local recovered, recovery_error = journal.invoke("turn_recover", {turn = active.turn, operation_key = "detach-recover:" .. operation_key})
        local claim = object(recovered)
        if recovery_error or not claim then return unavailable(recovery_error or "interactive claim unavailable", operation_key) end
        local _, mark_error = journal.invoke("work_uncertain", {turn = active.turn, claim = claim.claim,
            operation_key = "detach-uncertain:" .. operation_key,
            evidence = {summary = "interactive process exited without a proven Work result", artifacts = {"placement attempt " .. attempt}}})
        if mark_error then return unavailable(mark_error, operation_key) end
    end
    if stored.state == "active" then
        local transitioned, transition_error = journal.invoke("session_transition", {session = session, state = "suspended", operation_key = operation_key})
        if transition_error or not transitioned then return unavailable(transition_error or "interactive suspension unavailable", operation_key) end
    end
    return succeed({session = session, attempt_id = attempt})
end

-- The turn's result is the agent's final message; a harness whose stop
-- carries no message ended its turn with the reply only on its screen.
local function reply_of(answer: unknown): string
    if type(answer) == "string" then return answer end
    return "The agent ended its turn; its reply is shown in its terminal"
end

-- message_text is what a queued message types into the agent's prompt; a
-- message from another session or a person names its sender the way
-- Sessions lists it.
local HEADER = "[Bee message from "
-- prompt_text is a message's input as the text typed for it.
local function prompt_text(value: unknown): string?
    if type(value) == "string" then return value end
    return (canonical.encode(value, 16384, 16))
end

function M.message_text(input: unknown, sender: Object?, session: string): string?
    local prompt = prompt_text(input)
    if not prompt then return nil end
    if not sender or sender.id == session then return prompt end
    local name = tostring(sender.id)
    if sender.kind == "session" then
        local current = describe(name)
        local title = current and bounds.text(current.title, 512)
        if title and title ~= "" then name = title end
    end
    if #name > 60 then name = name:sub(1, 57) .. "..." end
    return HEADER .. name .. "]\n" .. prompt
end

-- same_prompt is whether the prompt the agent submitted is the message typed
-- for the turn: its body, under the sender line Bee typed above it.
local function same_prompt(typed: string, input: unknown): boolean
    local body = prompt_text(input)
    if not body then return false end
    local function normal(value: string): string
        local unified = value:gsub("\r\n?", "\n")
        return (unified:gsub("%s+$", ""))
    end
    local submitted = normal(typed)
    if submitted:sub(1, #HEADER) == HEADER then
        local newline = submitted:find("\n", 1, true)
        if not newline then return false end
        submitted = submitted:sub(newline + 1)
    end
    return submitted == normal(body)
end

-- claimed is the active turn's current claim, recovered after an owner restart.
local function claimed(active: Object, operation_key: string): (string?, string?)
    local recovered, recovery_error = journal.invoke("turn_recover", {turn = active.turn, operation_key = operation_key})
    local claim = object(recovered)
    local value = claim and bounds.text(claim.claim, 128)
    if recovery_error or not value then return nil, recovery_error or "the turn's claim is unavailable" end
    return value, nil
end

-- launch_prompt hands a window that starts its agent the message waiting for
-- it: the reserved message, or the next queued one, which it reserves. The
-- agent takes it as its launch prompt, so nothing is typed into a terminal
-- that is still starting. A session with nothing waiting has no prompt.
function M.launch_prompt(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local session = ref(request.session)
    if not session or bounds.fields(request, {"session"}) then return fail("INVALID", "launch_prompt needs one session ref") end
    local raw, read_error = journal.invoke("session_describe", {session = session})
    local stored = object(raw)
    local route = stored and object(stored.route)
    if read_error or not stored or not route then return unavailable(read_error or "session is unavailable", nil) end
    if route.delivery ~= "hook" then return fail("INVALID", "only a window session starts a terminal") end
    local definition = ref(route.definition)
    if not definition or not security.can("bee.sessions.attach", definition) then return fail("DENIED", "a launch prompt requires a host grant") end
    if stored.state ~= "active" then return succeed({}) end
    local active = object(stored.active_turn)
    local turn: string? = nil
    local claim: string? = nil
    if active then
        if active.phase ~= "reserved" then return succeed({}) end
        local current, claim_error = claimed(active, "launch-recover:" .. tostring(route.native_attempt_id))
        if not current then return unavailable(claim_error or "the waiting message's claim is unavailable", nil) end
        turn, claim = tostring(active.turn), current
    else
        local reserved, reserve_error = journal.invoke("turn_reserve", {session = session,
            operation_key = "launch:" .. tostring(route.native_attempt_id) .. ":" .. tostring(stored.head_sequence)})
        local next_turn = object(reserved)
        if reserve_error or not next_turn then return unavailable(reserve_error or "the next message could not be reserved", nil) end
        if not next_turn.turn then return succeed({}) end
        turn, claim = tostring(next_turn.turn), tostring(next_turn.claim)
    end
    local pulled, pull_error = journal.invoke("turn_pull", {turn = turn, claim = claim})
    local input = object(pulled)
    local text = input and M.message_text(input.input, object(input.sender), session)
    if pull_error or not input or not text then return unavailable(pull_error or "the waiting message is unreadable", nil) end
    return succeed({prompt = text})
end

-- idle_check tells a window whether it may stop its agent now: no turn is in
-- flight, nothing waits, and the placement proves the agent alive with no
-- work of its own. A placement that cannot count that work keeps it running.
function M.idle_check(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local session = ref(request.session)
    if not session or bounds.fields(request, {"session"}) then return fail("INVALID", "idle_check needs one session ref") end
    local raw, read_error = journal.invoke("session_describe", {session = session})
    local stored = object(raw)
    local route = stored and object(stored.route)
    if read_error or not stored or not route then return unavailable(read_error or "session is unavailable", nil) end
    if route.delivery ~= "hook" then return fail("INVALID", "only a window session runs a terminal") end
    local definition = ref(route.definition)
    if not definition or not security.can("bee.sessions.attach", definition) then return fail("DENIED", "an idle check requires a host grant") end
    if stored.state ~= "active" or stored.active_turn ~= nil or bounds.integer(stored.queued) ~= 0 then return succeed({stop = false}) end
    local attempt = bounds.id(route.native_attempt_id)
    if not attempt then return succeed({stop = false}) end
    return succeed({stop = cancellation.quiet(route.placement_methods, attempt, route)})
end

-- deliver types the session's next queued message into its terminal once
-- that terminal's agent has ended a turn, which proves its input takes typed
-- messages. Until then the message waits: a terminal that is gone or
-- suspended is resumed, and a starting terminal takes the waiting message as
-- its launch prompt (launch_prompt). A message the terminal cannot take
-- settles as failed with the reason.
deliver = function(session: string, key_seed: string): string?
    local raw, read_error = journal.invoke("session_describe", {session = session})
    local stored = object(raw)
    local route = stored and object(stored.route)
    if read_error or not stored or not route then return read_error or "the session is unavailable" end
    if route.delivery ~= "hook" then return nil end
    -- resume makes sure the session's terminal runs; one already running is
    -- left as it is.
    local function resume(): string?
        local resumed, resume_error = funcs.call(RESUME, {session = session})
        local reply = object(resumed)
        if resume_error or not reply or reply.ok ~= true then
            local fault = reply and object(reply.error)
            return tostring(resume_error or (fault and fault.message) or "the session's terminal could not resume")
        end
        return nil
    end
    if stored.state == "suspended" then return resume() end
    if stored.state ~= "active" then return nil end
    local active = object(stored.active_turn)
    -- A reserved turn waits for a terminal; one that is gone, as after a
    -- restart, is resumed and takes it as its launch prompt.
    if active then
        if active.phase == "reserved" then return resume() end
        return nil
    end
    if stored.attempt_turn_ended ~= true then return resume() end
    local reserved, reserve_error = journal.invoke("turn_reserve", {session = session, operation_key = "deliver:" .. key_seed})
    local next_turn = object(reserved)
    if reserve_error or not next_turn then return reserve_error or "the next message could not be reserved" end
    if not next_turn.turn then
        -- Nothing waits: the window may stop an agent nobody uses.
        local _, idle_error = funcs.call(ACTIVITY, {session = session, state = "idle"})
        if idle_error then return tostring(idle_error) end
        return nil
    end
    local turn, claim = tostring(next_turn.turn), tostring(next_turn.claim)
    local pulled, pull_error = journal.invoke("turn_pull", {turn = turn, claim = claim})
    local input = object(pulled)
    local text = input and M.message_text(input.input, object(input.sender), session)
    if pull_error or not input or not text then return pull_error or "the queued message is unreadable" end
    local typed, type_error = funcs.call(TYPE, {session = session, text = text})
    local reply = object(typed)
    if not type_error and reply and reply.ok == true then return nil end
    local fault = reply and object(reply.error)
    local reason = tostring(type_error or (fault and fault.message) or "no reply")
    -- Only accepted work settles, so the undelivered turn is accepted first,
    -- as a cancellation before any executor started is.
    local _, accept_error = journal.invoke("turn_accept", {turn = turn, claim = claim, input_digest = input.input_digest,
        checkpoint = {attempt_id = tostring(route.native_attempt_id or turn)}, operation_key = "deliver-accept:" .. key_seed})
    if accept_error then return accept_error end
    local _, settle_error = journal.invoke("work_settle", {turn = turn, claim = claim, operation_key = "deliver-failed:" .. key_seed,
        result = {state = "failed", error = {code = "UNDELIVERED", message = "The session's terminal could not take the message: " .. reason}}})
    return settle_error
end

function M.hook_boundary(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local caller = identity()
    local session, event, event_key = ref(request.session), request.event, key(request.operation_key)
    local attempt = bounds.id(request.attempt_id)
    if not session or caller ~= session or not event_key or not attempt or bounds.fields(request, {"session", "event", "operation_key", "attempt_id", "permission", "input", "answer"})
        or (event ~= "UserPromptSubmit" and event ~= "Stop" and event ~= "StopFailure" and event ~= "PermissionRequest") then return fail("INVALID", "hook boundary identity is invalid", event_key) end
    if request.input ~= nil and (event ~= "UserPromptSubmit" or bounds.text(request.input, 65536) == nil) then return fail("INVALID", "native prompt is invalid", event_key) end
    if request.answer ~= nil and (event ~= "Stop" or bounds.text(request.answer, 65536) == nil) then return fail("INVALID", "the agent's reply is invalid", event_key) end
    if not security.can("bee.sessions.hook_boundary", session) then return fail("DENIED", "hook boundary requires the authenticated gateway", event_key) end
    local raw, err = journal.invoke("session_describe", {session = session})
    local stored = object(raw)
    local route = stored and object(stored.route)
    if err or not route then return unavailable(err or "interactive route unavailable", event_key) end
    if route.delivery ~= "hook" then return succeed({}) end
    if route.native_attempt_id ~= attempt then return fail("STALE", "hook belongs to an earlier native attachment", event_key) end
    if event == "PermissionRequest" then
        local permission = bounds.object(request.permission)
        local active = bounds.object(stored.active_turn)
        if not permission or not active then return fail("CONFLICT", "permission requires a current interactive turn", event_key) end
        local fields: Object = {session = session, definition = route.definition, plan_digest = route.plan_digest,
            attempt_id = attempt, thread_id = stored.thread_ref, action_id = permission.action_id, binding_id = permission.binding_id,
            turn = active.turn, claim = active.claim, event_id = event_key, payload = permission.payload,
            saved_profile_id = route.saved_profile_id, saved_profile_revision = route.saved_profile_revision, transport = permission.transport}
        local response, response_error = funcs.call("bee.executor.external.binding:answer_hook", fields)
        if response_error then return unavailable(tostring(response_error), event_key) end
        local reply = bounds.object(response)
        if not reply or type(reply.ok) ~= "boolean" then return unavailable("invalid permission hook reply", event_key) end
        if reply.ok ~= true then
            local fault = bounds.object(reply.error)
            return fail("PERMISSION_REFUSED", fault and bounds.text(fault.message, 4096) or "permission hook refused", event_key)
        end
        return succeed(reply.value)
    end
    local event_digest, digest_error = hash.sha256(event_key)
    if not event_digest then return unavailable(tostring(digest_error), event_key) end
    local boundary_key = event_digest
    local active = object(stored.active_turn)
    if event ~= "UserPromptSubmit" then
        if not active or active.phase ~= "accepted" then return succeed({}) end
        local claim, claim_error = claimed(active, "hook-recover:" .. boundary_key)
        if not claim then return unavailable(claim_error or "interactive recovery unavailable", event_key) end
        local pulled, pull_error = journal.invoke("turn_pull", {turn = active.turn, claim = claim})
        local turn = object(pulled)
        local checkpoint = turn and object(turn.checkpoint)
        if pull_error or not checkpoint then return unavailable(pull_error or "interactive checkpoint unavailable", event_key) end
        if checkpoint.attempt_id ~= attempt then return succeed({}) end
        local settled, settle_error = journal.invoke("work_settle", {turn = active.turn, claim = claim,
            operation_key = "hook-stop:" .. boundary_key, result = event == "Stop" and {state = "succeeded", schema = "bee:Text@1", value = {text = reply_of(request.answer)}}
                or {state = "failed", error = {code = "INTERACTIVE_FAILED", message = "Interactive turn failed"}}})
        if settle_error or not settled then return unavailable(settle_error or "interactive turn settlement unavailable", event_key) end
        local problem = deliver(session, "after:" .. boundary_key)
        if problem then return unavailable(problem, event_key) end
        return succeed({})
    end
    -- A prompt the agent submits is either the message Bee typed for the
    -- reserved turn, which accepts that turn, or the person's own prompt,
    -- which becomes the session's work when no turn is in flight.
    local turn_ref: string? = nil
    local claim: string? = nil
    if active and active.phase == "reserved" then
        local current, claim_error = claimed(active, "hook-recover:" .. boundary_key)
        if not current then return unavailable(claim_error or "interactive recovery unavailable", event_key) end
        local pulled, pull_error = journal.invoke("turn_pull", {turn = active.turn, claim = current})
        local typed = object(pulled)
        if pull_error or not typed then return unavailable(pull_error or "interactive turn input unavailable", event_key) end
        if type(request.input) ~= "string" or not same_prompt(request.input, typed.input) then return succeed({}) end
        turn_ref, claim = tostring(active.turn), current
    elseif not active and request.input ~= nil then
        local sent, send_error = journal.invoke("work_send", {session = session, operation_key = "hook-native:" .. boundary_key,
            input = request.input, output_schema = "bee:Text@1"})
        local native_work = object(sent)
        if send_error or not native_work then return unavailable(send_error or "native prompt journal unavailable", event_key) end
        local reserved, reserve_error = journal.invoke("turn_reserve", {session = session, work = native_work.work,
            operation_key = "hook-native-start:" .. boundary_key})
        local native = object(reserved)
        if reserve_error or not native then return unavailable(reserve_error or "native prompt turn unavailable", event_key) end
        if not native.turn then return succeed({}) end
        turn_ref, claim = tostring(native.turn), tostring(native.claim)
    else
        return succeed({})
    end
    local pulled, pull_error = journal.invoke("turn_pull", {turn = turn_ref, claim = claim})
    local input = object(pulled)
    if pull_error or not input then return unavailable(pull_error or "interactive turn input unavailable", event_key) end
    if input.phase == "settled" then return succeed({}) end
    local accepted, accept_error = journal.invoke("turn_accept", {turn = turn_ref, claim = claim, input_digest = input.input_digest,
        checkpoint = {attempt_id = route.native_attempt_id, hook_event = event_key}, operation_key = "hook-accept:" .. boundary_key})
    if accept_error or not accepted then return unavailable(accept_error or "interactive turn accept unavailable", event_key) end
    -- A working agent is never stopped for idling, whoever started its turn.
    local _, activity_error = funcs.call(ACTIVITY, {session = session, state = "working"})
    if activity_error then return unavailable(tostring(activity_error), event_key) end
    return succeed({})
end

-- send queues a message for the session and types it into the agent when it
-- has no turn in flight; a stopped session resumes to take it.
function M.send(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local operation_key = key(request.operation_key)
    local session = ref(request.session)
    if not operation_key or not session or request.input == nil
        or bounds.fields(request, {"session", "input", "output", "expected_incarnation", "operation_key"}) then
        return fail("INVALID", "send requires session, input, and operation_key", operation_key)
    end
    if request.expected_incarnation ~= nil and request.expected_incarnation ~= 1 then
        return fail("STALE", "session incarnation changed", operation_key)
    end
    if request.output ~= nil and request.output ~= "bee:Text@1" then
        return fail("INVALID", "an agent replies in text; output must be bee:Text@1", operation_key)
    end
    local current, read_error = describe(session)
    if not current then return fail("NOT_FOUND", read_error or "session is unavailable", operation_key) end
    if current.lifecycle ~= "active" and current.lifecycle ~= "suspended" then return fail("CONFLICT", "session is not accepting work", operation_key) end
    if current.terminal ~= true then
        return fail("CONFLICT", "this session predates terminal sessions and cannot run; close it and open a new one", operation_key)
    end
    local receipt, send_error = journal.invoke("work_send", {session = session, operation_key = operation_key,
        input = request.input, output_schema = "bee:Text@1"})
    if send_error or not receipt then return unavailable(send_error or "Threads returned no work receipt", operation_key) end
    -- The message is queued either way; delivery that cannot happen now
    -- happens when the agent next starts or ends a turn.
    local problem = deliver(session, "send:" .. operation_key)
    if problem then logger:warn("Session message not delivered yet", {session = session, cause = problem}) end
    return succeed(receipt)
end

local function work_value(value: unknown): (Object?, string?)
    local row = object(value)
    if not row or not ref(row.work) or not ref(row.session) or not bounds.integer(row.revision)
        or (row.phase ~= "queued" and row.phase ~= "reserved" and row.phase ~= "accepted" and row.phase ~= "settled")
        or not object(row.sender) then return nil, "Threads returned a malformed work row" end
    local state: Object = {work = row.work, session = row.session, sender = row.sender,
        revision = row.revision, cancelling = row.cancelling == true, phase = row.phase}
    if row.uncertainty ~= nil then
        state.uncertainty = {summary = tostring((object(row.uncertainty) or {}).summary or "turn outcome is uncertain"), artifacts = {}}
    end
    if row.result ~= nil then
        local result = object(row.result)
        if not result then return nil, "Threads returned a malformed work result" end
        local outcome = result.state
        if outcome == "succeeded" then
            local usage, usage_error = record_values.usage(result.usage or {})
            if not usage then return nil, usage_error or "Threads returned malformed usage" end
            state.phase = "settled"
            state.result = {outcome = outcome, schema = result.schema or row.output_schema,
                value = result.value, artifacts = result.artifacts or {}, usage = usage}
        elseif outcome == "budget_exceeded" then
            local failure = object(result.error) or {}
            local evidence = object(result.evidence)
            if failure.code ~= "BUDGET_EXCEEDED" or not evidence then return nil, "Threads returned a malformed budget outcome" end
            state.phase = "settled"
            state.cancelling = false
            state.result = {outcome = outcome, error = {code = "BUDGET_EXCEEDED",
                message = failure.message or "the configured work budget was exceeded", retry = "never"},
                artifacts = result.artifacts or {}, evidence = evidence}
        elseif outcome == "failed" or outcome == "cancelled" or outcome == "rejected" then
            local failure = object(result.error) or {}
            state.phase = "settled"
            state.cancelling = false
            state.result = {outcome = outcome, error = {code = failure.code or "EXECUTOR_FAILED",
                message = failure.message or "the executor failed", retry = "never"}, artifacts = result.artifacts or {}}
        else
            return nil, "Threads returned an unsupported result state"
        end
    end
    return state, nil
end

local operation_state: (string) -> (Object?, string?)

function M.get(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    if bounds.fields(request, {"session", "work", "operation"}) then return fail("INVALID", "get accepts one exact ref") end
    if request.session ~= nil then
        local session = ref(request.session)
        if not session or request.work ~= nil or request.operation ~= nil then return fail("INVALID", "get needs exactly one subject") end
        local value, err = describe(session)
        if not value then return unavailable(err or "session is unavailable", nil) end
        return succeed({kind = "session", value = value})
    end
    if request.work ~= nil then
        local work = ref(request.work)
        if not work or request.operation ~= nil then return fail("INVALID", "get needs exactly one subject") end
        local value, err = journal.invoke("work_describe", {work = work})
        if err or not value then return unavailable(err or "work is unavailable", nil) end
        local state, decode_error = work_value(value)
        if not state then return unavailable(decode_error or "work is malformed", nil) end
        return succeed({kind = "work", value = state})
    end
    local operation = ref(request.operation)
    if not operation then return fail("INVALID", "get needs exactly one subject") end
    local state, state_error = operation_state(operation)
    if not state then return unavailable(state_error or "operation is unavailable", nil) end
    return succeed({kind = "operation", value = state})
end

-- observed reports a work row as an await observation. A work without a
-- result or uncertainty is pending; its wait ended at the caller's timeout.
local function observed(subject: string, value: unknown): (Object?, string?)
    local row = object(value)
    local state = row and work_value(row)
    if not state then return nil, "Threads returned a malformed work state" end
    local result = object((state).result)
    local cursor = tostring((state).revision)
    if result then
        return {subject_kind = "work", subject = subject, cursor = cursor, tag = "ready", result = result}, nil
    end
    local uncertainty = object((state).uncertainty)
    if uncertainty then
        return {subject_kind = "work", subject = subject, cursor = cursor, tag = "uncertain", evidence = uncertainty}, nil
    end
    return {subject_kind = "work", subject = subject, cursor = cursor, tag = "pending", reason = "timeout"}, nil
end

local function work_observation(subject: string): (Object?, string?)
    local value, err = journal.invoke("work_describe", {work = subject})
    if err or not value then return nil, err or "work is unavailable" end
    return observed(subject, value)
end

-- awaited observes works after Threads reports that one of them reached an
-- outcome or that wait_ms passed.
local function awaited(works: {string}, wait_ms: integer): ({[string]: Object}?, string?)
    local value, err = journal.invoke("work_await", {works = works, wait_ms = wait_ms})
    local reply = object(value)
    local rows = reply and bounds.array(reply.works, #works)
    if err or not rows or #rows ~= #works then return nil, err or "Threads returned a malformed work wait" end
    local observations: {[string]: Object} = {}
    for index, subject in ipairs(works) do
        local observation, observe_error = observed(subject, rows[index])
        if not observation then return nil, observe_error end
        observations[subject] = observation
    end
    return observations, nil
end

local function now_ms(): integer
    return math.floor(time.now():unix_nano() / 1000000)
end

local function timeout_of(request: Object): integer?
    if request.timeout_ms == nil then return session_protocol.DEFAULT_TIMEOUT_MS end
    local timeout = bounds.count(request.timeout_ms)
    if not timeout or timeout > session_protocol.MAX_TIMEOUT_MS then return nil end
    return timeout
end

local function op_descriptor(subject: string): (Object?, string?)
    local value, err = journal.invoke("operation_describe", {operation = subject})
    if err or not value then return nil, err or "operation is unavailable" end
    local row = object(value)
    if not row or row.operation_ref ~= subject or type(row.operation_key) ~= "string"
        or type(row.operation) ~= "string" or row.target == nil then
        return nil, "Threads returned a malformed operation description"
    end
    return row, nil
end

local function operation_receipt(description: Object): (Object?, string?)
    local operation = description.operation
    local receipt = object(description.receipt)
    local target = ref(description.target)
    local subject = ref(description.operation_ref)
    if not subject or not target then return nil, "operation target is malformed" end
    if operation == "session_create" then
        local snapshot_value, snapshot_error = describe(target)
        if not snapshot_value then return nil, snapshot_error end
        return {session = target, operation = subject, snapshot = snapshot_value}, nil
    elseif operation == "session_transition" then
        return {operation = subject, subject = target, state = "requested", effect = "close"}, nil
    elseif receipt then
        return receipt, nil
    end
    return nil, "operation receipt is malformed"
end

operation_state = function(subject: string): (Object?, string?)
    local description, describe_error = op_descriptor(subject)
    if not description then return nil, describe_error end
    local receipt, receipt_error = operation_receipt(description)
    if not receipt then return nil, receipt_error end
    local target = ref((description).target)
    if not target then return nil, "operation target is malformed" end
    local observation: Object
    -- awaits names the work whose settlement completes a pending operation.
    local awaits: string? = nil
    if receipt.effect == "cancel" then
        local value, work_error = journal.invoke("work_describe", {work = target})
        if work_error or not value then return nil, work_error or "cancelled work is unavailable" end
        local state, state_error = work_value(value)
        if not state then return nil, state_error end
        local work_result = object((state).result)
        local uncertainty = object((state).uncertainty)
        local cursor = "1"
        if work_result then
            local cancelled = work_result.outcome == "cancelled"
            local artifacts = work_result.artifacts or {}
            local summary = cancelled and "the work cancellation is settled" or "the work was already terminal"
            observation = {subject_kind = "operation", subject = subject, cursor = cursor, tag = "ready",
                result = {kind = "control", value = {effect = "cancel", state = cancelled and "stopped" or "already_terminal",
                    work = target, evidence = {summary = summary, artifacts = artifacts}}}}
        elseif uncertainty then
            observation = {subject_kind = "operation", subject = subject, cursor = cursor,
                tag = "uncertain", evidence = uncertainty}
        else
            observation = {subject_kind = "operation", subject = subject, cursor = cursor, tag = "pending", reason = "timeout"}
            awaits = target
        end
    elseif receipt.effect == "close" then
        local current, read_error = describe(target)
        if not current then return nil, read_error end
        if current.lifecycle == "closing" then
            local final_error = finish_closing(target, "observe-close:" .. subject)
            if final_error then return nil, final_error end
            local refreshed, refresh_error = describe(target)
            if not refreshed then return nil, refresh_error end
            current = refreshed
        end
        if current.lifecycle == "closed" then
            observation = {subject_kind = "operation", subject = subject, cursor = "1", tag = "ready",
                result = {kind = "control", value = {effect = "close", state = "closed", session = target, cleanup = "complete"}}}
        elseif current.activity == "blocked" or current.activity == "stalled" then
            observation = {subject_kind = "operation", subject = subject, cursor = "1", tag = "blocked",
                blocker = {kind = current.activity == "stalled" and "stalled" or "recovery",
                    message = "session work must settle before the session can close", subject = target, actions = {}}}
        else
            observation = {subject_kind = "operation", subject = subject, cursor = "1", tag = "pending", reason = "timeout"}
        end
    else
        observation = {subject_kind = "operation", subject = subject, cursor = "1", tag = "ready",
            result = {kind = "receipt", value = receipt}}
    end
    return {operation = subject, operation_key = (description).operation_key,
        revision = 1, receipt = receipt, observation = observation, awaits = awaits}, nil
end

-- await waits up to timeout_ms for the subject to settle and reports it;
-- reaching the timeout reports pending and cancels nothing.
function M.await(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local subject = ref(request.subject)
    if not subject or bounds.fields(request, {"subject", "timeout_ms"}) then return fail("INVALID", "await needs a work or operation ref") end
    local timeout = timeout_of(request)
    if not timeout then return fail("INVALID", "timeout_ms is outside its bound") end
    if subject:sub(1, 3) == "bw:" then
        local observations, err = awaited({subject}, timeout)
        if not observations then return unavailable(err or "work is unavailable", nil) end
        return succeed(observations[subject])
    elseif subject:sub(1, 3) == "bo:" then
        local state, state_error = operation_state(subject)
        if not state then return unavailable(state_error or "operation is unavailable", nil) end
        local target = state.awaits
        if timeout > 0 and type(target) == "string" then
            local _, wait_error = awaited({target}, timeout)
            if wait_error then return unavailable(wait_error, nil) end
            state, state_error = operation_state(subject)
            if not state then return unavailable(state_error or "operation is unavailable", nil) end
        end
        return succeed((state).observation)
    end
    return fail("INVALID", "await needs a work or operation ref")
end

function M.catalog(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local _, workspace = identity()
    if not workspace then return fail("DENIED", "the authenticated caller has no workspace", nil) end
    local page, catalog_error = catalog_service.list(request, workspace)
    if not page then return fail(catalog_error and catalog_error.code or "INVALID", catalog_error and catalog_error.message or "catalog request is invalid", nil) end
    return succeed(page)
end

local function internal_key(prefix: string, operation_key: string): (string?, string?)
    local digest, digest_error = hash.sha256("bee.sessions." .. prefix .. "\n" .. operation_key)
    if not digest then return nil, tostring(digest_error) end
    return prefix .. ":" .. digest, nil
end

local function cancel_settle_key(turn: string): string
    return "cancel-settle:" .. turn:sub(-72)
end

finish_closing = function(session: string, operation_key: string): string?
    local current, current_error = describe(session)
    if not current then return current_error or "closing session unavailable" end
    if tostring(current.lifecycle) ~= "closing" then return nil end
    local raw, read_error = journal.invoke("session_describe", {session = session})
    local stored = object(raw)
    local route = stored and object(stored.route)
    if read_error then return read_error end
    if route and route.delivery == "hook" and type(route.native_attempt_id) == "string" then
        local stopped = cancellation.stop(route.placement_methods, route.native_attempt_id, route, true)
        if stopped.state == "pending" then return nil end
        if stopped.state ~= "stopped" then return stopped.evidence.summary end
        local cursor: integer? = nil
        repeat
            local page_raw, history_error = journal.invoke("work_history", {session = session, cursor = cursor, limit = 64})
            local page = object(page_raw)
            local rows = page and bounds.array(page.items, 64)
            if history_error or not page or not rows then return history_error or "window work history unavailable" end
            for _, item_raw in ipairs(rows) do
                local item = object(item_raw)
                local work = item and ref(item.work)
                if not work then return "window history omitted its WorkRef" end
                local state_raw, state_error = journal.invoke("work_describe", {work = work})
                local state = object(state_raw)
                if state_error or not state then return state_error or "window work unavailable" end
                if state.phase ~= "settled" then
                    local cancel_key = assert(internal_key("window-close-cancel", work))
                    local _, cancel_error = journal.invoke("work_cancel", {work = work, operation_key = cancel_key, reason = "session closed"})
                    if cancel_error then return cancel_error end
                    if (state.phase == "reserved" or state.phase == "accepted") and type(state.turn) == "string" and type(state.claim) == "string" then
                        if state.phase == "reserved" then
                            local pulled_raw, pull_error = journal.invoke("turn_pull", {turn = state.turn, claim = state.claim})
                            local pulled = object(pulled_raw)
                            if pull_error or not pulled then return pull_error or "closing window turn unavailable" end
                            local _, accept_error = journal.invoke("turn_accept", {turn = state.turn, claim = state.claim,
                                input_digest = pulled.input_digest, checkpoint = {attempt_id = route.native_attempt_id},
                                operation_key = assert(internal_key("window-close-accept", state.turn))})
                            if accept_error then return accept_error end
                        end
                        local _, settle_error = journal.invoke("work_settle", {turn = state.turn, claim = state.claim,
                            result = {state = "cancelled", error = {code = "CANCELLED", message = "session closed"}, artifacts = stopped.evidence.artifacts},
                            operation_key = cancel_settle_key(state.turn)})
                        if settle_error then return settle_error end
                    end
                end
            end
            cursor = page.next == nil and nil or bounds.integer(page.next)
        until cursor == nil
        local next_snapshot, snapshot_error = describe(session)
        if not next_snapshot then return snapshot_error end
        current = next_snapshot
    else
        local execution = object(current.execution)
        if current.queue_count > 0 or (execution and execution.state == "running") then return nil end
    end
    local close_key, key_error = internal_key("close-final", operation_key)
    if not close_key then return key_error or "cannot derive final close operation key" end
    local _, close_error = journal.invoke("session_transition", {session = session, state = "closed",
        expected_revision = current.revision, operation_key = close_key})
    return close_error
end

local function control_receipt(operation: string, subject: string, effect: "cancel" | "close"): Object
    return {operation = operation, subject = subject, state = "requested", effect = effect}
end

function M.close(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local operation_key = key(request.operation_key)
    local session = ref(request.session)
    if not operation_key or not session
        or bounds.fields(request, {"session", "expected_incarnation", "operation_key"}) then
        return fail("INVALID", "close requires a session and operation_key", operation_key)
    end
    if request.expected_incarnation ~= nil and request.expected_incarnation ~= 1 then
        return fail("STALE", "session incarnation changed", operation_key)
    end
    local current, current_error = describe(session)
    if not current then return fail("NOT_FOUND", current_error or "session is unavailable", operation_key) end
    if current.lifecycle == "closed" then return fail("CONFLICT", "session is already closed", operation_key) end
    local transitioned, transition_error = journal.invoke("session_transition", {session = session, state = "closing",
        operation_key = operation_key})
    if transition_error or not transitioned then return unavailable(transition_error or "Threads returned no close receipt", operation_key) end
    local transition = object(transitioned)
    local operation = transition and ref(transition.operation)
    if not operation then return unavailable("Threads returned a malformed close receipt", operation_key) end
    current, current_error = describe(session)
    if not current then return unavailable(current_error or "cannot read the closing session", operation_key) end
    local finish_error = finish_closing(session, operation_key)
    if finish_error then return unavailable(finish_error, operation_key) end
    return succeed(control_receipt(operation, session, "close"))
end

function M.cancel(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local operation_key = key(request.operation_key)
    local work = ref(request.work)
    local reason = request.reason == nil and nil or bounds.text(request.reason, 16384)
    if not operation_key or not work or work:sub(1, 3) ~= "bw:"
        or (request.reason ~= nil and not reason)
        or bounds.fields(request, {"work", "reason", "expected_incarnation", "operation_key"}) then
        return fail("INVALID", "cancel requires a work ref, optional reason, and operation_key", operation_key)
    end
    local cancel_operation_key = operation_key
    if request.expected_incarnation ~= nil and request.expected_incarnation ~= 1 then
        return fail("STALE", "session incarnation changed", operation_key)
    end
    local raw, cancel_error = journal.invoke("work_cancel", {work = work, reason = reason, operation_key = operation_key})
    if cancel_error or not raw then return unavailable(cancel_error or "Threads returned no cancellation receipt", operation_key) end
    local receipt = object(raw)
    local operation = receipt and ref(receipt.operation)
    if not operation or receipt.subject ~= work or receipt.effect ~= "cancel" then
        return unavailable("Threads returned a malformed cancellation receipt", operation_key)
    end
    local value, read_error = journal.invoke("work_describe", {work = work})
    if read_error or not value then return unavailable(read_error or "cannot read cancelled work", operation_key) end
    local state = object(value)
    if not state or state.phase ~= "accepted" or type(state.turn) ~= "string" or type(state.claim) ~= "string" then
        return succeed(raw)
    end
    local session_data, session_error = journal.invoke("session_describe", {session = state.session})
    local stored_session = object(session_data)
    local route = stored_session and object(stored_session.route)
    local placement_methods = route and object(route.placement_methods)
    local checkpoint = object(state.checkpoint)
    local attempt_id = checkpoint and ref(checkpoint.attempt_id) or ref(state.turn)
    if session_error or not placement_methods or not attempt_id then
        local uncertain_key, uncertain_key_error = internal_key("cancel-uncertain", cancel_operation_key)
        if not uncertain_key then return unavailable(uncertain_key_error or "cannot derive cancellation evidence key", operation_key) end
        local marker, marker_error = journal.invoke("work_uncertain", {turn = state.turn, claim = state.claim,
            evidence = {summary = session_error or "cancel could not resolve its admitted placement", artifacts = {}},
            operation_key = uncertain_key})
        if marker_error and marker == nil then return unavailable(marker_error, operation_key) end
        return succeed(raw)
    end
    local result = cancellation.stop(placement_methods, attempt_id, route)
    if result.state == "uncertain" then
        local uncertain_key, uncertain_key_error = internal_key("cancel-uncertain", cancel_operation_key)
        if not uncertain_key then return unavailable(uncertain_key_error or "cannot derive cancellation evidence key", operation_key) end
        local marker, marker_error = journal.invoke("work_uncertain", {turn = state.turn, claim = state.claim,
            evidence = result.evidence, operation_key = uncertain_key})
        if marker_error and marker == nil then return unavailable(marker_error, operation_key) end
    elseif result.state == "stopped" then
        local settled, settle_error = journal.invoke("work_settle", {turn = state.turn, claim = state.claim,
            result = {state = "cancelled", error = {code = "CANCELLED", message = reason or "work cancelled"},
                artifacts = result.evidence.artifacts}, operation_key = cancel_settle_key(state.turn)})
        if settle_error or not settled then
            local current, current_error = journal.invoke("work_describe", {work = work})
            local current_state = object(current)
            if current_error or not current_state or current_state.phase ~= "settled" then
                return unavailable(settle_error or current_error or "Threads did not settle cancelled work", operation_key)
            end
        end
    end
    return succeed(raw)
end

function M.join(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local operation_key = key(request.operation_key)
    if not operation_key or bounds.fields(request, {"works", "policy", "quorum", "timeout_ms", "operation_key"}) then
        return fail("INVALID", "join requires works and operation_key", operation_key)
    end
    local raw_works = bounds.array(request.works, 64)
    if not raw_works or #raw_works < 1 then return fail("INVALID", "works must hold 1 to 64 work refs", operation_key) end
    local policy = request.policy == nil and "all_success" or request.policy
    if policy ~= "all_success" and policy ~= "all_settled" and policy ~= "first_success" and policy ~= "quorum" then
        return fail("INVALID", "join policy is invalid", operation_key)
    end
    local quorum: integer? = nil
    if policy == "quorum" then
        quorum = bounds.count(request.quorum)
        if not quorum or quorum < 1 or quorum > #raw_works then return fail("INVALID", "quorum must be from 1 to the number of works", operation_key) end
    elseif request.quorum ~= nil then
        return fail("INVALID", "quorum is only valid with the quorum policy", operation_key)
    end
    local timeout = timeout_of(request)
    if not timeout then return fail("INVALID", "timeout_ms is outside its bound", operation_key) end
    local deadline_at = now_ms() + timeout
    local caller, workspace = identity()
    if not caller or not workspace then return fail("DENIED", "the authenticated caller has no workspace", operation_key) end
    local works: {string} = {}
    local seen: {[string]: boolean} = {}
    local node: string? = nil
    for index, raw in ipairs(raw_works) do
        local work = ref(raw)
        if not work then return fail("INVALID", "works must be distinct work refs", operation_key) end
        if work:sub(1, 3) ~= "bw:" or seen[work] then return fail("INVALID", "works must be distinct work refs", operation_key) end
        local work_node, work_workspace = work:match("^bw:([^:]+):([^:]+):")
        if not work_node or work_workspace ~= workspace or (node and work_node ~= node) then
            return fail("INVALID", "works must belong to this workspace and node", operation_key)
        end
        node = work_node
        seen[work] = true
        works[index] = work
    end
    local digest, digest_error = hash.sha256("bee.sessions.join\n" .. operation_key .. "\n" .. table.concat(works, "\n"))
    if not digest then return unavailable("cannot derive join reference: " .. tostring(digest_error), operation_key) end
    local joined_ref = "bj:" .. (node or "node") .. ":" .. workspace .. ":" .. digest:sub(1, 32)
    -- decide applies the policy to the current child observations; pending
    -- means the policy needs a child that has not settled yet.
    local function decide(children: {Object}): Object
        local successful: {string} = {}
        local values: {unknown} = {}
        local pending = false
        local blocked: Object? = nil
        local uncertain: Object? = nil
        for index, tagged in ipairs(children) do
            if tagged.tag == "pending" then pending = true
            elseif tagged.tag == "blocked" then blocked = object(tagged.blocker)
            elseif tagged.tag == "uncertain" then uncertain = object(tagged.evidence)
            else
                local result = object(tagged.result)
                if result and result.outcome == "succeeded" then
                    successful[#successful + 1] = works[index]
                    values[#values + 1] = result.value
                end
            end
        end
        local base: Object = {subject_kind = "join", subject = joined_ref, cursor = "1", children = children}
        if uncertain then base.tag = "uncertain"; base.evidence = uncertain
        elseif blocked then base.tag = "blocked"; base.blocker = blocked
        elseif policy == "first_success" and #successful > 0 then
            base.tag = "ready"; base.result = {succeeded = true, winners = successful, values = values}
        elseif policy == "quorum" and #successful >= (quorum) then
            base.tag = "ready"; base.result = {succeeded = true, winners = successful, values = values}
        elseif pending then
            base.tag = "pending"; base.reason = "timeout"
        else
            local all_success = #successful == #works
            local succeeded = policy == "all_settled" or policy == "all_success" and all_success
                or policy == "first_success" and #successful > 0 or policy == "quorum" and #successful >= (quorum)
            base.tag = "ready"
            local result: Object = {succeeded = succeeded, winners = successful}
            if succeeded then result.values = values end
            base.result = result
        end
        return base
    end
    local children: {Object} = {}
    for index, work in ipairs(works) do
        local observation, observe_error = work_observation(work)
        if not observation then return unavailable(observe_error or "cannot observe joined work", operation_key) end
        children[index] = observation
    end
    local decided = decide(children)
    while decided.tag == "pending" do
        local remaining = deadline_at - now_ms()
        if remaining <= 0 then break end
        local waiting: {string} = {}
        for index, observation in ipairs(children) do
            if observation.tag == "pending" then waiting[#waiting + 1] = works[index] end
        end
        local observations, wait_error = awaited(waiting, remaining)
        if not observations then return unavailable(wait_error or "cannot observe joined work", operation_key) end
        for index, work in ipairs(works) do
            local observation = observations[work]
            if observation then children[index] = observation end
        end
        decided = decide(children)
    end
    return succeed(decided)
end

-- LIST_PAGE_BYTES is the published bound of one reply value; a page carries
-- as many sessions as fit under it with its cursor.
M.LIST_PAGE_BYTES = 65536
local LIST_PAGE_OVERHEAD_BYTES = 512
function M.list(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    if bounds.fields(request, {"filter", "cursor"}) then return fail("INVALID", "list accepts only filter and cursor") end
    local filter = object(request.filter)
    if request.filter ~= nil and (not filter or bounds.fields(filter, {"lifecycle", "activity", "workspace", "definition"})) then
        return fail("INVALID", "session filter is malformed")
    end
    local lifecycle = filter and filter.lifecycle or nil
    if lifecycle ~= nil and lifecycle ~= "opening" and lifecycle ~= "active" and lifecycle ~= "suspended"
        and lifecycle ~= "closing" and lifecycle ~= "closed" then return fail("INVALID", "lifecycle filter is invalid") end
    local activity = filter and filter.activity or nil
    if activity ~= nil and activity ~= "idle" and activity ~= "working" and activity ~= "blocked" and activity ~= "stalled" then
        return fail("INVALID", "activity filter is invalid")
    end
    local workspace = filter and filter.workspace or nil
    local definition = filter and filter.definition or nil
    if (workspace ~= nil and not bounds.id(workspace)) or (definition ~= nil and not ref(definition)) then return fail("INVALID", "workspace or definition filter is invalid") end
    local cursor = request.cursor == nil and nil or ref(request.cursor)
    if request.cursor ~= nil and not cursor then return fail("INVALID", "cursor is invalid") end
    local page, scan_error = journal.invoke("session_scan", {cursor = cursor, limit = 64, workspace = workspace})
    if scan_error or not page then return unavailable(scan_error or "Threads returned no session page", nil) end
    local scan = object(page)
    local refs = scan and scan.items
    if type(refs) ~= "table" then return unavailable("Threads returned a malformed session page", nil) end
    local items: {Object} = {}
    -- The page stays within one published reply value: once the next session
    -- would not fit, the page ends after the last session scanned.
    local size = LIST_PAGE_OVERHEAD_BYTES
    local scanned: string? = nil
    for _, raw_ref in ipairs(refs) do
        local session = ref(raw_ref)
        if not session then return unavailable("Threads returned a malformed session ref", nil) end
        local current, read_error = describe(session)
        if not current then return unavailable(read_error or "cannot read a listed session", nil) end
        if (lifecycle == nil or current.lifecycle == lifecycle) and (activity == nil or current.activity == activity)
            and (definition == nil or current.definition == definition) then
            local encoded = json.encode(current)
            if not encoded then return unavailable("a listed session is not encodable", nil) end
            if size + #encoded + 1 > M.LIST_PAGE_BYTES then
                if not scanned then return unavailable("one session exceeds the list page bound", nil) end
                return succeed({items = items, next = scanned})
            end
            size = size + #encoded + 1
            items[#items + 1] = current
        end
        scanned = session
    end
    return succeed({items = items, next = scan and ref(scan.next) or nil})
end

-- Read-only display summary for the caller's workspace. No control actions.
function M.attention_count(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local actor, workspace = identity()
    if not actor or not workspace or request.workspace_id ~= workspace
        or bounds.fields(request, {"workspace_id"}) then return fail("DENIED", "attention summary requires the caller's workspace") end
    local count = 0
    local cursor: string? = nil
    for _ = 1, 16 do
        local page = M.list({filter = {workspace = workspace}, cursor = cursor})
        if not page.ok then return page end
        local value = object(page.value)
        local items = value and value.items
        if type(items) ~= "table" then return unavailable("session summary unavailable", nil) end
        for _, raw in ipairs(items) do
            local row = object(raw)
            if row and row.lifecycle ~= "closed" and (row.activity == "blocked" or row.activity == "stalled") then count = count + 1 end
        end
        cursor = value and ref(value.next) or nil
        if not cursor then return succeed({count = count}) end
    end
    return unavailable("session summary exceeds the display page limit", nil)
end

function M.run(raw_request: unknown): Reply
    local input, refused = request_input(raw_request)
    if not input then return assert(refused) end
    local operation_key = key(input.operation_key)
    if not operation_key then return fail("INVALID", "run requires operation_key", nil) end
    local digest, hash_error = hash.sha256("bee.sessions.run.session\n" .. operation_key)
    if not digest then return unavailable("cannot derive the run session key: " .. tostring(hash_error), operation_key) end
    local spec = object(input.spec)
    local overrides, override_error = profile_values.overrides(spec and spec.overrides)
    if not overrides then return fail("INVALID", override_error or "invalid spawn overrides", operation_key) end
    local first_input = input.input
    if overrides and overrides.input ~= nil then
        if first_input ~= nil then return fail("INVALID", "input is specified twice", operation_key) end
        first_input = overrides.input
        local normalized: Object = {}
        for name, value in pairs(overrides) do if name ~= "input" then normalized[name] = value end end
        local copied: Object = {}
        for name, value in pairs(spec or {}) do copied[name] = value end
        copied.overrides = normalized
        spec = copied
    end
    if first_input == nil then return fail("INVALID", "run requires input", operation_key) end
    local opened = M.open({spec = spec, operation_key = "run-session:" .. digest})
    if not opened.ok then return opened end
    local receipt = object(opened.value)
    if not receipt then return unavailable("open returned no session receipt", operation_key) end
    return M.send({session = receipt.session, input = first_input, output = input.output,
        expected_incarnation = 1, operation_key = operation_key})
end

function M.history(raw_request: unknown): Reply
    local input, refused = request_input(raw_request)
    if not input then return assert(refused) end
    local session = ref(input.session)
    if not session or bounds.fields(input, {"session", "cursor", "limit"}) then return fail("INVALID", "history requires a session") end
    local page, page_error = journal.invoke("work_history", input)
    if page_error or not page then return unavailable(page_error or "history unavailable", nil) end
    return succeed(page)
end

for _, name in ipairs({"open", "run", "send", "await", "join", "get", "list", "history", "cancel", "close", "catalog"}) do
    local local_method = M[name]
    M[name] = function(raw: unknown): Reply
        local input = object(raw)
        if not input or input.node == nil then return local_method(raw) end
        local node = bounds.id(input.node)
        if not node or node:find("[^A-Za-z0-9_.-]") then return fail("INVALID", "node is malformed", key(input.operation_key)) end
        local request: Object = {}
        for field, value in pairs(input) do if field ~= "node" then request[field] = value end end
        if node == system.node.id() then return local_method(request) end
        local reply = remote.call(node, name, request)
        return {ok = reply.ok == true, value = reply.value, error = object(reply.error)}
    end
end
return M
