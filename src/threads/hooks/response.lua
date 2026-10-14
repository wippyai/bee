local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
function M.render(event: string, raw: unknown, driver: string): Object
    local result = assert(bounds.object(raw))
    if driver == "agy" then
        if event == "PreToolUse" and result.denied == true then return {decision = "deny", reason = result.reason} end
        if event == "PreToolUse" and result.changed == true then return {overwrite = result.input} end
        local context = bounds.text(result.additional_context, 24576)
        if event == "UserPromptSubmit" and context and #context > 0 then return {injectSteps = {{ephemeralMessage = context}}} end
        return {}
    end
    local specific: Object = {hookEventName = event}
    local response: Object = {}
    local context = bounds.text(result.additional_context, 24576)
    if context and #context > 0 then specific.additionalContext = context end
    if result.denied == true then
        if event == "PreToolUse" then
            specific.permissionDecision, specific.permissionDecisionReason = "deny", result.reason
        else response.decision, response.reason = "block", result.reason end
    elseif event == "PreToolUse" and result.changed == true and result.input ~= nil then
        specific.updatedInput = result.input
        if driver == "codex" or driver == "muse" then specific.permissionDecision = "allow" end
    elseif event == "PostToolUse" and #(bounds.array(result.original_refs, 16) or {}) > 0 then
        specific.updatedToolOutput = result.output
    end
    if specific.additionalContext ~= nil or specific.permissionDecision ~= nil
        or specific.updatedInput ~= nil or specific.updatedToolOutput ~= nil then response.hookSpecificOutput = specific end
    return response
end
return M
