local bounds = require("bounds")
local security = require("security")
local funcs = require("funcs")
local channel = require("channel")
local M = {}
function M.hook(point: string, raw: unknown): {[string]: unknown}
    local turn = assert(bounds.object(raw))
    if point == "prompt.submit" and turn.text == "deny prompt" then return {kind = "deny", reason = "fixture refuses this prompt"} end
    local input = bounds.object(turn.input)
    local mode = input and input.mode
    if mode == "held_deny" or mode == "held_change" then return assert(bounds.object(funcs.call("bee.tests.memory:hold_hook", turn))) end
    if mode == "revoke" then return assert(bounds.object(funcs.call("bee.tests.memory:revoke_during_hook", turn))) end
    if mode == "context" then return {kind = "add_context", text = "fixture explicit context"} end
    if mode == "crash" then error("fixture hook crash") end
    if mode == "invalid" then return {kind = "invented"} end
    if mode == "oversized" then return {kind = "add_context", text = string.rep("x", 20000)} end
    if mode == "budget" then assert(channel.new(1)):receive(); return {kind = "deny", reason = "late denial"} end
    if mode == "deny" then return {kind = "deny", reason = "fixture refuses this operation"} end
    if turn.trait_id == "bee.tests.memory:output_hook" then return {kind = "add_context", text = "tool output: " .. tostring(turn.output)} end
    local actor = assert(security.actor())
    assert(actor:meta().definition_id == "bee.tests.memory:app", "hook inherits carrier authority")
    local suffix = turn.trait_id == "bee.tests.memory:hooks_a" and ":a" or ":b"
    if point == "tool.before" then
        if input and type(input.command) == "string" then return {kind = "change", input = {command = input.command .. suffix}} end
        return {kind = "change", input = {text = tostring(input and input.text or "") .. suffix}}
    elseif point == "tool.after" then
        return {kind = "change", output = tostring(turn.output) .. suffix}
    elseif point == "prompt.submit" then
        return {kind = "add_context", text = "fixture context" .. suffix}
    end
    return {kind = "pass"}
end
return M
