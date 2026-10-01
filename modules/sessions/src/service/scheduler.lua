-- MIT. Threads owns the work queue and fenced turns. This scheduler keeps no
-- queue state: boot and periodic scans recover every unsettled turn.
local canonical = require("canonical")
local cancellation = require("cancellation")
local bounds = require("bounds")
local M = {}
M.MAX_SCAN = 64

type Object = {[string]: unknown}
type Sender = {kind: "session" | "principal", id: string}
type WorkReceipt = {work: string, session: string, operation: string, committed_at: string, sequence: integer,
    kind: "request", state: "queued", output_schema: string, sender: Sender}
type Due = {work: string, session: string, state: "queued" | "reserved" | "accepted",
    turn: string?, claim: string?, owner_epoch: integer?, checkpoint: unknown?, route: Object?, uncertainty: Object?,
    cancel_requested: boolean?, cancel_reason: string?}
type Page = {items: {Due}}
type Turn = {work: string, session: string, turn: string, claim: string, owner_epoch: integer,
    input: unknown, input_digest: string, output_schema: string, sender: Sender, route: Object,
    checkpoint: unknown?, context: Object?, budget: Object?, phase: "reserved" | "accepted"}
type Execution = {state: "settled", outcome: "succeeded" | "failed" | "cancelled", answer: string?,
    error: {code: string, message: string}?, usage: unknown?, checkpoint: Object?, evidence: unknown?}
    | {state: "settled", outcome: "budget_exceeded", error: {code: string, message: string},
        checkpoint: Object?, evidence: {summary: string, artifacts: {string}}}
    | {state: "pending" | "uncertain", outcome: string?, evidence: unknown?}
type Reservation = {work: string?, session: string, turn: string?, claim: string?, owner_epoch: integer?, state: string}
type Journal = {
    enqueue: (Object) -> (WorkReceipt?, string?),
    scan_due: ({limit: integer}) -> (Page?, string?),
    reserve_turn: ({session: string, operation_key: string}) -> (Reservation?, string?),
    recover_turn: ({turn: string, operation_key: string}) -> (Reservation?, string?),
    pull_turn: ({turn: string, claim: string}) -> (Turn?, string?),
    accept_turn: ({turn: string, claim: string, input_digest: string, checkpoint: unknown, operation_key: string}) -> (unknown?, string?),
    settle: (Object) -> (unknown?, string?),
    mark_uncertain: (Object) -> (unknown?, string?),
    describe_session: ({session: string}) -> (Object?, string?),
    transition_session: (Object) -> (unknown?, string?),
    target: ((string) -> (string?, string?))?,
}
type Executor = {run_turn: (Object) -> (Execution?, string?)}
type Registry = {get: (string) -> (Executor?, string?)}
type Issue = {work: string?, stage: string, reason: string}
type Pass = {scanned: integer, reserved: integer, activated: integer, recovered: integer,
    running: integer, uncertain: integer, skipped: integer, issues: {Issue}}
type Wake = () -> (boolean, string?)
type Service = {send: (Object) -> (WorkReceipt?, string?), run_pass: (string?) -> (Pass?, string?)}

local function valid_id(value: unknown): boolean
    return type(value) == "string" and #value > 0 and #value <= 256
        and value:match("^[A-Za-z0-9][A-Za-z0-9_.:@-]*$") ~= nil
end

local function object(value: unknown): Object?
    if type(value) ~= "table" then return nil end
    return value
end

local function key(prefix: string, ref: string, run_id: string?): string
    local suffix = ref:sub(-72)
    if run_id then suffix = run_id:sub(-24) .. ":" .. suffix end
    return prefix .. ":" .. suffix
end

