-- MIT. Runs the ambient client inside an application handler scope.
local sessions = require("sessions")
local M = {}

local function code(fault: {code: string}?): string return fault and fault.code or "" end

function M.run(input: {scenario: string}): {[string]: unknown}
    if input.scenario == "call" then
        local result, fault = sessions.call({definition = "research:ready", input = "Summarize", operation_key = "probe/call"})
        if not result then return {code = code(fault)} end
        return {tag = result.observation.tag, work = result.work:ref(),
            operation = result.work.receipt and result.work.receipt.operation or ""}
    end
    if input.scenario == "context" then
        local open = sessions.open :: (unknown) -> (unknown, unknown)
        local session, raw_fault = open({definition = "research:worker"})
        local fault = type(raw_fault) == "table" and raw_fault :: {code: string} or nil
        return {code = code(fault), session = session and session:ref() or ""}
    end
    if input.scenario == "keys" then
        local session = assert(sessions.get("bs:n:w:s1"))
        local first = assert(session:send({input = "one", operation_key = "send/one"}))
        local again = assert(session:send({input = "one", operation_key = "send/one"}))
        local labelled = assert(session:send({input = "two", operation_key = "send/two"}))
        local opened = assert(sessions.open({definition = "research:worker", operation_key = "open/one"}))
        local other = assert(sessions.open({definition = "research:worker", operation_key = "open/two"}))
        return {first = first.receipt and first.receipt.operation or "", again = again.receipt and again.receipt.operation or "",
            labelled = labelled.receipt and labelled.receipt.operation or "",
            opened = opened.receipt and opened.receipt.operation or "", other = other.receipt and other.receipt.operation or ""}
    end
    return {code = "UNKNOWN_SCENARIO"}
end

return M
