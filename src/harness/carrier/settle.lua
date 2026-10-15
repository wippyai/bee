-- MIT. How a turn settles from what was observed: the driver's terminal
-- envelope decides; process exit alone never does. vocabulary.Exit is observed, the
-- remaining output drained within a bound, and only then is a missing
-- envelope decided. A terminal the driver derived from the end of the
-- stream is such a missing envelope: it decides only after exit and the
-- drain, so output the child wrote before its end is still recorded. Pure.
local vocabulary = require("vocabulary")
local driver_types = require("driver_types")
local M = {}
-- Decides only when the evidence is complete: a terminal envelope, or an
-- exit with the drain finished. Returns nil while more may still arrive.
function M.decide(evidence: vocabulary.Evidence): vocabulary.Settlement?
    local terminal = evidence.terminal
    local exit = evidence.exit
    if terminal and evidence.stream_ended then
        if not exit or not evidence.drained then return nil end
        if exit.stopped then
            return {outcome = "cancelled", answer = terminal.answer, resume_ref = terminal.resume_ref, exit_reconciled = true,
                reason = "process stopped on request before a result envelope"}
        end
        return {outcome = terminal.outcome, answer = terminal.answer, resume_ref = terminal.resume_ref, exit_reconciled = true,
            reason = "the stream ended without a result envelope"}
    end
    if terminal then
        if terminal.outcome == "succeeded" and exit and not exit.uncertain and exit.code ~= 0 and evidence.exit_codes_trustworthy then
            return {outcome = "uncertain", answer = terminal.answer, resume_ref = terminal.resume_ref, exit_reconciled = false,
                reason = "terminal envelope reports success but the trusted exit code is " .. tostring(exit.code)}
        end
        return {outcome = terminal.outcome, answer = terminal.answer, resume_ref = terminal.resume_ref, exit_reconciled = exit ~= nil,
            reason = "terminal envelope"}
    end
    if not exit then return nil end
    if not evidence.drained then return nil end
    if exit.signal and exit.signal > 0 then
        return {outcome = "cancelled", answer = nil, resume_ref = nil, exit_reconciled = true, reason = "process ended by signal " .. tostring(exit.signal) .. " with no terminal envelope"}
    end
    if exit.stopped then
        return {outcome = "cancelled", answer = nil, resume_ref = nil, exit_reconciled = true, reason = "process stopped on request with no terminal envelope"}
    end
    if exit.uncertain then
        return {outcome = "uncertain", answer = nil, resume_ref = nil, exit_reconciled = true, reason = "no exit observed and no terminal envelope; the placement reports the attempt uncertain"}
    end
    return {outcome = "uncertain", answer = nil, resume_ref = nil, exit_reconciled = true, reason = "process exited with no terminal envelope"}
end
return M
