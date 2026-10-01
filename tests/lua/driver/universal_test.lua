-- MIT. The universal contract owns shared configure decoding and bounds.
local test = require("test")
local universal = require("universal")
local codec_registry = require("codec_registry")
local descriptor = require("descriptor")

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
            local handle = universal.configure("claude", renderers)
            local invalid = handle({configure_renderer = "claude", fixture = "false"})
            test.eq(invalid.ok, false)
            test.is_false(called)
            local valid = handle({configure_renderer = "claude", fixture = false})
            test.eq(valid.ok, true)
            test.is_true(called)
            local unsupported = handle({configure_renderer = "unknown", fixture = false})
            test.eq(unsupported.ok, false)
        end)
        test.it("refuses malformed configuration objects and renderer selectors", function()
            local called = false
            local handle = universal.configure("claude", {
                claude = function(_request: configuration.Request): {[string]: unknown}
                    called = true
                    return {ok = true, delivery = {arguments = {}, files = {}}}
                end,
            })
            test.eq(handle("invalid").ok, false)
            test.eq(handle({configure_renderer = "not a renderer"}).ok, false)
            test.is_false(called)
        end)
        test.it("selects the shared normalizer from the registry descriptor codec", function()
            local protocol = universal.protocol("bee.driver.opencode.descriptor:cli")
            test.eq(protocol.revision(), "opencode-run-json-1")
            local function legacy_property(raw: unknown, name: string): unknown
                assert(type(raw) == "table")
                return raw[name]
            end
            test.eq(legacy_property(protocol, "PROTOCOL_REVISION"), protocol.revision())
            test.eq(legacy_property(protocol, "MAX_ANSWER_BYTES"), protocol.max_answer_bytes())
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

        test.it("settles Muse failure and cancellation terminal envelopes", function()
            for _, outcome in ipairs({"failed", "cancelled"}) do
                local handle = universal.normalize("bee.driver.muse.descriptor:cli")
                local accepted = handle({index = 1, envelope = {payload_type = "runtime.command.accepted", stream = {id = "muse-session"}, payload = {}}}) :: {[string]: unknown}
                local started = handle({state = accepted.state, index = 2, envelope = {payload_type = "run.lifecycle.started", payload = {}}}) :: {[string]: unknown}
                local ended = handle({state = started.state, index = 3, envelope = {payload_type = "run.terminal." .. outcome,
                    payload = {terminal = outcome, reason = "provider refused"}}}) :: {[string]: unknown}
                local terminal = ended.terminal :: {[string]: unknown}
                test.eq(terminal.outcome, outcome)
                test.eq((terminal.error :: {[string]: unknown}).message, "provider refused")
            end
        end)

        test.it("returns decoded common fields with typed descriptor option values", function()
            local api = universal.launch("bee.driver.claude.descriptor:cli")
            local request, decode_error = api.decode({profile_id = "batch", brief = "summarize", permission_mode = "acceptEdits"})
            if not request then error(tostring(decode_error)) end
            test.eq(request.profile_id, "batch")
            test.eq(request.brief, "summarize")
            test.eq(request.permission_mode, "acceptEdits")
            test.is_nil(request.turn_budget)
            test.eq(request.permission_exchange, false)
            local _, removed_budget_error = api.decode({profile_id = "batch", brief = "summarize", turn_budget = 3})
            test.eq(removed_budget_error, "unknown field turn_budget")
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
                flags = {permission = {field = "permission_mode", emit_default = true, argv = {{option = "permission"}}}},
                options = {fields = {permission_mode = {type = "enum", values = {"default"}}}},
            }
            local ok, argv, render_error = pcall(universal.render_argv, {{option = "permission"}},
                {profile_id = "batch", brief = "work", permission_mode = "default"}, recursive)
            test.is_true(ok)
            test.is_nil(argv)
            test.not_nil(render_error)

            local many: {string} = {}
            for index = 1, 129 do many[index] = "argument" end
            local selected = assert(descriptor.load("bee.driver.claude.descriptor:cli"))
            argv, render_error = universal.render_argv(many, {profile_id = "batch", brief = "work"}, selected)
            test.is_nil(argv)
            test.not_nil(render_error)
        end)
    end)
end

return test.run_cases(define_tests)
