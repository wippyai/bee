-- MIT. Deterministic turn executor for scheduler recovery tests.
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
type State = {stop_after_first: boolean?}
type Executor = {run_turn: (Object) -> (Object?, string?), launches: integer, resumes: integer,
    last_turn: Object?, set_state: (string, "recoverable" | "unknown") -> boolean}

local function object(value: unknown): Object?
    if type(value) ~= "table" then return nil end
    return assert(bounds.object(value))
end

function M.new(config: State): Executor
    local calls: {[string]: integer} = {}
    local states: {[string]: "recoverable" | "unknown" | "settled"} = {}
    local executor: Executor
    executor = {
        launches = 0,
        resumes = 0,
        last_turn = nil,
        run_turn = function(turn: Object): (Object?, string?)
            if turn.driver_options ~= nil then return nil, "turn request includes obsolete driver options" end
            local attempt = type(turn.attempt_id) == "string" and turn.attempt_id or ""
            local prompt = type(turn.prompt) == "string" and turn.prompt or ""
            local sender = type(turn.sender) == "table" and turn.sender or nil
            if attempt == "" or prompt == "" or not sender then return nil, "turn input is incomplete" end
            local admission = object(turn.admission)
            if not admission or admission.attempt_id ~= attempt or admission.session_ref ~= sender.id
                or type(admission.owner_id) ~= "string" or type(admission.thread_id) ~= "string"
                or type(admission.action_id) ~= "string" then return nil, "turn admission route is incomplete" end
            executor.last_turn = turn
            local count = (calls[attempt] or 0) + 1
            calls[attempt] = count
            if count == 1 then executor.launches = executor.launches + 1 else executor.resumes = executor.resumes + 1 end
            if states[attempt] == "unknown" then
                return {state = "uncertain", outcome = "uncertain",
                    evidence = {code = "unknown", message = "execution outcome cannot be proven"}}, nil
            end
            if config.stop_after_first and count == 1 then
                states[attempt] = "recoverable"
                return {state = "pending", outcome = "pending",
                    evidence = {code = "running", message = "execution is still active"}}, nil
            end
            states[attempt] = "settled"
            return {state = "settled", outcome = "succeeded", answer = "done: " .. prompt, usage = {},
                checkpoint = {attempt_id = attempt, resume_ref = "resume-" .. attempt}}, nil
        end,
        set_state = function(attempt: string, state: "recoverable" | "unknown"): boolean
            if calls[attempt] == nil then return false end
            states[attempt] = state
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
