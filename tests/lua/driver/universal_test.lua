-- MIT. The universal contract owns shared configure decoding and bounds.
local test = require("test")
local universal = require("universal")
local codec_registry = require("codec_registry")

local function define_tests()
    test.describe("Universal external driver", function()
        test.it("decodes configure input once before selecting its CLI renderer", function()
            local called = false
            type Renderer = (configuration.Request) -> {[string]: unknown}
            local renderers: {[string]: Renderer} = {
                claude = function(request: configuration.Request): {[string]: unknown}
                    called = true
                    test.eq(request.fixture, false)
                    return {ok = true, delivery = {arguments = {}, files = {}}}
                end,
                other = function(_request: configuration.Request): {[string]: unknown}
                    error("descriptor-selected renderer was bypassed")
                end,
            }
            local handle = universal.configure("bee.driver.claude.descriptor:cli", renderers)
            local invalid = handle({fixture = "false"})
            test.eq(invalid.ok, false)
            test.is_false(called)
            local valid = handle({fixture = false})
            test.eq(valid.ok, true)
            test.is_true(called)
        end)
        test.it("selects the shared normalizer from the registry descriptor codec", function()
            local protocol = universal.protocol("bee.driver.opencode.descriptor:cli")
            test.eq(protocol.PROTOCOL_REVISION, "opencode-run-json-1")
            local handle = universal.normalize("bee.driver.opencode.descriptor:cli")
            local started = handle({index = 0, envelope = {type = "step_start", sessionID = "ses_universal"}})
            local reply = started :: {[string]: unknown}
            test.eq(reply.ok, true)
            test.is_true(type(reply.observations) == "table")
            local ended = handle({state = reply.state, index = 1, eof = true}) :: {[string]: unknown}
            local terminal = ended.terminal :: {[string]: unknown}
            test.eq(terminal.outcome, "succeeded")
            test.eq(terminal.resume_ref, "ses_universal")
        end)

        test.it("uses descriptor JSON paths to extract protocol fields", function()
            local protocol = codec_registry.resolve("codex-jsonl", {
                resume_id = {"conversation_key"},
                result_text = {"item", "message"},
                errors = {"fault", "detail"},
                usage = {"stats"},
            })
            test.not_nil(protocol)
            local selected = protocol :: codec_registry.Protocol
            local state = selected.new(false)
            selected.normalize(state, 0, {type = "thread.started", conversation_key = "thread_selected"})
            selected.normalize(state, 1, {type = "item.completed", item = {type = "agent_message", message = "selected answer"}})
            local completed = selected.normalize(state, 2, {type = "turn.completed", stats = {input_tokens = 7, output_tokens = 3}})
            test.not_nil(completed.terminal)
            test.eq(completed.terminal and completed.terminal.resume_ref, "thread_selected")
            test.eq(completed.terminal and completed.terminal.answer, "selected answer")
            test.eq(completed.terminal and completed.terminal.usage and completed.terminal.usage.input_tokens, 7)
        end)

        test.it("refuses recursive flag rendering and oversized argv expansion", function()
            local recursive: {[string]: unknown} = {
                flags = {turn_budget = {field = "turn_budget", emit_default = true, argv = {{option = "turn_budget"}}}},
                options = {fields = {turn_budget = {type = "budget"}}},
            }
            local ok, argv, render_error = pcall(universal.render_argv, {{option = "turn_budget"}},
                {profile_id = "batch", brief = "work", turn_budget = 1}, recursive)
            test.is_true(ok)
            test.is_nil(argv)
            test.not_nil(render_error)

            local many: {string} = {}
            for index = 1, 129 do many[index] = "argument" end
            argv, render_error = universal.render_argv(many, {profile_id = "batch", brief = "work"}, {})
            test.is_nil(argv)
            test.not_nil(render_error)
        end)
    end)
end

return test.run_cases(define_tests)
