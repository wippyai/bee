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
local replies = require("replies")
local delivery = require("delivery")
type Object = replies.Object
type Reply = replies.Reply
local object = replies.object
local fail = replies.fail
local unavailable = replies.unavailable
local succeed = replies.succeed
local request_input = replies.request_input
local identity = replies.identity
local key = replies.key
local ref = replies.ref
local finish_closing = part_observation.finish_closing
local describe = replies.describe
M.get = part_observation.get
M.await = part_observation.await
local internal_key = part_observation.internal_key
local cancel_settle_key = part_observation.cancel_settle_key
M.join = part_observation.join
M.history = part_observation.history

local snapshot = require("snapshot").decode

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
    local plan, refused = admission.resolve(definition, "window", workspace, profile_id, revision, nil, nil, nil, nil, request.overrides)
    if not plan then return unavailable(tostring(refused and refused.error and refused.error.message or "interactive plan is unavailable"), operation_key) end
    if plan.plan_digest ~= request.plan_digest or plan.mode ~= "window" then return fail("CONFLICT", "interactive attach plan changed", operation_key) end
    local driver = plan.binding_ref
    -- The session records the admission of each attempt it attaches; its
    -- hooks are judged under the attempt's own plan.
    local admitted = admission.session_admission(plan)
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
        local route: Object = {delivery = "hook", origin_request_id = origin, operation_key = operation_key}
        for name, field in pairs(admitted) do route[name] = field end
        created, err = journal.invoke("session_create", {thread_id = thread, operation_key = operation_key,
            title = plan.title, route = route})
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
    local attached, attach_error = journal.invoke("session_attach", {session = receipt and receipt.session, attempt_id = request.attempt_id,
        admission = admitted, operation_key = "attach:" .. tostring(request.attempt_id)})
    if attach_error or not attached then return unavailable(attach_error or "native attachment failed", operation_key) end
    return succeed(created)
end

-- restore reports what reopens a window session whose terminal is gone: the
-- admitted definition and plan, the saved profile, the request that first
-- admitted it, the operation key that created it, the principal that owns it,
-- its last native attempt and its thread. A window app resumes
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
    local owner = bounds.id(route.owner_id)
    if not origin or not attempt or not plan_digest or not thread or not operation_key or not owner then
        return unavailable("window session records no admitted continuation to restore", nil)
    end
    local value: Object = {trait_ceiling = route.trait_ceiling, overrides = route.overrides, session = session, definition_ref = definition, plan_digest = plan_digest,
        origin_request_id = origin, previous_attempt_id = attempt, thread_id = thread, operation_key = operation_key, owner_id = owner}
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
    -- A turn the exited terminal accepted ends without a proven result. A
    -- reserved turn reached no agent: the next terminal takes it, or closing
    -- cancels it.
    local active = object(stored.active_turn)
    if active and active.phase == "accepted" then
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
    local problem = delivery.deliver(session, "send:" .. operation_key)
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

-- A refusal the journal answers keeps its meaning; anything else is the
-- journal being unavailable.
local JOURNAL_CODES: {[string]: string} = {NOT_FOUND = "NOT_FOUND", DENIED = "DENIED", CONFLICT = "CONFLICT", INVALID_ARGUMENT = "INVALID"}

local function journal_fault(fault: {code: string, message: string}, operation_key: string): Reply
    local code = JOURNAL_CODES[fault.code]
    if code then return fail(code, fault.message, operation_key) end
    return unavailable(fault.message, operation_key)
end

-- remove deletes a session and what Bee keeps only for it. Its thread and
-- records stay, unless history asks to remove them too, which a thread
-- shared with other sessions, apps or peers refuses. The request is recorded
-- first. A session that is not closed closes: its agent stops, and the close
-- completes the removal once placement proves the agent exited. Until then
-- the session is removing.
function M.remove(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local operation_key = key(request.operation_key)
    local session = ref(request.session)
    if not operation_key or not session or session:sub(1, 3) ~= "bs:" or bounds.fields(request, {"session", "history", "operation_key"})
        or (request.history ~= nil and type(request.history) ~= "boolean") then
        return fail("INVALID", "remove requires a session and operation_key; history is a boolean", operation_key)
    end
    local current = describe(session)
    local recorded, record_fault = journal.call("session_remove", {session = session, operation_key = operation_key,
        history = request.history == true or nil})
    if record_fault then return journal_fault(record_fault, operation_key) end
    local receipt = object(recorded)
    local operation = receipt and ref(receipt.operation)
    if not operation then return unavailable("Threads returned a malformed removal receipt", operation_key) end
    if current then
        if current.lifecycle ~= "closing" and current.lifecycle ~= "closed" then
            local close_key = assert(internal_key("remove-close", operation_key))
            local _, transition_fault = journal.call("session_transition", {session = session, state = "closing", operation_key = close_key})
            if transition_fault then return journal_fault(transition_fault, operation_key) end
        end
        local finish_error: string?
        if current.lifecycle == "closed" then finish_error = part_observation.finish_removal(session)
        else finish_error = finish_closing(session, operation_key) end
        if finish_error then return unavailable(finish_error, operation_key) end
    end
    local _, absent = journal.call("session_describe", {session = session})
    if absent and absent.code ~= "NOT_FOUND" then return unavailable(absent.message, operation_key) end
    return succeed({operation = operation, session = session, state = absent and "removed" or "removing"})
end

-- rename gives the session an explicit name that its title shows from then
-- on; an empty name returns it to its automatic title.
function M.rename(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local operation_key = key(request.operation_key)
    local session = ref(request.session)
    local name = type(request.name) == "string" and (request.name):match("^%s*(.-)%s*$") or nil
    if not operation_key or not session or session:sub(1, 3) ~= "bs:" or not name or bounds.fields(request, {"session", "name", "operation_key"}) then
        return fail("INVALID", "rename requires a session, a name and operation_key", operation_key)
    end
    local renamed, rename_fault = journal.call("session_rename", {session = session, operation_key = operation_key,
        name = name ~= "" and name or nil})
    if rename_fault then return journal_fault(rename_fault, operation_key) end
    local receipt = object(renamed)
    local operation, title = receipt and ref(receipt.operation), receipt and bounds.text(receipt.title, 512)
    if not receipt or not operation or not title then return unavailable("Threads returned a malformed rename receipt", operation_key) end
    return succeed({operation = operation, session = session, title = title, name = receipt.name})
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

for _, name in ipairs({"open", "run", "send", "await", "join", "get", "history", "cancel", "close", "remove", "rename", "catalog"}) do
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