local function add_issue(pass: Pass, work: string?, stage: string, reason: string)
    pass.issues[#pass.issues + 1] = {work = work, stage = stage, reason = reason}
end

local function finish_close(journal: Journal, pass: Pass, session: string, work: string)
    local current, read_error = journal.describe_session({session = session})
    if read_error or not current then add_issue(pass, work, "session_describe", read_error or "Threads returned no session"); return end
    if current.state ~= "closing" or current.queued ~= 0 or current.active ~= 0 then return end
    local _, close_error = journal.transition_session({session = session, state = "closed", operation_key = key("auto-close", session)})
    if close_error then add_issue(pass, work, "session_close", close_error) end
end

local function ref(value: unknown): string?
    if type(value) ~= "string" or not valid_id(value) then return nil end
    return value
end
local function sender(raw: unknown): Sender?
    local value = object(raw)
    local id = value and ref(value.id) or nil
    local kind = value and value.kind or nil
    if not id or (kind ~= "session" and kind ~= "principal") then return nil end
    return {kind = kind, id = id}
end
function M.work_receipt(raw: unknown): (WorkReceipt?, string?)
    local value = object(raw)
    if not value then return nil, "Threads returned a malformed work receipt" end
    local work, session, operation = ref(value.work), ref(value.session), ref(value.operation)
    local committed_at, output_schema = value.committed_at, value.output_schema
    local sequence, from = bounds.integer(value.sequence), sender(value.sender)
    if not work or not session or not operation or not sequence or not from or type(committed_at) ~= "string"
        or type(output_schema) ~= "string" or value.kind ~= "request" or value.state ~= "queued" then
        return nil, "Threads returned a malformed work receipt"
    end
    return {work = work, session = session, operation = operation, sequence = sequence, committed_at = committed_at,
        output_schema = output_schema, sender = from, kind = "request", state = "queued"}, nil
end
function M.reservation(raw: unknown): (Reservation?, string?)
    local value = object(raw)
    if not value then return nil, "Threads returned a malformed reservation" end
    local session, state = ref(value.session), value.state
    if not session or type(state) ~= "string" then return nil, "Threads returned a malformed reservation" end
    local work, turn, claim, epoch = ref(value.work), ref(value.turn), ref(value.claim), bounds.integer(value.owner_epoch)
    if (value.work ~= nil and not work) or (value.turn ~= nil and not turn) or (value.claim ~= nil and not claim)
        or (value.owner_epoch ~= nil and not epoch) then return nil, "Threads returned a malformed reservation" end
    return {session = session, state = state, work = work, turn = turn, claim = claim, owner_epoch = epoch}, nil
end
function M.turn(raw: unknown): (Turn?, string?)
    local value = object(raw)
    if not value then return nil, "Threads returned a malformed turn" end
    local work, session, turn, claim = ref(value.work), ref(value.session), ref(value.turn), ref(value.claim)
    local epoch, from, route = bounds.integer(value.owner_epoch), sender(value.sender), object(value.route)
    local phase, input_digest, output_schema = value.phase, value.input_digest, value.output_schema
    local context = object(value.context)
    if not work or not session or not turn or not claim or not epoch or not from or not route
        or (phase ~= "reserved" and phase ~= "accepted") or type(input_digest) ~= "string"
        or type(output_schema) ~= "string" or (value.context ~= nil and not context) then return nil, "Threads returned a malformed turn" end
    return {work = work, session = session, turn = turn, claim = claim, owner_epoch = epoch, sender = from,
        route = route, phase = phase, input = value.input, input_digest = input_digest, output_schema = output_schema,
        checkpoint = value.checkpoint, context = context}, nil
end
function M.execution(raw: unknown): (Execution?, string?)
    local value = object(raw)
    if not value then return nil, "executor returned a malformed execution" end
    local state, outcome = value.state, value.outcome
    if state == "pending" or state == "uncertain" then
        if outcome ~= nil and type(outcome) ~= "string" then return nil, "executor returned a malformed execution" end
        return {state = state, outcome = outcome, evidence = value.evidence}, nil
    end
    if state ~= "settled" or (outcome ~= "succeeded" and outcome ~= "failed" and outcome ~= "cancelled") then
        return nil, "executor returned a malformed execution"
    end
    local fault: {code: string, message: string}? = nil
    if value.error ~= nil then
        local error = object(value.error)
        if not error or type(error.code) ~= "string" or type(error.message) ~= "string" then return nil, "executor returned a malformed execution" end
        fault = {code = error.code, message = error.message}
    end
    local answer, checkpoint = value.answer, object(value.checkpoint)
    if (answer ~= nil and type(answer) ~= "string") or (value.checkpoint ~= nil and not checkpoint) then return nil, "executor returned a malformed execution" end
    return {state = "settled", outcome = outcome, answer = answer, checkpoint = checkpoint,
        usage = value.usage, error = fault, evidence = value.evidence}, nil
end
local function decode_page(raw: unknown): ({Due}?, string?)
    local value = object(raw)
    if not value or type(value.items) ~= "table" then return nil, "work_scan returned a malformed page" end
    local items = value.items
    local count: integer = 0
    for item_key in pairs(items) do
        if type(item_key) ~= "number" or item_key < 1 or math.floor(item_key) ~= item_key then return nil, "work_scan items are not a list" end
        count = count + 1
        if count > M.MAX_SCAN then return nil, "work_scan exceeded the scheduler scan bound" end
    end
    local checked: {Due} = {}
    for index = 1, count do
        local row = object(items[index])
        if not row then return nil, "work_scan returned an invalid work row" end
        local work, session, state = ref(row.work), ref(row.session), row.state
        if not work or not session or (state ~= "queued" and state ~= "reserved" and state ~= "accepted") then return nil, "work_scan returned an invalid work row" end
        local turn, claim, epoch = ref(row.turn), ref(row.claim), bounds.integer(row.owner_epoch)
        if state ~= "queued" and (not turn or not claim or not epoch) then return nil, "work_scan omitted the fenced turn identity" end
        local route, uncertainty = object(row.route), object(row.uncertainty)
        local cancel_requested, cancel_reason = row.cancel_requested, row.cancel_reason
        if (row.route ~= nil and not route) or (row.uncertainty ~= nil and not uncertainty)
            or (cancel_requested ~= nil and type(cancel_requested) ~= "boolean")
            or (cancel_reason ~= nil and type(cancel_reason) ~= "string") then return nil, "work_scan returned an invalid work row" end
        checked[#checked + 1] = {work = work, session = session, state = state, turn = turn, claim = claim, owner_epoch = epoch,
            checkpoint = row.checkpoint, route = route, uncertainty = uncertainty, cancel_requested = cancel_requested, cancel_reason = cancel_reason}
    end
    return checked, nil
end
function M.page(raw: unknown): (Page?, string?)
    local items, err = decode_page(raw)
    if not items then return nil, err end
    return {items = items}, nil
end

local function accepted_turn(journal: Journal, turn: Turn): (boolean, string?)
    if turn.phase == "accepted" then return true, nil end
    local accepted, accept_error = journal.accept_turn({turn = turn.turn, claim = turn.claim,
        input_digest = turn.input_digest, checkpoint = turn.checkpoint or {attempt_id = turn.turn, generation = 1},
        operation_key = key("accept", turn.turn)})
    if accept_error or not accepted then return false, accept_error or "Threads did not accept the turn" end
    return true, nil
end

local function run_cancel(journal: Journal, pass: Pass, due: Due, run_id: string)
    if due.state == "queued" then pass.skipped = pass.skipped + 1; return end
    local recovered, recover_error = journal.recover_turn({turn = assert(due.turn),
        operation_key = key("cancel-recover", assert(due.turn), run_id)})
    if recover_error or not recovered or not recovered.turn or not recovered.claim then
        add_issue(pass, due.work, "cancel_recover", recover_error or "Threads returned no cancellation claim"); return
    end
    local raw_turn, pull_error = journal.pull_turn({turn = recovered.turn, claim = recovered.claim})
    if pull_error or not raw_turn then add_issue(pass, due.work, "cancel_pull", pull_error or "Threads returned no turn"); return end
    local turn = raw_turn
    if turn.work ~= due.work or turn.session ~= due.session or turn.turn ~= recovered.turn or turn.claim ~= recovered.claim then
        add_issue(pass, due.work, "cancel_pull", "Threads returned a different fenced turn"); return
    end
    if turn.phase == "reserved" then
        local accepted, accept_error = accepted_turn(journal, turn)
        if not accepted then add_issue(pass, due.work, "cancel_accept", accept_error or "turn acceptance failed"); return end
        local result: Object = {state = "cancelled", error = {code = "CANCELLED", message = due.cancel_reason or "work cancelled before executor activation"},
            artifacts = {"turn was cancelled before the external executor started"}}
        local settled, settle_error = journal.settle({turn = turn.turn, claim = turn.claim, result = result,
            operation_key = key("cancel-settle", turn.turn)})
        if settle_error or not settled then add_issue(pass, due.work, "cancel_settle", settle_error or "Threads did not settle cancelled work"); return end
        pass.activated = pass.activated + 1
        finish_close(journal, pass, turn.session, turn.work)
        return
    end
    local route = object(turn.route)
    local placement_methods = route and object(route.placement_methods)
    local checkpoint = object(turn.checkpoint)
    local attempt_id = checkpoint and checkpoint.attempt_id or turn.turn
    if not placement_methods or type(attempt_id) ~= "string" then
        local _, mark_error = journal.mark_uncertain({turn = turn.turn, claim = turn.claim,
            evidence = {summary = "cancelled turn has no admitted placement attempt", artifacts = {}},
            operation_key = key("cancel-uncertain", turn.turn)})
        if mark_error then add_issue(pass, due.work, "cancel_uncertain", mark_error) end
        return
    end
    local stopped = cancellation.stop(placement_methods, attempt_id, route)
    if stopped.state == "pending" then pass.running = pass.running + 1; return end
    if stopped.state == "uncertain" then
        local _, mark_error = journal.mark_uncertain({turn = turn.turn, claim = turn.claim,
            evidence = stopped.evidence, operation_key = key("cancel-uncertain", turn.turn)})
        if mark_error then add_issue(pass, due.work, "cancel_uncertain", mark_error) else pass.uncertain = pass.uncertain + 1 end
        return
    end
    local result: Object = {state = "cancelled", error = {code = "CANCELLED", message = due.cancel_reason or "work cancelled"},
        artifacts = stopped.evidence.artifacts}
    local settled, settle_error = journal.settle({turn = turn.turn, claim = turn.claim, result = result,
        operation_key = key("cancel-settle", turn.turn)})
    if settle_error or not settled then add_issue(pass, due.work, "cancel_settle", settle_error or "Threads did not settle cancelled work"); return end
    pass.activated = pass.activated + 1
    finish_close(journal, pass, turn.session, turn.work)
end

local function run_due(journal: Journal, registry: Registry, pass: Pass, due: Due, run_id: string)
    if due.uncertainty then pass.uncertain = pass.uncertain + 1; return end
    local reservation: Reservation? = nil
    if due.state == "queued" then
        local reserved, reserve_error = journal.reserve_turn({session = due.session,
            operation_key = key("reserve", due.work)})
        if reserve_error then add_issue(pass, due.work, "turn_reserve", reserve_error); return end
        if not reserved or not reserved.turn then pass.skipped = pass.skipped + 1; return end
        reservation = reserved
        pass.reserved = pass.reserved + 1
    else
        local recovered, recover_error = journal.recover_turn({turn = assert(due.turn),
            operation_key = key("recover", assert(due.turn), run_id)})
        if recover_error then add_issue(pass, due.work, "turn_recover", recover_error); return end
        if not recovered or not recovered.turn or not recovered.claim then pass.skipped = pass.skipped + 1; return end
        reservation = recovered
        pass.recovered = pass.recovered + 1
    end
    local claim = reservation and reservation.claim
    local turn_ref = reservation and reservation.turn
    if not reservation or not claim or not turn_ref or not valid_id(claim) or not valid_id(turn_ref) then
        add_issue(pass, due.work, "turn_reserve", "Threads returned a malformed reservation"); return
    end
    if reservation.work and reservation.work ~= due.work then
        add_issue(pass, due.work, "turn_reserve", "Threads reserved another work item"); return
    end
    local raw_turn, pull_error = journal.pull_turn({turn = turn_ref, claim = claim})
    if pull_error or not raw_turn then add_issue(pass, due.work, "turn_pull", pull_error or "Threads returned no turn"); return end
    local turn = raw_turn
    if turn.work ~= due.work or turn.session ~= due.session or turn.turn ~= turn_ref or turn.claim ~= claim then
        add_issue(pass, due.work, "turn_pull", "Threads returned a different fenced turn"); return
    end
    local accepted, accept_error = accepted_turn(journal, turn)
    if not accepted then add_issue(pass, due.work, "turn_accept", accept_error or "turn acceptance failed"); return end
    local executor, executor_error = registry.get("external")
    if executor_error or not executor then add_issue(pass, due.work, "executor", executor_error or "external executor is unavailable"); return end
    local route = object(turn.route)
    local sender = object(turn.sender)
    local input, input_error = M.prompt(turn.input)
    if not route or not sender or not input then
        add_issue(pass, due.work, "turn_input", input_error or "Threads returned an incomplete executor input"); return
    end
    local context = object(turn.context) or {}
    local admission: Object = {attempt_id = turn.turn, definition_ref = route.definition,
        workspace_id = route.workspace_id, owner_id = route.owner_id, thread_id = route.thread_id,
        session_ref = route.session_ref, action_id = route.action_id, brief = input,
        expected_plan_digest = route.plan_digest, profile_id = route.profile_id}
    if route.saved_profile_id ~= nil then admission.saved_profile_id = route.saved_profile_id end
    if route.saved_profile_revision ~= nil then admission.saved_profile_revision = route.saved_profile_revision end
    if route.workdir ~= nil then admission.workdir = route.workdir end
    if not valid_id(admission.definition_ref) or not valid_id(admission.workspace_id) or not valid_id(admission.owner_id)
        or not valid_id(admission.thread_id) or not valid_id(admission.session_ref) or not valid_id(admission.action_id)
        or type(admission.expected_plan_digest) ~= "string" then
        add_issue(pass, due.work, "turn_input", "Threads returned an incomplete retained session admission route"); return
    end
    local invocation: Object = {attempt_id = turn.turn,
        generation = turn.owner_epoch, recovery = due.state ~= "queued", prompt = input, sender = sender, admission = admission,
        driver_binding_ref = route.driver_binding_ref, profile_id = route.profile_id,
        driver_methods = route.driver_methods, budget = turn.budget,
        placement_methods = route.placement_methods, checkpoint = context}
    local observation_target: string? = "bee.threads.service:turn_observation"
    if journal.target then
        local selected_target, target_error = journal.target("turn_observation")
        if target_error or not selected_target then
            add_issue(pass, due.work, "turn_observation", target_error or "Threads has no observation target")
            return
        end
        observation_target = selected_target
    end
    invocation.claim = turn.claim
    invocation.observation_target = observation_target
    if context.attempt_id ~= nil then invocation.previous_attempt_id = context.attempt_id end
    local outcome, run_error = executor.run_turn(invocation)
    if run_error or not outcome then
        local reason = run_error or "external executor returned no outcome"
        add_issue(pass, due.work, "run_turn", reason)
        local _, mark_error = journal.mark_uncertain({turn = turn.turn, claim = turn.claim,
            evidence = {summary = reason, artifacts = {}}, operation_key = key("executor-error", turn.turn)})
        if mark_error then add_issue(pass, due.work, "work_uncertain", mark_error)
        else pass.uncertain = pass.uncertain + 1 end
        return
    end
    if outcome.state == "pending" or outcome.state == "uncertain" then
        if outcome.state == "pending" then pass.running = pass.running + 1 else pass.uncertain = pass.uncertain + 1 end
        if outcome.state == "uncertain" then
            local evidence = object(outcome.evidence) or {}
            local summary = type(evidence.message) == "string" and evidence.message
                or type(evidence.code) == "string" and evidence.code or "executor could not prove the turn outcome"
            local _, mark_error = journal.mark_uncertain({turn = turn.turn, claim = turn.claim,
                evidence = {summary = summary, artifacts = {}}, operation_key = key("uncertain", turn.turn)})
            if mark_error then add_issue(pass, due.work, "work_uncertain", mark_error) end
        end
        return
    end
    local result: Object
    if outcome.outcome == "succeeded" then
        result = {state = "succeeded", schema = turn.output_schema, value = {text = outcome.answer or ""},
            artifacts = {}, usage = outcome.usage}
    elseif outcome.outcome == "budget_exceeded" then
        result = {state = "budget_exceeded", error = outcome.error, evidence = outcome.evidence,
            artifacts = outcome.evidence.artifacts}
    else
        local error_value = outcome.error or {code = "EXECUTOR_FAILED", message = "the external turn failed"}
        result = {state = outcome.outcome, error = {code = error_value.code or "EXECUTOR_FAILED",
            message = error_value.message or "the external turn failed", retry = "never"}, artifacts = {}}
    end
    local settled, settle_error = journal.settle({turn = turn.turn, claim = turn.claim, result = result,
        operation_key = key("settle", turn.turn), context = outcome.checkpoint})
    if settle_error or not settled then add_issue(pass, due.work, "work_settle", settle_error or "Threads did not settle the work"); return end
    pass.activated = pass.activated + 1
    finish_close(journal, pass, turn.session, turn.work)
end

function M.create(journal: Journal, registry: Registry, wake: Wake?, run_id: string): (Service?, string?)
    if type(journal) ~= "table" or type(journal.enqueue) ~= "function" or type(journal.scan_due) ~= "function"
        or type(journal.reserve_turn) ~= "function" or type(journal.recover_turn) ~= "function"
        or type(journal.pull_turn) ~= "function" or type(journal.accept_turn) ~= "function"
        or type(journal.settle) ~= "function" or type(journal.mark_uncertain) ~= "function"
        or type(journal.describe_session) ~= "function" or type(journal.transition_session) ~= "function" then
        return nil, "Threads journal adapter is incomplete"
    end
    if type(registry) ~= "table" or type(registry.get) ~= "function" then return nil, "executor registry is incomplete" end
    if not valid_id(run_id) then return nil, "scheduler run identity is malformed" end
    if wake ~= nil and type(wake) ~= "function" then return nil, "wake hint is malformed" end
    local service: Service = {
        send = function(request: Object): (WorkReceipt?, string?)
            if not valid_id(request.session) or type(request.operation_key) ~= "string" or #request.operation_key == 0
                or #request.operation_key > 128 or request.input == nil then return nil, "INVALID: session, operation_key and input are required" end
            local enqueue = {session = request.session, operation_key = request.operation_key, input = request.input,
                output_schema = request.output_schema or "bee:Text@1", budget = request.budget}
            local receipt, enqueue_error = journal.enqueue(enqueue)
            if enqueue_error or not receipt then return nil, enqueue_error or "Threads did not return a work receipt" end
            if wake then
                local delivered, wake_error = wake()
                if not delivered then return receipt, wake_error or "wake hint was not delivered" end
            end
            return receipt, nil
        end,
        run_pass = function(only_work: string?): (Pass?, string?)
            local page, scan_error = journal.scan_due({limit = M.MAX_SCAN})
            if scan_error or not page then return nil, scan_error or "Threads returned no work page" end
            local work, page_error = decode_page(page)
            if not work then return nil, page_error end
            local pass: Pass = {scanned = #work, reserved = 0, activated = 0, recovered = 0,
                running = 0, uncertain = 0, skipped = 0, issues = {}}
            for _, due in ipairs(work) do
                if only_work ~= nil and due.work ~= only_work then pass.skipped = pass.skipped + 1
                elseif due.cancel_requested then run_cancel(journal, pass, due, run_id)
                else run_due(journal, registry, pass, due, run_id) end
            end
            return pass, nil
        end,
    }
    return service, nil
end

function M.prompt(value: unknown): (string?, string?)
    if type(value) == "string" then return value, nil end
    return canonical.encode(value, 16384, 16)
end

return M
