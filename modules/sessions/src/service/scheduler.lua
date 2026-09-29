-- MIT. Threads commits queued work and fenced reservations. This scheduler
-- holds no queue state: every pass re-reads the owner journal so boot and
-- periodic scans recover dropped wake hints.
local M = {}
M.MAX_SCAN = 64

type SendRequest = {session: string, operation_key: string, executor_id: string, input: unknown,
    input_digest: string, output_schema: string}
type WorkReceipt = {work: string, session: string, operation: string, sequence: integer,
    committed_at: string, kind: "request", state: "queued", output_schema: string}
type Claim = {work: string, session: string, claim_ref: string, executor_id: string, epoch: integer}
type ExecutionIntent = {execution_ref: string, claim_ref: string?, binding_ref: string?, plan_digest: string?}
type DueWork = {work: string, session: string, executor_id: string, state: "queued" | "reserved" | "accepted",
    claim: Claim?, execution: ExecutionIntent?}
type DuePage = {items: {DueWork}}
type Plan = {executor_id: string, definition_digest: string?, binding_ref: string?, features: {string}?}
type Prepared = {intent: ExecutionIntent, checkpoint: unknown?}
type Evidence = {state: "not_started" | "running" | "recoverable" | "quiescent" | "unknown", execution: ExecutionIntent?, checkpoint: unknown?}
type Journal = {
    enqueue: (SendRequest) -> (WorkReceipt?, string?),
    scan_due: ({limit: integer}) -> (DuePage?, string?),
    reserve_turn: ({work: string, session: string}) -> (Claim?, string?),
    link_execution: (Claim, ExecutionIntent) -> (boolean, string?),
}
type Executor = {
    negotiate: (Claim) -> (Plan?, string?),
    prepare: (Claim, Plan, Evidence) -> (Prepared?, string?),
    activate: (Claim, Prepared) -> (unknown?, string?),
    reconcile: ({claim: Claim, execution: ExecutionIntent?}) -> (Evidence?, string?),
}
type Registry = {get: (string) -> (Executor?, string?)}
type Issue = {work: string?, stage: string, reason: string}
type Pass = {scanned: integer, reserved: integer, activated: integer, resumed: integer,
    running: integer, quiescent: integer, uncertain: integer, skipped: integer, issues: {Issue}}
type Wake = () -> (boolean, string?)
type Service = {send: (SendRequest) -> (WorkReceipt?, string?), run_pass: () -> (Pass?, string?)}

local function valid_id(value: unknown): boolean
    return type(value) == "string" and #value > 0 and #value <= 256 and value:match("^[A-Za-z0-9][A-Za-z0-9_.:@-]*$") ~= nil
end

local function valid_session_ref(value: unknown): boolean
    if type(value) ~= "string" or #value > 256 then return false end
    local node, workspace, ref = value:match("^bs:([^:]+):([^:]+):([^:]+)$")
    return node ~= nil and #node > 0 and #workspace > 0 and #ref > 0
end

local function valid_send(request: SendRequest): string?
    if type(request) ~= "table" then return "request must be an object" end
    if not valid_session_ref(request.session) then return "session ref is malformed" end
    if type(request.operation_key) ~= "string" or #request.operation_key == 0 or #request.operation_key > 128 then return "operation_key is malformed" end
    if not valid_id(request.executor_id) then return "executor_id is malformed" end
    if type(request.input) == "string" then
        if #request.input > 16384 then return "input exceeds 16384 bytes" end
    elseif type(request.input) ~= "table" then
        return "input must be text or a typed value"
    end
    if not valid_id(request.input_digest) then return "input_digest is malformed" end
    if not valid_id(request.output_schema) then return "output_schema is malformed" end
    return nil
end

local function valid_claim(claim: unknown): boolean
    if type(claim) ~= "table" then return false end
    local value = claim :: {[string]: unknown}
    return valid_id(value.work) and valid_session_ref(value.session) and valid_id(value.claim_ref)
        and valid_id(value.executor_id) and type(value.epoch) == "number" and value.epoch >= 1 and value.epoch == math.floor(value.epoch)
end

