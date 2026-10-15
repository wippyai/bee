-- MIT. Session work and operation observations.
local bounds = require("bounds")
local journal = require("journal")
local hash = require("hash")
local security = require("security")
local cancellation = require("cancellation")
local time = require("time")
local session_protocol = require("session_protocol")
local record_values = require("record_values")
local snapshot = require("snapshot").decode

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

local finish_closing: (string, string) -> string?
local function describe(session: string): (Object?, string?)
    local value, err = journal.invoke("session_describe", {session = session})
    if err or not value then return nil, err or "Threads returned no session" end
    return snapshot(value)
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

function M.history(raw_request: unknown): Reply
    local input, refused = request_input(raw_request)
    if not input then return assert(refused) end
    local session = ref(input.session)
    if not session or bounds.fields(input, {"session", "cursor", "limit"}) then return fail("INVALID", "history requires a session") end
    local page, page_error = journal.invoke("work_history", input)
    if page_error or not page then return unavailable(page_error or "history unavailable", nil) end
    return succeed(page)
end

M.object = object
M.fail = fail
M.unavailable = unavailable
M.succeed = succeed
M.request_input = request_input
M.identity = identity
M.key = key
M.ref = ref
M.finish_closing = finish_closing
M.describe = describe
M.work_value = work_value
M.operation_state = operation_state
M.observed = observed
M.work_observation = work_observation
M.awaited = awaited
M.now_ms = now_ms
M.timeout_of = timeout_of
M.op_descriptor = op_descriptor
M.operation_receipt = operation_receipt
M.internal_key = internal_key
M.cancel_settle_key = cancel_settle_key
return M
