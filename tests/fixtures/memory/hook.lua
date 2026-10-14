local bounds = require("bounds")
local security = require("security")
local funcs = require("funcs")
local hash = require("hash")
local channel = require("channel")
local M = {}
function M.hook(point: string, raw: unknown): {[string]: unknown}
    local turn = assert(bounds.object(raw))
    if point == "prompt.submit" and turn.text == "deny prompt" then return {kind = "deny", reason = "fixture refuses this prompt"} end
    local input = bounds.object(turn.input)
    local mode = input and input.mode
    if mode == "held_deny" or mode == "held_change" then return assert(bounds.object(funcs.call("bee.tests.memory:hold_hook", turn))) end
    if mode == "revoke" then return assert(bounds.object(funcs.call("bee.tests.memory:revoke_during_hook", turn))) end
    if mode == "clock_jump_deny" then
        local _, err = funcs.call("bee.tests.memory:advance_hook_clock", 3600000)
        assert(not err, tostring(err))
        return {kind = "deny", reason = "timely denial across clock adjustment"}
    end
    if mode == "context" then return {kind = "add_context", text = "fixture explicit context"} end
    if mode == "crash" then error("fixture hook crash") end
    if mode == "invalid" then return {kind = "invented"} end
    if mode == "oversized" then return {kind = "add_context", text = string.rep("x", 20000)} end
    if mode == "budget" then assert(channel.new(1)):receive(); return {kind = "deny", reason = "late denial"} end
    if mode == "deny" then return {kind = "deny", reason = "fixture refuses this operation"} end
    local actor = assert(security.actor())
    assert(actor:meta().definition_id == "bee.tests.memory:app", "hook inherits carrier authority")
    if turn.trait_id == "bee.tests.memory:remember_hook" and point == "prompt.submit" then
        local workspace = assert(bounds.id(actor:meta().workspace_id))
        local index = "memory:" .. assert(hash.sha256(workspace .. ":bee.tests.memory:app"))
        local raw_reply, err = funcs.call("bee.threads.binding:read_after", {thread_id = index, cursor = 0, limit = 64})
        assert(not err, tostring(err))
        local reply = assert(bounds.object(raw_reply))
        assert(reply.ok == true, "hook memory read failed: " .. tostring(assert(bounds.object(reply.error or {})).message))
        local value = assert(bounds.object(reply.value))
        local facts: {string} = {}
        for _, raw_record in ipairs(assert(bounds.array(value.records, 64))) do
            local record = assert(bounds.object(raw_record))
            local body = bounds.object(record.body)
            local data = body and bounds.object(body.data)
            local text = data and bounds.text(data.text)
            if text then facts[#facts + 1] = text end
        end
        return {kind = "add_context", text = table.concat(facts, "\n")}
    end
    local suffix = turn.trait_id == "bee.tests.memory:hooks_a" and ":a" or ":b"
    if mode == "large_output" then
        if point == "tool.after" then return {kind = "change", output = "digest" .. suffix} end
        return {kind = "pass"}
    end
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
