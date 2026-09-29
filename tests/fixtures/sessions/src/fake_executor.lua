-- MIT. Deterministic test executor that pulls and accepts a fenced turn before
-- settling; recovery reuses the same execution identity and result address.
local threads = require("threads")
local M = {}
type Claim = {work: string, session: string, claim_ref: string, executor_id: string, epoch: integer}
type Intent = {execution_ref: string, claim_ref: string?, binding_ref: string?, plan_digest: string?}
type ExecutionState = "not_started" | "running" | "recoverable" | "quiescent" | "unknown"
type Evidence = {state: ExecutionState, execution: Intent?, checkpoint: unknown?}
type Plan = {executor_id: string, definition_digest: string?, binding_ref: string?, features: {string}?}
type Prepared = {intent: Intent, checkpoint: unknown?}
type State = {stop_after_accept: boolean?, launches: integer?, resumes: integer?}
type Executor = {
    negotiate: (Claim) -> (Plan?, string?),
    prepare: (Claim, Plan, Evidence) -> (Prepared?, string?),
    activate: (Claim, Prepared) -> (unknown?, string?),
    reconcile: ({claim: Claim, execution: Intent?}) -> (Evidence?, string?),
    set_state: (string, ExecutionState) -> boolean,
    launches: integer,
    resumes: integer,
}

function M.new(owner: threads.Owner, config: State): Executor
    local states: {[string]: ExecutionState} = {}
    local prepared: {[string]: Prepared} = {}
    local interrupted: {[string]: boolean} = {}
    local executor: Executor
    executor = {
        launches = 0,
        resumes = 0,
        negotiate = function(claim: Claim): (Plan?, string?)
            if claim.executor_id ~= "external" then return nil, "UNSUPPORTED" end
            return {executor_id = "external", definition_digest = "sha256:definition", binding_ref = "bee.fake.executor:binding", features = {}}, nil
        end,
        prepare = function(claim: Claim, _plan: Plan, evidence: Evidence): (Prepared?, string?)
            local existing = prepared[claim.claim_ref]
            if existing then return existing, nil end
            if evidence.state == "recoverable" then return nil, "recovery lost the prepared intent" end
            local intent: Intent = {execution_ref = "be:node:workspace:e" .. tostring(claim.epoch), claim_ref = claim.claim_ref,
                binding_ref = "bee.fake.executor:binding", plan_digest = "sha256:plan"}
            local value: Prepared = {intent = intent, checkpoint = nil}
            prepared[claim.claim_ref] = value
            return value, nil
        end,
        activate = function(claim: Claim, value: Prepared): (unknown?, string?)
            local ref = value.intent.execution_ref
            if states[ref] == "running" then return {state = "already_running"}, nil end
            if states[ref] == "recoverable" then executor.resumes = executor.resumes + 1
            else executor.launches = executor.launches + 1 end
            local turn, pull_error = owner.pull_turn(claim)
            if not turn then return nil, pull_error end
            local accepted, accept_error = owner.accept_turn(claim, turn.input_digest, {frontier = "accepted"})
            if not accepted then return nil, accept_error end
            if config.stop_after_accept and not interrupted[ref] then
                interrupted[ref] = true
                states[ref] = "recoverable"
                return {state = "interrupted_after_accept"}, nil
            end
            local input = type(turn.input) == "string" and turn.input or "structured input"
            local settled, settle_error = owner.settle(claim, {outcome = "succeeded", schema = turn.output_schema,
                value = {text = "done: " .. input}, artifacts = {}, usage = {}})
            if not settled then return nil, settle_error end
            states[ref] = "quiescent"
            return {state = "settled", execution_ref = ref}, nil
        end,
        reconcile = function(request: {claim: Claim, execution: Intent?}): (Evidence?, string?)
            if not request.execution then return {state = "not_started", execution = nil, checkpoint = nil}, nil end
            local state: ExecutionState = states[request.execution.execution_ref] or "not_started"
            return {state = state, execution = request.execution, checkpoint = nil}, nil
        end,
        set_state = function(work: string, state: ExecutionState): boolean
            local row = owner.work_state(work)
            if not row or not row.execution then return false end
            states[row.execution.execution_ref] = state
            return true
        end,
    }
    return executor
end

function M.registry(executor_id: string, executor: Executor): {get: (string) -> (Executor?, string?)}
    return {get = function(requested: string): (Executor?, string?)
        if requested ~= executor_id then return nil, "NOT_FOUND" end
        return executor, nil
    end}
end

return M