local function add_issue(pass: Pass, work: string?, stage: string, reason: string)
    pass.issues[#pass.issues + 1] = {work = work, stage = stage, reason = reason}
end

local function due_items(page: DuePage): ({DueWork}?, string?)
    if type(page) ~= "table" or type(page.items) ~= "table" then return nil, "scan_due returned a malformed page" end
    local items = page.items :: {unknown}
    local count = 0
    for key in pairs(items) do
        if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return nil, "scan_due items are not a list" end
        count = count + 1
        if count > M.MAX_SCAN then return nil, "scan_due exceeded the scheduler scan bound" end
    end
    local checked: {DueWork} = {}
    for index = 1, count do
        local item = items[index]
        if type(item) ~= "table" then return nil, "scan_due returned an invalid work row" end
        local row = item :: {[string]: unknown}
        if not valid_id(row.work) or not valid_session_ref(row.session) or not valid_id(row.executor_id)
            or (row.state ~= "queued" and row.state ~= "reserved" and row.state ~= "accepted") then
            return nil, "scan_due returned an invalid work row"
        end
        if row.state ~= "queued" and not valid_claim(row.claim) then return nil, "scan_due omitted its fenced claim" end
        checked[#checked + 1] = row :: DueWork
    end
    return checked, nil
end

local function process_due(journal: Journal, registry: Registry, pass: Pass, due: DueWork)
    local claim = due.claim
    if due.state == "queued" then
        local reserved, reserve_error = journal.reserve_turn({work = due.work, session = due.session})
        if reserve_error then add_issue(pass, due.work, "reserve_turn", tostring(reserve_error)); return end
        if not reserved then pass.skipped = pass.skipped + 1; return end
        claim = reserved
        pass.reserved = pass.reserved + 1
    end
    if not valid_claim(claim) or not claim then add_issue(pass, due.work, "reserve_turn", "Threads returned a malformed claim"); return end
    if claim.work ~= due.work or claim.session ~= due.session or claim.executor_id ~= due.executor_id then
        add_issue(pass, due.work, "reserve_turn", "Threads claim does not match the queued work"); return
    end
    local executor, executor_error = registry.get(claim.executor_id)
    if executor_error or not executor then add_issue(pass, due.work, "executor", tostring(executor_error or "selected executor is unavailable")); return end
    local evidence, reconcile_error = executor.reconcile({claim = claim, execution = due.execution})
    if reconcile_error or type(evidence) ~= "table" then
        add_issue(pass, due.work, "reconcile", tostring(reconcile_error or "executor returned malformed evidence")); return
    end
    if evidence.state == "running" then pass.running = pass.running + 1; return end
    if evidence.state == "quiescent" then pass.quiescent = pass.quiescent + 1; return end
    if evidence.state == "unknown" then pass.uncertain = pass.uncertain + 1; return end
    if evidence.state ~= "not_started" and evidence.state ~= "recoverable" then
        add_issue(pass, due.work, "reconcile", "executor returned an unsupported reconciliation state"); return
    end
    if evidence.state == "recoverable" and not due.execution then
        add_issue(pass, due.work, "reconcile", "recoverable execution has no journaled execution intent"); return
    end
    local plan, negotiate_error = executor.negotiate(claim)
    if negotiate_error or type(plan) ~= "table" then
        add_issue(pass, due.work, "negotiate", tostring(negotiate_error or "executor returned a malformed plan")); return
    end
    if plan.executor_id ~= claim.executor_id then add_issue(pass, due.work, "negotiate", "executor plan identity changed"); return end
    local prepared, prepare_error = executor.prepare(claim, plan, evidence)
    if prepare_error or type(prepared) ~= "table" or type(prepared.intent) ~= "table" then
        add_issue(pass, due.work, "prepare", tostring(prepare_error or "executor returned a malformed intent")); return
    end
    local intent = prepared.intent
    if not valid_id(intent.execution_ref) then add_issue(pass, due.work, "prepare", "executor returned an invalid execution ref"); return end
    if due.execution and due.execution.execution_ref ~= intent.execution_ref then
        add_issue(pass, due.work, "prepare", "recovery changed the execution identity"); return
    end
    if not due.execution then
        local linked, link_error = journal.link_execution(claim, intent)
        if link_error or linked ~= true then add_issue(pass, due.work, "link_execution", tostring(link_error or "Threads did not confirm execution intent")); return end
    end
    local _, activate_error = executor.activate(claim, prepared)
    if activate_error then add_issue(pass, due.work, "activate", tostring(activate_error)); return end
    if evidence.state == "recoverable" then pass.resumed = pass.resumed + 1 else pass.activated = pass.activated + 1 end
end

function M.create(journal: Journal, registry: Registry, wake: Wake?): (Service?, string?)
    if type(journal) ~= "table" or type(journal.enqueue) ~= "function" or type(journal.scan_due) ~= "function"
        or type(journal.reserve_turn) ~= "function" or type(journal.link_execution) ~= "function" then
        return nil, "Threads journal adapter is incomplete"
    end
    if type(registry) ~= "table" or type(registry.get) ~= "function" then return nil, "executor registry is incomplete" end
    if wake ~= nil and type(wake) ~= "function" then return nil, "wake hint is malformed" end
    local service: Service = {
        send = function(request: SendRequest): (WorkReceipt?, string?)
            local request_error = valid_send(request)
            if request_error then return nil, "INVALID: " .. request_error end
            local receipt, enqueue_error = journal.enqueue(request)
            if enqueue_error or not receipt then return nil, enqueue_error or "Threads did not return a work receipt" end
            if wake then
                local delivered, wake_error = wake()
                if not delivered then return receipt, wake_error or "wake hint was not delivered" end
            end
            return receipt, nil
        end,
        run_pass = function(): (Pass?, string?)
            local page, scan_error = journal.scan_due({limit = M.MAX_SCAN})
            if scan_error or not page then return nil, scan_error or "Threads returned no scan page" end
            local work, page_error = due_items(page)
            if not work then return nil, page_error end
            local pass: Pass = {scanned = #work, reserved = 0, activated = 0, resumed = 0,
                running = 0, quiescent = 0, uncertain = 0, skipped = 0, issues = {}}
            for _, due in ipairs(work) do process_due(journal, registry, pass, due) end
            return pass, nil
        end,
    }
    return service, nil
end

return M
