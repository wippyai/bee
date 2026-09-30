-- MIT. Sessions owns admission and the public session operations; Threads
-- remains the only durable store.
local bounds = require("bounds")
local journal = require("journal")
local admission = require("admission")
local catalog_service = require("catalog_service")
local driver_route = require("driver_route")
local hash = require("hash")
local security = require("security")
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
    local active = type(row.active) == "number" and row.active or 0
    local uncertain = type(row.uncertain) == "number" and row.uncertain or 0
    local stalled = type(row.stalled) == "number" and row.stalled or 0
    local lifecycle = row.state
    if lifecycle ~= "active" and lifecycle ~= "suspended" and lifecycle ~= "closing" and lifecycle ~= "closed" then
        return nil, "Threads returned an unsupported session lifecycle"
    end
    local activity = "idle"
    if stalled > 0 then activity = "stalled"
    elseif uncertain > 0 then activity = "blocked"
    elseif active > 0 or queued > 0 then activity = "working" end
    local at = type(row.updated_at) == "string" and row.updated_at or row.created_at
    if type(at) ~= "string" then return nil, "Threads omitted the session timestamp" end
    return {session = row.session, revision = row.revision, incarnation = 1, title = row.title,
        lifecycle = lifecycle, activity = activity,
        execution = {state = active > 0 and "running" or "quiescent", evidence_at = at, stale = false},
        queue_count = queued, effective_limits = {}, continuity = {mode = "provider_resume"}, actions = {}}, nil
end

local function describe(session: string): (Object?, string?)
    local value, err = journal.invoke("session_describe", {session = session})
    if err or not value then return nil, err or "Threads returned no session" end
    return snapshot(value)
end

local function open(request: Object): Reply
    local operation_key = key(request.operation_key)
    local spec = object(request.spec)
    if not operation_key or not spec or bounds.fields(spec, {"definition", "profile", "workdir"}) then
        return fail("INVALID", "open requires a definition, optional profile/workdir, and operation_key", operation_key)
    end
    local definition = ref(spec.definition)
    if not definition then return fail("INVALID", "definition is not a ref", operation_key) end
    local profile = object(spec.profile)
    local profile_id: string? = nil
    local profile_revision: integer? = nil
    if spec.profile ~= nil then
        if not profile or bounds.fields(profile, {"id", "revision"}) then return fail("INVALID", "profile is malformed", operation_key) end
        profile_id = ref(profile.id)
        profile_revision = bounds.integer(profile.revision)
        if not profile_id or not profile_revision or profile_revision < 1 then return fail("INVALID", "profile is malformed", operation_key) end
    end
    local workdir: string? = nil
    if spec.workdir ~= nil then
        workdir = ref(spec.workdir)
        if not workdir then return fail("INVALID", "workdir is not a resource ref", operation_key) end
    end
    local owner_id, workspace = identity()
    if not owner_id or not workspace then return fail("DENIED", "the authenticated caller has no workspace identity", operation_key) end
    local plan, refused = admission.resolve(definition, nil, workspace, profile_id, profile_revision)
    if not plan then
        local fault = object(refused)
        local details = fault and object(fault.error)
        return fail(details and tostring(details.code or "UNAVAILABLE") or "UNAVAILABLE",
            details and tostring(details.message or "admission refused the session") or "admission refused the session", operation_key)
    end
    local plan_value = object(plan)
    local driver_binding_ref = plan_value and ref(plan_value.binding_ref)
    local profile_ref = plan_value and ref(plan_value.profile_id)
    if not plan_value or not driver_binding_ref or not profile_ref then
        return unavailable("admission returned an incomplete executor route", operation_key)
    end
    if type(plan_value.session_resource) ~= "string" or plan_value.session_resource == "" then
        return fail("UNAVAILABLE", "the selected definition has no retained session resource", operation_key)
    end
    local methods, methods_error = driver_route.resolve(driver_binding_ref)
    if not methods then return unavailable(methods_error or "selected driver methods are unavailable", operation_key) end
    local placement_methods = object(plan_value.placement_methods)
    if not placement_methods then return unavailable("admission omitted placement operations", operation_key) end
    local route: Object = {definition = definition, plan_digest = plan_value.plan_digest,
        saved_profile_id = profile_id, saved_profile_revision = profile_revision, workdir = workdir,
        driver_binding_ref = driver_binding_ref, profile_id = profile_ref, driver_methods = methods,
        placement_methods = placement_methods}
    local created, create_error = journal.invoke("session_create", {operation_key = operation_key,
        title = plan_value.title or definition, route = route})
    if create_error or not created then return unavailable(create_error or "Threads returned no open receipt", operation_key) end
    local receipt = object(created)
    local session = receipt and ref(receipt.session)
    local operation = receipt and ref(receipt.operation)
    if not session or not operation then return unavailable("Threads returned a malformed open receipt", operation_key) end
    local current, read_error = describe(session)
    if not current then return unavailable(read_error or "cannot read the opened session", operation_key) end
    return succeed({session = session, operation = operation, snapshot = current})
