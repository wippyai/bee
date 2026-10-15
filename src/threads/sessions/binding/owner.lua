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
local logger = require("logger")
local listing = require("listing")
local remote = require("remote")
local system = require("system")
local M = {}
local part_observation = require("part_observation")
type Object = part_observation.Object
type Reply = part_observation.Reply
local object = part_observation.object
local fail = part_observation.fail
local unavailable = part_observation.unavailable
local succeed = part_observation.succeed
local request_input = part_observation.request_input
local identity = part_observation.identity
local key = part_observation.key
local ref = part_observation.ref
local finish_closing = part_observation.finish_closing
local describe = part_observation.describe
M.get = part_observation.get
M.await = part_observation.await
local internal_key = part_observation.internal_key
local cancel_settle_key = part_observation.cancel_settle_key
M.join = part_observation.join
M.history = part_observation.history

local snapshot = require("snapshot").decode

local deliver: (string, string) -> string?
local TYPE = "bee.harness.binding:present_type"
local RESUME = "bee.harness.binding:present_restore"
local ACTIVITY = "bee.harness.binding:present_activity"

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

local function normalize_spec(raw: unknown, input: unknown): (Object?, unknown, string?)
    local spec = object(raw)
    if not spec or bounds.fields(spec, {"definition", "profile", "workdir", "workspace", "overrides"}) then
        return nil, nil, "open requires a definition, optional profile/workdir/workspace, and operation_key"
    end
    local overrides, err = profile_values.overrides(spec.overrides)
    if not overrides then return nil, nil, err or "invalid spawn overrides" end
    if overrides.workdir and spec.workdir ~= nil then return nil, nil, "workdir is specified twice" end
    if overrides.workspace and spec.workspace ~= nil then return nil, nil, "workspace is specified twice" end
    if overrides.input ~= nil then
        if input ~= nil then return nil, nil, "input is specified twice" end
        input = overrides.input
    end
    local copied: Object = {}
    for name, value in pairs(spec) do copied[name] = value end
    copied.workdir = overrides.workdir or spec.workdir
    copied.workspace = overrides.workspace or spec.workspace
    if spec.overrides ~= nil then
        local normalized: Object = {}
        for name, value in pairs(overrides) do
            if name ~= "workspace" and name ~= "workdir" and name ~= "input" then normalized[name] = value end
        end
        copied.overrides = normalized
    end
    return copied, input, nil
end

