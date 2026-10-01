local bounds = require("bounds")
-- MIT. Test-only journal with the same fenced reserve/accept/settle boundary
-- used by the production Sessions scheduler.
local M = {}
local scheduler = require("scheduler")
local STAMP = "2026-09-29T00:00:00.000Z"

type Object = {[string]: unknown}
type Phase = "queued" | "reserved" | "accepted" | "settled"
type Row = {work: string, session: string, input: unknown, input_digest: string, output_schema: string,
    sender: {kind: "session" | "principal", id: string}, phase: Phase, revision: integer,
    turn: string?, claim: string?, owner_epoch: integer?, checkpoint: unknown?, context: Object?,
    result: Object?, uncertainty: Object?, budget: Object?}
type Owner = {journal: scheduler.Journal, work_state: (string) -> Object?, turn_for_work: (string) -> string?}

local function object(value: unknown): Object?
    if type(value) ~= "table" then return nil end
    return assert(bounds.object(value))
end

function M.new(): Owner
    local rows: {[string]: Row} = {}
    local order: {string} = {}
    local sequence = 0
    local turn_sequence = 0
    local claim_sequence = 0

    local function by_turn(turn: string): Row?
        for _, work in ipairs(order) do
            local row = rows[work]
            if row.turn == turn then return row end
        end
        return nil
    end

    local function enqueue(request: Object): (scheduler.WorkReceipt?, string?)
        sequence = sequence + 1
        local work = "bw:node:workspace:w" .. tostring(sequence)
        local session = request.session
        if type(session) ~= "string" then return nil, "session is required" end
        local sender_kind: "session" | "principal" = session:sub(1, 3) == "bs:" and "session" or "principal"
        local sender_id = sender_kind == "session" and session or "principal:test"
        local sender = {kind = sender_kind, id = sender_id}
        local output_schema = request.output_schema or "bee:Text@1"
        assert(type(output_schema) == "string")
        local receipt: scheduler.WorkReceipt = {work = work, session = session, operation = "bo:node:workspace:o" .. tostring(sequence),
            committed_at = STAMP, sequence = sequence, kind = "request", state = "queued",
            output_schema = output_schema, sender = sender}
        rows[work] = {work = work, session = session, input = request.input, input_digest = "sha256:input-" .. tostring(sequence),
            output_schema = output_schema, sender = sender, phase = "queued", revision = 1,
            turn = nil, claim = nil, owner_epoch = nil, checkpoint = nil, context = {}, result = nil, uncertainty = nil,
            budget = object(request.budget)}
        order[#order + 1] = work
        return receipt, nil
    end
    local function scan_due(_request: {limit: integer}): (scheduler.Page?, string?)
        local items: {scheduler.Due} = {}
        local seen: {[string]: boolean} = {}
        for _, work in ipairs(order) do
            local row = rows[work]
            local phase = row.phase
            if phase ~= "settled" and not seen[row.session] then
                local state: "queued" | "reserved" | "accepted"
                if phase == "queued" then state = "queued"
                elseif phase == "reserved" then state = "reserved"
                elseif phase == "accepted" then state = "accepted"
                else error("invalid due work phase") end
                local item: scheduler.Due = {work = row.work, session = row.session, state = state,
                    turn = row.turn, claim = row.claim, owner_epoch = row.owner_epoch, uncertainty = row.uncertainty}
                items[#items + 1] = item
                seen[row.session] = true
            end
        end
        return {items = items}, nil
    end
    local function reserve_turn(request: {session: string, operation_key: string}): (scheduler.Reservation?, string?)
        for _, work in ipairs(order) do
            local row = rows[work]
            if row.session == request.session and row.phase == "queued" then
                turn_sequence = turn_sequence + 1
                claim_sequence = claim_sequence + 1
                row.turn = "bt:node:workspace:t" .. tostring(turn_sequence)
                row.claim = "bc:node:workspace:c" .. tostring(claim_sequence)
                row.owner_epoch = 1
                row.phase = "reserved"
                row.revision = 2
                return {work = row.work, session = row.session, turn = row.turn, claim = row.claim,
                    owner_epoch = row.owner_epoch, state = row.phase}, nil
            end
        end
        return {session = request.session, state = "empty"}, nil
    end
    local function recover_turn(request: {turn: string, operation_key: string}): (scheduler.Reservation?, string?)
        local row = by_turn(request.turn)
        if not row or not row.claim or not row.owner_epoch then return nil, "turn not found" end
        claim_sequence = claim_sequence + 1
        row.claim = "bc:node:workspace:c" .. tostring(claim_sequence)
        row.owner_epoch = (row.owner_epoch) + 1
        return {work = row.work, session = row.session, turn = request.turn, claim = row.claim,
            owner_epoch = row.owner_epoch, state = row.phase}, nil
    end
    local function pull_turn(request: {turn: string, claim: string}): (scheduler.Turn?, string?)
        local row = by_turn(request.turn)
        if not row or row.claim ~= request.claim then return nil, "stale claim" end
        local route: Object = {definition = "bee.test:definition", plan_digest = string.rep("a", 64),
            workspace_id = "workspace", owner_id = "principal:test", thread_id = "thread-test",
            session_ref = row.session, action_id = row.session,
            driver_binding_ref = "bee.fake.driver:binding", profile_id = "batch",
            driver_methods = {}, driver_options = {}, placement_methods = {}}
        local phase: "reserved" | "accepted"
        if row.phase == "reserved" then phase = "reserved"
        elseif row.phase == "accepted" then phase = "accepted"
        else error("invalid pulled turn phase") end
        assert(row.owner_epoch)
        local pulled: scheduler.Turn = {work = row.work, session = row.session, turn = request.turn, claim = request.claim,
            owner_epoch = row.owner_epoch, input = row.input, input_digest = row.input_digest,
            output_schema = row.output_schema, sender = row.sender, route = route,
            checkpoint = row.checkpoint, context = row.context, phase = phase, budget = row.budget}
        return pulled, nil
    end
    local function accept_turn(request: Object): (Object?, string?)
        local turn = type(request.turn) == "string" and request.turn or ""
        local claim = type(request.claim) == "string" and request.claim or ""
        local row = by_turn(turn)
        if not row or row.claim ~= claim then return nil, "stale claim" end
        if request.input_digest ~= row.input_digest then return nil, "input digest changed" end
        row.phase = "accepted"
        row.revision = 3
        row.checkpoint = assert(bounds.object(request.checkpoint))
        return {state = "accepted"}, nil
    end
    local function settle(request: Object): (Object?, string?)
        local turn = type(request.turn) == "string" and request.turn or ""
        local claim = type(request.claim) == "string" and request.claim or ""
        local row = by_turn(turn)
        if not row or row.claim ~= claim then return nil, "stale claim" end
        local result = request.result
        if type(result) ~= "table" then return nil, "result is required" end
        row.result = assert(bounds.object(result))
        row.context = object(request.context) or {}
        row.phase = "settled"
        row.revision = 4
        return {state = "settled"}, nil
    end
    local function mark_uncertain(request: Object): (Object?, string?)
        local turn = type(request.turn) == "string" and request.turn or ""
        local row = by_turn(turn)
        if not row then return nil, "turn not found" end
        row.uncertainty = object(request.evidence) or {summary = "turn outcome is uncertain", artifacts = {}}
        return {state = "uncertain"}, nil
    end
    local function describe_session(_request: {session: string}): (Object?, string?)
        return {state = "active", queued = 0, active = 0}, nil
    end
    local function transition_session(_request: Object): (Object?, string?)
        return {state = "active"}, nil
    end

    local owner: Owner = {
        journal = {enqueue = enqueue, scan_due = scan_due, reserve_turn = reserve_turn, recover_turn = recover_turn,
            pull_turn = pull_turn, accept_turn = accept_turn, settle = settle, mark_uncertain = mark_uncertain,
            describe_session = describe_session, transition_session = transition_session},
        work_state = function(work: string): Object?
            local row = rows[work]
            if not row then return nil end
            return {work = row.work, phase = row.phase, revision = row.revision, result = row.result,
                uncertainty = row.uncertainty, sender = row.sender}
        end,
        turn_for_work = function(work: string): string?
            local row = rows[work]
            return row and row.turn or nil
        end,
    }
    return owner
end

return M
