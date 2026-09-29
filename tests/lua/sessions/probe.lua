-- MIT. Runs the ambient client inside an application handler's context: the
-- acting identity `event:<id>` is the event the fake application context reports.
local sessions = require("sessions")
local M = {}

local function code(fault: {code: string}?): string return fault and fault.code or "" end

function M.run(input: {scenario: string}): {[string]: unknown}
    if input.scenario == "call" then
        local result, fault = sessions.call({definition = "research:ready", input = "Summarize"})
        if not result then return {code = code(fault)} end
        return {tag = result.observation.tag, work = result.work:ref(),
            operation = result.work.receipt and result.work.receipt.operation or ""}
    end
    if input.scenario == "context" then
        local session, fault = sessions.open({definition = "research:worker"})
        return {code = code(fault), session = session and session:ref() or ""}
    end
    if input.scenario == "keys" then
        local session = assert(sessions.get("bs:n:w:s1"))
        local first = assert(session:send({input = "one"}))
        local again = assert(session:send({input = "one"}))
        local different, conflict = session:send({input = "two"})
        local labelled = assert(session:send({input = "two", key = "second"}))
        local opened = assert(sessions.open({definition = "research:worker"}))
        local other = assert(sessions.open({definition = "research:worker", key = "b"}))
        return {first = first.receipt and first.receipt.operation or "", again = again.receipt and again.receipt.operation or "",
            different = different and "sent" or "", conflict = code(conflict),
            labelled = labelled.receipt and labelled.receipt.operation or "",
            opened = opened.receipt and opened.receipt.operation or "", other = other.receipt and other.receipt.operation or ""}
    end
    return {code = "UNKNOWN_SCENARIO"}
end

return M
