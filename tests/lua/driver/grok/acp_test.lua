-- SPDX-License-Identifier: MIT
local test = require("test")
local normalize = require("normalize")
local prepare = require("prepare")
local configure = require("configure")
local bounds = require("bounds")
local json = require("json")
type Object = {[string]: unknown}
local function run()
    test.describe("Grok ACP permission channel", function()
        test.it("delivers instructions through the native home rules path without print-only flags", function()
            local reply = assert(bounds.object(configure.handle({fixture = true, home_directory = "/private", instructions = "Fixture instruction."})))
            test.eq(reply.ok, true)
            local delivery = assert(bounds.object(reply.delivery))
            test.eq(#assert(bounds.array(delivery.arguments, 16)), 0)
            local found = false
            for _, raw in ipairs(assert(bounds.array(delivery.files, 16))) do
                local file = assert(bounds.object(raw))
                if file.path == ".grok/rules/bee.md" then test.eq(file.content, "Fixture instruction."); found = true end
            end
            test.is_true(found)
        end)
        test.it("handshakes, asks once, returns an answer and requires a terminal response", function()
            local launched = assert(bounds.object(prepare.handle({profile_id = "batch", brief = "Fixture prompt.", permission_exchange = true})))
            test.eq(launched.ok, true)
            local launch = assert(bounds.object(launched.launch))
            test.eq(assert(bounds.array(launch.argv, 64))[1], "agent")
            test.is_nil(launch.stdin_eof)
            test.eq(assert(bounds.object(json.decode(assert(bounds.text(launch.stdin))))).method, "initialize")
            local context: Object = {permission_exchange = true, brief = "Fixture prompt.", options = {model = "grok-4.5"}}
            local first = assert(bounds.object(normalize.handle({index = 1, context = context,
                envelope = {jsonrpc = "2.0", id = "bee:init", result = {protocolVersion = 1, _meta = {currentWorkingDirectory = "/fixture"}}}})))
            test.eq(first.ok, true)
            local create = assert(bounds.object(json.decode(assert(bounds.text(assert(bounds.array(first.writes, 8))[1])))))
            test.eq(create.method, "session/new")
            test.eq(assert(bounds.object(create.params)).cwd, "/fixture")
            test.eq(json.encode(assert(bounds.object(create.params)).mcpServers), "[]")
            local second = assert(bounds.object(normalize.handle({index = 2, state = first.state, context = context,
                envelope = {jsonrpc = "2.0", id = "bee:session", result = {sessionId = "fixture-session"}}})))
            test.eq(second.ok, true)
            local model = assert(bounds.object(json.decode(assert(bounds.text(assert(bounds.array(second.writes, 8))[1])))))
            test.eq(model.method, "session/set_model")
            test.eq(assert(bounds.object(model.params)).modelId, "grok-4.5")
            local ready = assert(bounds.object(normalize.handle({index = 3, state = second.state, context = context,
                envelope = {jsonrpc = "2.0", id = "bee:model", result = {}}})))
            test.eq(ready.ok, true)
            test.eq(assert(bounds.object(json.decode(assert(bounds.text(assert(bounds.array(ready.writes, 8))[1]))))).method, "session/prompt")
            local requested = assert(bounds.object(normalize.handle({index = 3, state = ready.state, context = context,
                envelope = {jsonrpc = "2.0", id = 0, method = "session/request_permission", params = {sessionId = "fixture-session",
                    toolCall = {toolCallId = "fixture-call", title = "Fixture command", rawInput = {command = "rm -f fixture-target"},
                        _meta = {["x.ai/tool"] = {name = "run_terminal_command"}}}, options = {
                        {optionId = "allow-once", kind = "allow_once"}, {optionId = "reject-once", kind = "reject_once"}}}}})))
            test.eq(requested.ok, true)
            local observation = assert(bounds.object(assert(bounds.array(requested.observations, 8))[1]))
            test.eq(assert(bounds.object(observation.data)).event_name, "grok.permission")
            local text = assert(bounds.object(normalize.handle({index = 4, state = requested.state, context = context,
                envelope = {jsonrpc = "2.0", method = "session/update", params = {sessionId = "fixture-session", update = {
                    sessionUpdate = "agent_message_chunk", content = {type = "text", text = "Fixture answer."}}}}})))
            local done = assert(bounds.object(normalize.handle({index = 5, state = text.state, context = context,
                envelope = {jsonrpc = "2.0", id = "bee:prompt", result = {stopReason = "end_turn"}}})))
            test.eq(assert(bounds.object(done.terminal)).answer, "Fixture answer.")
            test.eq(assert(bounds.object(done.terminal)).outcome, "succeeded")
            local unfinished = assert(bounds.object(normalize.handle({index = 5, state = text.state, context = context, eof = true})))
            test.eq(assert(bounds.object(unfinished.terminal)).outcome, "uncertain")
        end)
    end)
end
return test.run_cases(run)
