-- MIT. Test-only canonical Threads journal owner for scheduler recovery tests.
local M = {}
type Request = {session: string, operation_key: string, executor_id: string, input: unknown,
    input_digest: string, output_schema: string}
type Claim = {work: string, session: string, claim_ref: string, executor_id: string, epoch: integer}
type Intent = {execution_ref: string, claim_ref: string?, binding_ref: string?, plan_digest: string?}
type Receipt = {work: string, session: string, operation: string, sequence: integer, committed_at: string,
    kind: "request", state: "queued", output_schema: string}
type Result = {outcome: "succeeded", schema: string, value: {text: string}, artifacts: {string}, usage: {string}}
type WorkState = {phase: "queued" | "reserved" | "accepted" | "settled", result: Result?, execution: Intent?}
type Turn = {work: string, session: string, input: unknown, input_digest: string, output_schema: string}
type Owner = {
    enqueue: (Request) -> (Receipt?, string?),
    scan_due: ({limit: integer}) -> ({items: {unknown}}?, string?),
    reserve_turn: ({work: string, session: string}) -> (Claim?, string?),
    link_execution: (Claim, Intent) -> (boolean, string?),
    pull_turn: (Claim) -> (Turn?, string?),
    accept_turn: (Claim, string, unknown) -> (boolean?, string?),
    settle: (Claim, Result) -> (boolean?, string?),
    work_state: (string) -> WorkState?,
    count: () -> integer,
}

function M.new(): Owner
    local rows: {[string]: {work: string, session: string, executor_id: string, input: unknown, input_digest: string,
        output_schema: string, sequence: integer, operation_key: string, phase: "queued" | "reserved" | "accepted" | "settled",
        claim: Claim?, execution: Intent?, result: Result?}} = {}
    local order: {string} = {}
    local operations: {[string]: {digest: string, receipt: Receipt}} = {}
    local sequence = 0
    local claims = 0

    local function row_for(work: string): {[string]: unknown}?
        return rows[work] :: {[string]: unknown}?
    end
    local function owns_claim(claim: Claim): ({[string]: unknown}?, string?)
        local row = row_for(claim.work)
        if not row or row.claim == nil then return nil, "NOT_FOUND" end
        local saved = row.claim :: Claim
        if saved.claim_ref ~= claim.claim_ref or saved.epoch ~= claim.epoch then return nil, "STALE" end
        return row, nil
    end

    local owner: Owner = {
        enqueue = function(request: Request): (Receipt?, string?)
            local replay = operations[request.operation_key]
            if replay then
                if replay.digest ~= request.input_digest then return nil, "CONFLICT" end
                return replay.receipt, nil
            end
            sequence = sequence + 1
            local work = "bw:node:workspace:w" .. tostring(sequence)
            local operation = "bo:node:workspace:o" .. tostring(sequence)
            local receipt: Receipt = {work = work, session = request.session, operation = operation, sequence = sequence,
                committed_at = "2026-09-29T00:00:00.000Z", kind = "request", state = "queued", output_schema = request.output_schema}
            rows[work] = {work = work, session = request.session, executor_id = request.executor_id, input = request.input,
                input_digest = request.input_digest, output_schema = request.output_schema, sequence = sequence,
                operation_key = request.operation_key, phase = "queued", claim = nil, execution = nil, result = nil}
            order[#order + 1] = work
            operations[request.operation_key] = {digest = request.input_digest, receipt = receipt}
            return receipt, nil
        end,
        scan_due = function(request: {limit: integer}): ({items: {unknown}}?, string?)
            local items: {unknown} = {}
            local active_sessions: {[string]: boolean} = {}
            for _, work in ipairs(order) do
                local row = rows[work]
                if row.phase ~= "settled" and not active_sessions[row.session] and #items < request.limit then
                    items[#items + 1] = {work = row.work, session = row.session, executor_id = row.executor_id,
                        state = row.phase == "settled" and "queued" or row.phase, claim = row.claim, execution = row.execution}
                    active_sessions[row.session] = true
                end
            end
            return {items = items}, nil
        end,
        reserve_turn = function(request: {work: string, session: string}): (Claim?, string?)
            local row = row_for(request.work)
            if not row or row.session ~= request.session then return nil, "NOT_FOUND" end
            local typed = row :: {[string]: unknown}
            if typed.phase ~= "queued" then
                if typed.claim then return typed.claim :: Claim, nil end
                return nil, nil
            end
            for _, work in ipairs(order) do
                local active = rows[work]
                if work ~= request.work and active.session == request.session and (active.phase == "reserved" or active.phase == "accepted") then
                    return nil, nil
                end
            end
            claims = claims + 1
            local claim: Claim = {work = request.work, session = request.session, claim_ref = "bt:node:workspace:c" .. tostring(claims),
                executor_id = tostring(typed.executor_id), epoch = 1}
            typed.claim = claim
            typed.phase = "reserved"
            return claim, nil
        end,
        link_execution = function(claim: Claim, intent: Intent): (boolean, string?)
            local row, claim_error = owns_claim(claim)
            if not row then return false, claim_error end
            if row.execution then
                local prior = row.execution :: Intent
                if prior.execution_ref ~= intent.execution_ref then return false, "CONFLICT" end
                return true, nil
            end
            row.execution = intent
            return true, nil
        end,
        pull_turn = function(claim: Claim): (Turn?, string?)
            local row, claim_error = owns_claim(claim)
            if not row then return nil, claim_error end
            if row.phase ~= "reserved" and row.phase ~= "accepted" then return nil, "STALE" end
            return {work = tostring(row.work), session = tostring(row.session), input = row.input,
                input_digest = tostring(row.input_digest), output_schema = tostring(row.output_schema)}, nil
        end,
        accept_turn = function(claim: Claim, digest: string, _checkpoint: unknown): (boolean?, string?)
            local row, claim_error = owns_claim(claim)
            if not row then return nil, claim_error end
            if row.input_digest ~= digest then return nil, "CONFLICT" end
            if row.phase == "accepted" then return true, nil end
            if row.phase ~= "reserved" then return nil, "STALE" end
            row.phase = "accepted"
            return true, nil
        end,
        settle = function(claim: Claim, result: Result): (boolean?, string?)
            local row, claim_error = owns_claim(claim)
            if not row then return nil, claim_error end
            if row.phase == "settled" then return true, nil end
            if row.phase ~= "accepted" then return nil, "STALE" end
            row.phase = "settled"
            row.result = result
            return true, nil
        end,
        work_state = function(work: string): WorkState?
            local row = rows[work]
            if not row then return nil end
            return {phase = row.phase, result = row.result, execution = row.execution}
        end,
        count = function(): integer return #order end,
    }
    return owner
end

return M
