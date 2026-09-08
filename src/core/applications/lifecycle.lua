-- Pure lifecycle deadlines. Completion is emitted only after a process EXIT.
type Phase = "starting" | "ready" | "close_requested" | "close_confirming" | "close_unresponsive"
    | "stopping" | "terminating" | "stopped"
type Event = "ready" | "exit" | "stop" | "force_stop" | "tick"
    | "request_close" | "confirm_close" | "accept_close" | "cancel_close"
type State = {phase: Phase, deadline: number, failure: string}
type Effect = "none" | "opened" | "close" | "terminate" | "closed" | "failed"
    | "query_close" | "close_cancelled" | "close_timeout"
local M = {}
function M.accepts_updates(state: State): boolean
    return state.phase == "starting" or state.phase == "ready" or state.phase == "close_requested"
        or state.phase == "close_confirming" or state.phase == "close_unresponsive"
end
function M.start(now: number): State return {phase = "starting", deadline = now + 3, failure = ""} end
function M.reduce(state: State, event: Event, now: number): (State, Effect)
    if state.phase == "stopped" then return state, "none" end
    if event == "exit" then
        local failed = state.phase == "starting" or state.failure ~= ""
        return {phase = "stopped", deadline = 0, failure = failed and (state.failure ~= "" and state.failure or "startup_failed") or ""}, failed and "failed" or "closed"
    end
    if event == "ready" and state.phase == "starting" then
        return {phase = "ready", deadline = 0, failure = ""}, "opened"
    end
    -- Negotiation is opt-in at the broker boundary. No cleanup deadline begins
    -- until the app/user accepts; silence is never permission to terminate.
    if event == "request_close" and state.phase == "ready" then
        return {phase = "close_requested", deadline = now + 2, failure = ""}, "query_close"
    end
    if event == "confirm_close" and state.phase == "close_requested" then
        return {phase = "close_confirming", deadline = 0, failure = ""}, "none"
    end
    if event == "accept_close" and (state.phase == "close_requested" or state.phase == "close_confirming") then
        return {phase = "stopping", deadline = now + 0.25, failure = ""}, "close"
    end
    if event == "cancel_close" and (state.phase == "close_requested" or state.phase == "close_confirming"
        or state.phase == "close_unresponsive") then
        return {phase = "ready", deadline = 0, failure = ""}, "close_cancelled"
    end
    if event == "stop" and (state.phase == "starting" or state.phase == "ready") then
        return {phase = "stopping", deadline = now + 0.25, failure = state.phase == "starting" and "cancelled" or ""}, "close"
    end
    if event == "force_stop" then
        return {phase = "terminating", deadline = now + 1, failure = state.failure}, "terminate"
    end
    if event == "tick" and state.deadline > 0 and now >= state.deadline then
        if state.phase == "close_requested" then
            return {phase = "close_unresponsive", deadline = 0, failure = ""}, "close_timeout"
        elseif state.phase == "starting" then
            return {phase = "terminating", deadline = now + 1, failure = "startup_timeout"}, "terminate"
        elseif state.phase == "stopping" or state.phase == "terminating" then
            return {phase = "terminating", deadline = now + 1, failure = state.failure}, "terminate"
        end
    end
    return state, "none"
end
return M
