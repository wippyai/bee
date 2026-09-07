-- Pure lifecycle deadlines. Completion is emitted only after a process EXIT.
type Phase = "starting" | "ready" | "stopping" | "terminating" | "stopped"
type State = {phase: Phase, deadline: number, failure: string}
type Effect = "none" | "opened" | "close" | "terminate" | "closed" | "failed"
local M = {}
function M.start(now: number): State return {phase = "starting", deadline = now + 3, failure = ""} end
function M.reduce(state: State, event: string, now: number): (State, Effect)
    if state.phase == "stopped" then return state, "none" end
    if event == "exit" then
        local failed = state.phase == "starting" or state.failure ~= ""
        return {phase = "stopped", deadline = 0, failure = failed and (state.failure ~= "" and state.failure or "startup_failed") or ""}, failed and "failed" or "closed"
    end
    if event == "ready" and state.phase == "starting" then
        return {phase = "ready", deadline = 0, failure = ""}, "opened"
    end
    if event == "stop" and (state.phase == "starting" or state.phase == "ready") then
        return {phase = "stopping", deadline = now + 0.25, failure = state.phase == "starting" and "cancelled" or ""}, "close"
    end
    if event == "force_stop" then
        return {phase = "terminating", deadline = now + 1, failure = state.failure}, "terminate"
    end
    if event == "tick" and state.deadline > 0 and now >= state.deadline then
        if state.phase == "starting" then
            return {phase = "terminating", deadline = now + 1, failure = "startup_timeout"}, "terminate"
        elseif state.phase == "stopping" or state.phase == "terminating" then
            return {phase = "terminating", deadline = now + 1, failure = state.failure}, "terminate"
        end
    end
    return state, "none"
end
return M
