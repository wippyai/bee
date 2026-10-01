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
        local session, session_error = sessions.get("bs:n:w:s1")
        assert(session, tostring(session_error and session_error.message))
        local first, first_error = session:send({input = "one", operation_key = "send/one"})
        assert(first, tostring(first_error and first_error.message))
        local again, again_error = session:send({input = "one", operation_key = "send/one"})
        assert(again, tostring(again_error and again_error.message))
        local labelled, labelled_error = session:send({input = "two", operation_key = "send/two"})
        assert(labelled, tostring(labelled_error and labelled_error.message))
        local opened, opened_error = sessions.open({definition = "research:worker", operation_key = "open/one"})
        assert(opened, tostring(opened_error and opened_error.message))
        local other, other_error = sessions.open({definition = "research:worker", operation_key = "open/two"})
        assert(other, tostring(other_error and other_error.message))
        return {first = first.receipt and first.receipt.operation or "", again = again.receipt and again.receipt.operation or "",
            labelled = labelled.receipt and labelled.receipt.operation or "",
            opened = opened.receipt and opened.receipt.operation or "", other = other.receipt and other.receipt.operation or ""}
    end
    return {code = "UNKNOWN_SCENARIO"}
end

return M