end

local function send(request: Object): Reply
    local operation_key = key(request.operation_key)
    local session = ref(request.session)
    if not operation_key or not session or request.input == nil
        or bounds.fields(request, {"session", "input", "output", "expected_incarnation", "operation_key"}) then
        return fail("INVALID", "send requires session, input, and operation_key", operation_key)
    end
    if request.expected_incarnation ~= nil and request.expected_incarnation ~= 1 then
        return fail("STALE", "session incarnation changed", operation_key)
    end
    local current, read_error = describe(session)
    if not current then return fail("NOT_FOUND", read_error or "session is unavailable", operation_key) end
    if current.lifecycle ~= "active" then return fail("CONFLICT", "session is not accepting work", operation_key) end
    local output_schema = request.output == nil and "bee:Text@1" or ref(request.output)
    if not output_schema then return fail("INVALID", "output must be a schema ref", operation_key) end
    local receipt, send_error = journal.invoke("work_send", {session = session, operation_key = operation_key,
        input = request.input, output_schema = output_schema})
    if send_error or not receipt then return unavailable(send_error or "Threads returned no work receipt", operation_key) end
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
            state.phase = "settled"
            state.result = {outcome = outcome, schema = result.schema or row.output_schema,
                value = result.value, artifacts = result.artifacts or {}, usage = result.usage or {}}
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

local function session_get(request: Object): Reply
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

local function work_observation(subject: string): (Object?, string?)
    local value, err = journal.invoke("work_describe", {work = subject})
    if err or not value then return nil, err or "work is unavailable" end
    local row = object(value)
    local state = row and work_value(row)
    if not state then return nil, "Threads returned a malformed work state" end
    local result = object((state :: Object).result)
    local cursor = tostring((state :: Object).revision)
    if result then
        return {subject_kind = "work", subject = subject, cursor = cursor, tag = "ready", result = result}, nil
    end
    local uncertainty = object((state :: Object).uncertainty)
    if uncertainty then
        return {subject_kind = "work", subject = subject, cursor = cursor, tag = "uncertain", evidence = uncertainty}, nil
    end
    return {subject_kind = "work", subject = subject, cursor = cursor, tag = "pending", reason = "timeout"}, nil
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
    local receipt, receipt_error = operation_receipt(description :: Object)
    if not receipt then return nil, receipt_error end
    local target = ref((description :: Object).target)
    if not target then return nil, "operation target is malformed" end
    local observation: Object
    if receipt.effect == "cancel" then
        local value, work_error = journal.invoke("work_describe", {work = target})
        if work_error or not value then return nil, work_error or "cancelled work is unavailable" end
        local state, state_error = work_value(value)
        if not state then return nil, state_error end
        local work_result = object((state :: Object).result)
        local uncertainty = object((state :: Object).uncertainty)
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
        end
    elseif receipt.effect == "close" then
        local current, read_error = describe(target)
        if not current then return nil, read_error end
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
    return {operation = subject, operation_key = (description :: Object).operation_key,
        revision = 1, receipt = receipt, observation = observation}, nil
end

local function await(request: Object): Reply
    local subject = ref(request.subject)
    if not subject or bounds.fields(request, {"subject", "timeout_ms"}) then return fail("INVALID", "await needs a work or operation ref") end
    if subject:sub(1, 3) == "bw:" then
        local value, err = work_observation(subject)
        if not value then return unavailable(err or "work is unavailable", nil) end
        return succeed(value)
    elseif subject:sub(1, 3) == "bo:" then
        local state, state_error = operation_state(subject)
        if not state then return unavailable(state_error or "operation is unavailable", nil) end
        return succeed((state :: Object).observation)
    end
    return fail("INVALID", "await needs a work or operation ref")
