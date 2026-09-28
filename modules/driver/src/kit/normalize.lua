-- MIT. Shared driver request boundary for normalizer methods.
local bounds = require("bounds")
local turn_budget = require("turn_budget")
local M = {}

type Step = {observations: {{[string]: unknown}}, terminal: unknown?}
type Protocol<State> = {
    new: (boolean) -> State,
    decode_state: (unknown) -> (State?, string?),
    normalize: (State, integer, {[string]: unknown}, integer?) -> (Step?, string?),
    finish: (State, integer) -> (Step?, string?),
}
type Reply<State> = {ok: boolean, error: string?, state: State?, observations: {{[string]: unknown}}?, terminal: unknown}

function M.handle<State>(raw: unknown, protocol: Protocol<State>): Reply<State>
    local request = bounds.object(raw)
    if not request then return {ok = false, error = "request must be an object"} end
    local unknown = bounds.fields(request, {"state", "index", "envelope", "eof", "resumed", "turn_budget"})
    if unknown then return {ok = false, error = unknown} end
    local index = bounds.count(request.index)
    if not index then return {ok = false, error = "index must be a nonnegative integer"} end
    local resumed = false
    if request.resumed ~= nil then
        if type(request.resumed) ~= "boolean" then return {ok = false, error = "resumed must be a boolean"} end
        resumed = request.resumed
    end
    local budget: integer? = nil
    if request.turn_budget ~= nil then
        local decoded_budget, budget_error = turn_budget.decode(request.turn_budget, "turn_budget")
        if not decoded_budget then return {ok = false, error = budget_error or "turn_budget is invalid"} end
        budget = decoded_budget
    end
    local eof = false
    if request.eof ~= nil then
        if type(request.eof) ~= "boolean" then return {ok = false, error = "eof must be a boolean"} end
        eof = request.eof
    end
    local state: State
    if request.state == nil then
        state = protocol.new(resumed)
    else
        local decoded, state_error = protocol.decode_state(request.state)
        if not decoded then return {ok = false, error = state_error or "state is invalid"} end
        state = decoded
    end
    local step: Step?
    local step_error: string?
    if eof then
        if request.envelope ~= nil then return {ok = false, error = "eof request carries an envelope"} end
        step, step_error = protocol.finish(state, index)
    else
        local envelope = bounds.object(request.envelope)
        if not envelope then return {ok = false, error = "envelope must be an object"} end
        step, step_error = protocol.normalize(state, index, envelope, budget)
    end
    if not step then return {ok = false, error = step_error or "normalizer rejected the request"} end
    local terminal = bounds.object(step.terminal)
    local fault = terminal and bounds.object(terminal.error) or nil
    local code = fault and bounds.id(fault.code) or nil
    if fault and (code == "max_turns" or code == "error_max_turns" or code == "max_steps"
        or code == "max_model_steps" or code == "max_turn_requests") then
        terminal.outcome = "failed"
        terminal.answer = nil
        fault.code = "max_turns"
        fault.message = turn_budget.message(budget)
        fault.retryable = false
    end
    return {ok = true, state = state, observations = step.observations, terminal = step.terminal}
end

function M.bind<State>(new: (boolean) -> State,
    decode_state: (unknown) -> (State?, string?),
    normalize: (State, integer, {[string]: unknown}, integer?) -> (Step?, string?),
    finish: (State, integer) -> (Step?, string?)): (unknown) -> Reply<State>
    local protocol: Protocol<State> = {new = new, decode_state = decode_state, normalize = normalize, finish = finish}
    return function(request: unknown) return M.handle(request, protocol) end
end

return M