-- open starts a session: the agent's own program runs in a terminal that
-- Bee keeps whether or not anyone watches it. Messages are typed into it;
-- the person opens its terminal from Agents.
function M.open(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local operation_key = key(request.operation_key)
    if not operation_key then return fail("INVALID", "open requires operation_key", nil) end
    local spec, first_input, spec_error = normalize_spec(request.spec, nil)
    if not spec then return fail("INVALID", spec_error or "invalid spawn specification", operation_key) end
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
            local raw, call_error = executor:call("bee.threads.sessions.binding:open", request)
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
    if first_input ~= nil then
        local sent = M.send({session = session, input = first_input, operation_key = "open-input:" .. assert(hash.sha256(operation_key))})
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
    elseif stored.state == "closing" then
        local close_error = finish_closing(session, operation_key)
        if close_error then return unavailable(close_error, operation_key) end
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

-- idle_check tells a window whether it may stop its agent: no turn is in
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
    if not session or caller ~= session or not event_key or not attempt or bounds.fields(request, {"session", "binding_id", "event", "operation_key", "attempt_id", "permission", "input", "answer", "hook_payload"})
        or (event ~= "SessionStart" and event ~= "UserPromptSubmit" and event ~= "PreToolUse" and event ~= "PostToolUse" and event ~= "Stop" and event ~= "StopFailure" and event ~= "PermissionRequest") then return fail("INVALID", "hook boundary identity is invalid", event_key) end
    if request.input ~= nil and (event ~= "UserPromptSubmit" or bounds.text(request.input, 65536) == nil) then return fail("INVALID", "native prompt is invalid", event_key) end
    if request.answer ~= nil and (event ~= "Stop" or bounds.text(request.answer, 65536) == nil) then return fail("INVALID", "the agent's reply is invalid", event_key) end
    if not security.can("bee.sessions.hook_boundary", session) then return fail("DENIED", "hook boundary requires the authenticated gateway", event_key) end
    local raw, err = journal.invoke("session_describe", {session = session})
    local stored = object(raw)
    local route = stored and object(stored.route)
    if err or not route then return unavailable(err or "interactive route unavailable", event_key) end
    if route.delivery ~= "hook" then
        if event == "Stop" or event == "StopFailure" then return succeed({}) end
        local binding = bounds.id(request.binding_id)
        if not binding then return fail("INVALID", "managed hook has no binding", event_key) end
        local target = event == "PermissionRequest" and "bee.harness.binding:permission_hook" or "bee.harness.binding:extension_hook"
        local raw, failure = funcs.call(target, {binding_id = binding, event_id = event_key, payload = request.hook_payload})
        local reply = bounds.object(raw)
        if failure or not reply or reply.ok ~= true then
            local fault = reply and bounds.object(reply.error)
            return unavailable(tostring(failure or (fault and fault.message) or "managed hook unavailable"), event_key)
        end
        return succeed(reply.value)
    end
    if route.native_attempt_id ~= attempt then return fail("STALE", "hook belongs to an earlier native attachment", event_key) end
    local extension_response: Object? = nil
    local points = {SessionStart = "session.start", UserPromptSubmit = "prompt.submit", PreToolUse = "tool.before", PostToolUse = "tool.after"}
    local point = points[tostring(event)]
    if point then
        local payload = bounds.object(request.hook_payload) or {}
        local tool_input: unknown = payload.tool_input
        local tool_output: unknown = payload.tool_response
        if type(tool_input) == "string" then tool_input = json.decode(tool_input) end
        if type(tool_output) == "string" and route.provider == "codex" then tool_output = json.decode(tool_output) end
        local active_turn = bounds.object(stored.active_turn)
        local response, failure = funcs.call("bee.threads.hooks:dispatch", {session_ref = session, thread_id = stored.thread_ref,
            workspace_id = stored.workspace, point = point, occurrence_id = event_key, turn_ref = active_turn and active_turn.turn,
            tool_name = payload.tool_name, tool_call_id = payload.tool_use_id, input = tool_input, output = tool_output, text = request.input})
        local reply = bounds.object(response)
        if failure or not reply or reply.ok ~= true then
            local fault = reply and bounds.object(reply.error)
            return unavailable(tostring(failure or (fault and fault.message) or "hook dispatcher unavailable"), event_key)
        end
        extension_response = assert(bounds.object(reply.value))
        if extension_response.denied == true then
            if event == "UserPromptSubmit" and active_turn and active_turn.phase == "reserved" then
                local current, claim_error = claimed(active_turn, "hook-deny:" .. event_key)
                if not current then return unavailable(claim_error or "denied turn recovery unavailable", event_key) end
                local pulled, pull_error = journal.invoke("turn_pull", {turn = active_turn.turn, claim = current})
                local input = bounds.object(pulled)
                if pull_error or not input then return unavailable(pull_error or "denied turn input unavailable", event_key) end
                local _, accept_error = journal.invoke("turn_accept", {turn = active_turn.turn, claim = current, input_digest = input.input_digest,
                    checkpoint = {attempt_id = attempt}, operation_key = "hook-deny-accept:" .. event_key})
                if accept_error then return unavailable(accept_error, event_key) end
                local _, settle_error = journal.invoke("work_settle", {turn = active_turn.turn, claim = current, operation_key = "hook-deny-settle:" .. event_key,
                    result = {state = "rejected", error = {code = "HOOK_DENIED", message = extension_response.reason}}})
                if settle_error then return unavailable(settle_error, event_key) end
            end
            return succeed({extension_response = extension_response, hook_driver = route.provider})
        end
        if event ~= "UserPromptSubmit" then return succeed({extension_response = extension_response, hook_driver = route.provider}) end
    end
    if event == "PermissionRequest" then
        local permission = bounds.object(request.permission)
        local active = bounds.object(stored.active_turn)
        if not permission or not active then return fail("CONFLICT", "permission requires a current interactive turn", event_key) end
        local fields: Object = {session = session, definition = route.definition, plan_digest = route.plan_digest,
            attempt_id = attempt, thread_id = stored.thread_ref, action_id = permission.action_id, binding_id = permission.binding_id,
            turn = active.turn, claim = active.claim, event_id = event_key, payload = permission.payload,
            saved_profile_id = route.saved_profile_id, saved_profile_revision = route.saved_profile_revision, transport = permission.transport}
        local response, response_error = funcs.call("bee.harness.permission.external.binding:answer_hook", fields)
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
        if type(request.input) ~= "string" or not same_prompt(request.input, typed.input) then return succeed({extension_response = extension_response, hook_driver = extension_response and route.provider or nil}) end
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
        if not native.turn then return succeed({extension_response = extension_response, hook_driver = extension_response and route.provider or nil}) end
        turn_ref, claim = tostring(native.turn), tostring(native.claim)
    else
        return succeed({extension_response = extension_response, hook_driver = extension_response and route.provider or nil})
    end
    local pulled, pull_error = journal.invoke("turn_pull", {turn = turn_ref, claim = claim})
    local input = object(pulled)
    if pull_error or not input then return unavailable(pull_error or "interactive turn input unavailable", event_key) end
    if input.phase == "settled" then return succeed({extension_response = extension_response, hook_driver = extension_response and route.provider or nil}) end
    local accepted, accept_error = journal.invoke("turn_accept", {turn = turn_ref, claim = claim, input_digest = input.input_digest,
        checkpoint = {attempt_id = route.native_attempt_id, hook_event = event_key}, operation_key = "hook-accept:" .. boundary_key})
    if accept_error or not accepted then return unavailable(accept_error or "interactive turn accept unavailable", event_key) end
    -- A working agent is never stopped for idling, whoever started its turn.
    local _, activity_error = funcs.call(ACTIVITY, {session = session, state = "working"})
    if activity_error then return unavailable(tostring(activity_error), event_key) end
    return succeed({extension_response = extension_response, hook_driver = extension_response and route.provider or nil})
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
    -- The message is queued either way; delivery that cannot happen immediately
    -- happens when the agent next starts or ends a turn.
    local problem = deliver(session, "send:" .. operation_key)
    if problem then logger:warn("Session message not delivered yet", {session = session, cause = problem}) end
    return succeed(receipt)
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

M.LIST_PAGE_BYTES = listing.LIST_PAGE_BYTES
M.list = listing.list
M.attention_count = listing.attention_count

function M.run(raw_request: unknown): Reply
    local input, refused = request_input(raw_request)
    if not input then return assert(refused) end
    local operation_key = key(input.operation_key)
    if not operation_key then return fail("INVALID", "run requires operation_key", nil) end
    local digest, hash_error = hash.sha256("bee.sessions.run.session\n" .. operation_key)
    if not digest then return unavailable("cannot derive the run session key: " .. tostring(hash_error), operation_key) end
    local spec, first_input, spec_error = normalize_spec(input.spec, input.input)
    if not spec then return fail("INVALID", spec_error or "invalid spawn specification", operation_key) end
    if first_input == nil then return fail("INVALID", "run requires input", operation_key) end
    local opened = M.open({spec = spec, operation_key = "run-session:" .. digest})
    if not opened.ok then return opened end
    local receipt = object(opened.value)
    if not receipt then return unavailable("open returned no session receipt", operation_key) end
    return M.send({session = receipt.session, input = first_input, output = input.output,
        expected_incarnation = 1, operation_key = operation_key})
end

for _, name in ipairs({"open", "run", "send", "await", "join", "get", "history", "cancel", "close", "catalog"}) do
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