end

local function catalog(request: Object): Reply
    local _, workspace = identity()
    if not workspace then return fail("DENIED", "the authenticated caller has no workspace", nil) end
    local page, catalog_error = catalog_service.list(request, workspace)
    if not page then return fail("INVALID", catalog_error or "catalog request is invalid", nil) end
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

local function finish_closing(session: string, current: Object, operation_key: string): string?
    if current.lifecycle ~= "closing" or current.queue_count > 0
        or (object(current.execution) and (object(current.execution) :: Object).state == "running") then return nil end
    local close_key, key_error = internal_key("close-final", operation_key)
    if not close_key then return key_error or "cannot derive final close operation key" end
    local _, close_error = journal.invoke("session_transition", {session = session, state = "closed",
        expected_revision = current.revision, operation_key = close_key})
    return close_error
end

local function control_receipt(operation: string, subject: string, effect: "cancel" | "close"): Object
    return {operation = operation, subject = subject, state = "requested", effect = effect}
end

local function close(request: Object): Reply
    local operation_key = key(request.operation_key)
    local session = ref(request.session)
    if not operation_key or not session
        or bounds.fields(request, {session = true, expected_incarnation = true, operation_key = true}) then
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
    local finish_error = finish_closing(session, current, operation_key)
    if finish_error then return unavailable(finish_error, operation_key) end
    return succeed(control_receipt(operation, session, "close"))
end

local function cancel(request: Object): Reply
    local operation_key = key(request.operation_key)
    local work = ref(request.work)
    local reason = request.reason == nil and nil or bounds.text(request.reason, 16384)
    if not operation_key or not work or work:sub(1, 3) ~= "bw:"
        or (request.reason ~= nil and not reason)
        or bounds.fields(request, {work = true, reason = true, expected_incarnation = true, operation_key = true}) then
        return fail("INVALID", "cancel requires a work ref, optional reason, and operation_key", operation_key)
    end
    local cancel_operation_key = operation_key :: string
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
    local result = cancellation.stop(placement_methods, attempt_id)
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

