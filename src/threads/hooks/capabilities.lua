local M = {}
M.POINTS = {"session.start", "prompt.submit", "tool.before", "tool.after"}
M.EVENTS = {SessionStart = "session.start", UserPromptSubmit = "prompt.submit", PreToolUse = "tool.before", PostToolUse = "tool.after"}
type Capability = {point: string, supported: boolean, allowed_results: {string}, reason: string}
function M.for_driver(driver: string): {Capability}
    local result: {Capability} = {}
    for _, point in ipairs(M.POINTS) do
        local allowed: {string} = {}
        local reason = "The driver has no verified synchronous hook response transport."
        if driver == "wippy" then
            allowed = {"pass", "add_context", "change", "deny"}
            reason = "The host owns model requests, tool execution and result insertion."
        elseif driver == "claude" or driver == "codex" then
            allowed = {"pass", "add_context"}
            reason = "SessionStart additionalContext through the CLI hook response."
            if point == "prompt.submit" then
                allowed = {"pass", "add_context", "deny"}
                reason = "UserPromptSubmit additionalContext and decision=block."
            elseif point == "tool.before" then
                allowed = {"pass", "add_context", "change", "deny"}
                reason = driver == "codex" and "PreToolUse updatedInput changes shell command input only; permissionDecision=deny refuses execution."
                    or "Claude 2.1.296 PreToolUse updatedInput and permissionDecision=deny; CLI input validation, protected tools and host authorization still apply."
            elseif point == "tool.after" then
                if driver == "claude" then
                    allowed = {"pass", "add_context", "change"}
                    reason = "Claude 2.1.296 PostToolUse updatedToolOutput replaces the model's tool result subject to CLI output-shape validation and protected-tool restrictions; an executed call cannot be denied retroactively."
                else
                    reason = "PostToolUse additionalContext; this CLI rejects output replacement and cannot refuse an already executed call."
                end
            end
        elseif driver == "agy" then
            reason = "Agy's installed contract has no synchronous response for this point."
            if point == "prompt.submit" then
                allowed = {"pass", "add_context"}
                reason = "PreInvocation injectSteps.ephemeralMessage adds transient model context."
            elseif point == "tool.before" then
                allowed = {"pass", "change", "deny"}
                reason = "PreToolUse decision=deny blocks execution; overwrite merges top-level arguments. Changes cannot remove existing fields. Host authorization still applies."
            end
        elseif driver == "muse" then
            reason = "Muse 1.4.4 has no verified response semantics for this point."
            if point == "tool.before" then
                allowed = {"pass", "add_context", "change", "deny"}
                reason = "Muse 1.4.4 PreToolUse validates additionalContext, updatedInput with permissionDecision=allow, and denial with permissionDecisionReason; authorization and correction restrictions still apply."
            elseif point == "tool.after" then
                allowed = {"pass", "add_context"}
                reason = "Muse 1.4.4 PostToolUse accepts context and explicitly rejects output replacement; an executed call cannot be denied retroactively."
            end
        elseif driver == "grok" then
            reason = "Grok 1.0.30 ignores SessionStart stdout."
            if point == "prompt.submit" then
                allowed = {"pass", "deny"}
                reason = "UserPromptSubmit decision=block refuses typed prompts; allowing stdout/context is discarded, and auto-wake/subagent prompts are observation-only."
            elseif point == "tool.before" then
                allowed = {"pass", "add_context", "change", "deny"}
                reason = "Grok 1.0.30 command hooks support updatedInput, additionalContext and permissionDecision=deny before normal permission and tool validation."
            elseif point == "tool.after" then
                allowed = {"pass", "add_context", "change"}
                reason = "Grok 1.0.30 command hooks replace model-facing output through updatedToolOutput with native output-shape and protected-tool validation. An executed call cannot be denied retroactively."
            end
        elseif driver == "opencode" then
            reason = "OpenCode observes tool events after execution; its permission transport does not provide these synchronous hook points."
        end
        result[#result + 1] = {point = point, supported = #allowed > 0, allowed_results = allowed, reason = reason}
    end
    return result
end
function M.at(driver: string, point: string): Capability?
    for _, capability in ipairs(M.for_driver(driver)) do
        if capability.point == point then return capability end
    end
    return nil
end
function M.allows(capability: Capability, result: string): boolean
    for _, allowed in ipairs(capability.allowed_results) do if allowed == result then return true end end
    return false
end
return M