local function join(request: Object): Reply
    local operation_key = key(request.operation_key)
    if not operation_key or bounds.fields(request, {works = true, policy = true, quorum = true,
        timeout_ms = true, operation_key = true}) then
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
    local timeout = request.timeout_ms == nil and nil or bounds.count(request.timeout_ms)
    if request.timeout_ms ~= nil and (not timeout or timeout > 60000) then return fail("INVALID", "timeout_ms is outside its bound", operation_key) end
    local caller, workspace = identity()
    if not caller or not workspace then return fail("DENIED", "the authenticated caller has no workspace", operation_key) end
    local works: {string} = {}
    local children: {Object} = {}
    local seen: {[string]: boolean} = {}
    local node: string? = nil
    local successful: {string} = {}
    local values: {unknown} = {}
    local pending = false
    local blocked: Object? = nil
    local uncertain: Object? = nil
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
        local observation, observe_error = work_observation(work)
        if not observation then return unavailable(observe_error or "cannot observe joined work", operation_key) end
        children[index] = observation :: Object
        local tagged = observation :: Object
        if tagged.tag == "pending" then pending = true
        elseif tagged.tag == "blocked" then blocked = object(tagged.blocker)
        elseif tagged.tag == "uncertain" then uncertain = object(tagged.evidence)
        else
            local result = object(tagged.result)
            if result and result.outcome == "succeeded" then
                successful[#successful + 1] = work
                values[#values + 1] = result.value
            end
        end
    end
    local digest, digest_error = hash.sha256("bee.sessions.join\n" .. operation_key .. "\n" .. table.concat(works, "\n"))
    if not digest then return unavailable("cannot derive join reference: " .. tostring(digest_error), operation_key) end
    local joined_ref = "bj:" .. (node or "node") .. ":" .. workspace .. ":" .. digest:sub(1, 32)
    local base: Object = {subject_kind = "join", subject = joined_ref, cursor = "1", children = children}
    if uncertain then base.tag = "uncertain"; base.evidence = uncertain
    elseif blocked then base.tag = "blocked"; base.blocker = blocked
    elseif policy == "first_success" and #successful > 0 then
        base.tag = "ready"; base.result = {succeeded = true, winners = successful, values = values}
    elseif policy == "quorum" and #successful >= (quorum :: integer) then
        base.tag = "ready"; base.result = {succeeded = true, winners = successful, values = values}
    elseif pending then
        base.tag = "pending"; base.reason = "timeout"
    else
        local all_success = #successful == #works
        local succeeded = policy == "all_settled" or policy == "all_success" and all_success
            or policy == "first_success" and #successful > 0 or policy == "quorum" and #successful >= (quorum :: integer)
        base.tag = "ready"
        local result: Object = {succeeded = succeeded, winners = successful}
        if succeeded then result.values = values end
        base.result = result
    end
    return succeed(base)
end

local function list(request: Object): Reply
    if bounds.fields(request, {filter = true, cursor = true}) then return fail("INVALID", "list accepts only filter and cursor") end
    local filter = object(request.filter)
    if request.filter ~= nil and (not filter or bounds.fields(filter, {lifecycle = true, activity = true})) then
        return fail("INVALID", "session filter is malformed")
    end
    local lifecycle = filter and filter.lifecycle or nil
    if lifecycle ~= nil and lifecycle ~= "opening" and lifecycle ~= "active" and lifecycle ~= "suspended"
        and lifecycle ~= "closing" and lifecycle ~= "closed" then return fail("INVALID", "lifecycle filter is invalid") end
    local activity = filter and filter.activity or nil
    if activity ~= nil and activity ~= "idle" and activity ~= "working" and activity ~= "blocked" and activity ~= "stalled" then
        return fail("INVALID", "activity filter is invalid")
    end
    local cursor = request.cursor == nil and nil or ref(request.cursor)
    if request.cursor ~= nil and not cursor then return fail("INVALID", "cursor is invalid") end
    local page, scan_error = journal.invoke("session_scan", {cursor = cursor, limit = 64})
    if scan_error or not page then return unavailable(scan_error or "Threads returned no session page", nil) end
    local scan = object(page)
    local refs = scan and scan.items
    if type(refs) ~= "table" then return unavailable("Threads returned a malformed session page", nil) end
    local items: {Object} = {}
    for _, raw_ref in ipairs(refs :: {unknown}) do
        local session = ref(raw_ref)
        if not session then return unavailable("Threads returned a malformed session ref", nil) end
        local current, read_error = describe(session)
        if not current then return unavailable(read_error or "cannot read a listed session", nil) end
        if (lifecycle == nil or current.lifecycle == lifecycle) and (activity == nil or current.activity == activity) then
            items[#items + 1] = current
        end
    end
    return succeed({items = items, next = scan and ref(scan.next) or nil})
end

function M.call(method: string, request: unknown): Reply
    local input = object(request)
    if not input then return fail("INVALID", "request must be an object", nil) end
    if method == "open" then return open(input) end
    if method == "run" then
        local operation_key = key(input.operation_key)
        if not operation_key then return fail("INVALID", "run requires operation_key", nil) end
        local digest, hash_error = hash.sha256("bee.sessions.run.session\n" .. operation_key)
        if not digest then return unavailable("cannot derive the run session key: " .. tostring(hash_error), operation_key) end
        local opened = open({spec = input.spec, operation_key = "run-session:" .. digest})
        if not opened.ok then return opened end
        local receipt = object(opened.value)
        if not receipt then return unavailable("open returned no session receipt", operation_key) end
        return send({session = receipt.session, input = input.input, output = input.output,
            expected_incarnation = 1, operation_key = operation_key})
    end
    if method == "send" then return send(input) end
    if method == "get" then return session_get(input) end
    if method == "await" then return await(input) end
    if method == "list" then return list(input) end
    if method == "catalog" then return catalog(input) end
    if method == "join" then return join(input) end
    if method == "close" then return close(input) end
    if method == "cancel" then return cancel(input) end
    return fail("UNSUPPORTED", "unknown sessions operation", nil)
end

return M
