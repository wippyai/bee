-- MIT. The universal contract owns shared configure decoding and bounds.
local test = require("test")
local bounds = require("bounds")
local universal = require("universal")
local codec_registry = require("codec_registry")
local descriptor = require("descriptor")
local registry = require("registry")
local security = require("security")
local funcs = require("funcs")

local function define_tests()
    test.describe("Universal external driver", function()
        test.it("resolves each streaming codec once per unchanged declaration and rejects replacements", function()
            local ref = "bee.drivers.claude.descriptor:cli"
            local original = assert(registry.get(ref))
            local decode = descriptor.decode
            local decodes = 0
            descriptor.decode = function(raw: unknown): (descriptor.Descriptor?, string?)
                decodes = decodes + 1
                return decode(raw)
            end
            local ok, problem = pcall(function()
                local normalize = universal.normalize(ref)
                local protocol = universal.protocol(ref)
                local state: unknown = nil
                local direct = protocol.new(false)
                for index = 1, 8 do
                    local envelope = {type = "stream_event", event = {type = "content_block_delta", index = 0,
                        delta = {type = "text_delta", text = "x"}}}
                    local reply = assert(bounds.object(normalize({index = index, state = state, envelope = envelope})))
                    test.eq(reply.ok, true)
                    state = reply.state
                    test.not_nil(protocol.normalize(direct, index, envelope))
                    test.eq(protocol.revision(), "stream-json-2")
                end
                test.eq(decodes, 2, "option validation is independent of stream length")
                local changed = assert(registry.get(ref))
                assert(bounds.object(changed.data)).codec = "unknown-codec"
                local changes = registry.snapshot():changes()
                changes:update(changed)
                assert(changes:apply())
                test.is_false((pcall(normalize, {index = 9, eof = true, state = state})))
                test.is_false((pcall(protocol.finish, direct, 9)))
                local restored = registry.snapshot():changes()
                restored:update(original)
                assert(restored:apply())
                test.eq(assert(bounds.object(normalize({index = 9, eof = true, state = state}))).ok, true)
                test.not_nil(protocol.finish(direct, 9))
                test.eq(decodes, 4)
            end)
            descriptor.decode = decode
            local restored = registry.snapshot():changes()
            restored:update(original)
            assert(restored:apply())
            assert(ok, tostring(problem))
        end)
        test.it("rechecks descriptor read permission for a reused normalizer", function()
            local target = "bee.drivers.tests:normalize_probe"
            local input = {index = 1, envelope = {type = "stream_event", event = {type = "content_block_delta", index = 0,
                delta = {type = "text_delta", text = "x"}}}}
            test.eq(assert(bounds.object(funcs.call(target, input))).ok, true)
            local scope = security.new_scope({assert(security.policy("bee.drivers.tests:descriptor_denied"))})
            local result, problem = funcs.new():with_scope(scope):call(target, input)
            test.is_nil(result)
            test.not_nil(problem, "cached codecs still require descriptor read permission")
            test.is_true(tostring(problem):find("CLI descriptor", 1, true) ~= nil, tostring(problem))
            test.eq(assert(bounds.object(funcs.call(target, input))).ok, true)
        end)
        test.it("invalidates codec selection when an overlay changes without a history version", function()
            local owner, ref = "bee.drivers.tests:codec_cache", "bee.drivers.tests:overlay_codec"
            local declaration = assert(registry.get("bee.drivers.claude.descriptor:cli"))
            declaration.id = ref
            local overlay = assert(registry.overlay(owner)):changes()
            overlay:create(declaration)
            assert(overlay:apply())
            local ok, problem = pcall(function()
                local version = assert(registry.snapshot()):version():id()
                local normalize = universal.normalize(ref)
                local protocol = universal.protocol(ref)
                test.eq(assert(bounds.object(normalize({index = 0, eof = true}))).ok, true)
                test.eq(protocol.revision(), "stream-json-2")
                assert(bounds.object(declaration.data)).codec = "unknown-codec"
                local changes = assert(registry.overlay(owner)):changes()
                changes:update(declaration)
                assert(changes:apply())
                test.eq(assert(registry.snapshot()):version():id(), version)
                test.is_false((pcall(normalize, {index = 0, eof = true})))
                test.is_false((pcall(protocol.revision)))
            end)
            local cleanup = assert(registry.overlay(owner)):changes()
            cleanup:delete(ref)
            assert(cleanup:apply())
            assert(ok, tostring(problem))
        end)
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
            local handle = universal.configure("claude", renderers, "bee.drivers.claude.descriptor:cli")
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
            }, "bee.drivers.claude.descriptor:cli")
            test.eq(handle("invalid").ok, false)
            test.eq(handle({configure_renderer = "not a renderer"}).ok, false)
            test.is_false(called)
        end)
        test.it("selects the shared normalizer from the registry descriptor codec", function()
            local protocol = universal.protocol("bee.drivers.opencode.descriptor:cli")
            test.eq(protocol.revision(), "opencode-run-json-1")
            local function legacy_property(raw: unknown, name: string): unknown
                assert(type(raw) == "table")
                return raw[name]
            end
            test.eq(legacy_property(protocol, "PROTOCOL_REVISION"), protocol.revision())
            test.eq(legacy_property(protocol, "MAX_ANSWER_BYTES"), protocol.max_answer_bytes())
            local handle = universal.normalize("bee.drivers.opencode.descriptor:cli")
            local started = handle({index = 0, envelope = {type = "step_start", sessionID = "ses_universal"}})
            local reply = assert(bounds.object(started))
            test.eq(reply.ok, true)
            test.is_true(type(reply.observations) == "table")
            local interrupted = assert(bounds.object(handle({state = reply.state, index = 1, eof = true})))
            local unfinished = assert(bounds.object(interrupted.terminal))
            test.eq(unfinished.outcome, "uncertain")
            test.eq(unfinished.resume_ref, "ses_universal")
            test.is_nil(unfinished.answer)
            test.not_nil(unfinished.error)
            local completed = assert(bounds.object(handle({state = reply.state, index = 1,
                envelope = {type = "step_finish", sessionID = "ses_universal", part = {reason = "stop"}}})))
            test.eq(assert(bounds.object(completed.state)).completed, true)
            local ended = assert(bounds.object(handle({state = completed.state, index = 2, eof = true})))
            local terminal = assert(bounds.object(ended.terminal))
            test.eq(terminal.outcome, "succeeded")
            test.eq(terminal.resume_ref, "ses_universal")
        end)

        test.it("settles Muse failure and cancellation terminal envelopes", function()
            for _, outcome in ipairs({"failed", "cancelled"}) do
                local handle = universal.normalize("bee.drivers.muse.descriptor:cli")
                local accepted = assert(bounds.object(handle({index = 1, envelope = {payload_type = "runtime.command.accepted", stream = {id = "muse-session"}, payload = {}}})))
                local started = assert(bounds.object(handle({state = accepted.state, index = 2, envelope = {payload_type = "run.lifecycle.started", payload = {}}})))
                local ended = assert(bounds.object(handle({state = started.state, index = 3, envelope = {payload_type = "run.terminal." .. outcome,
                    payload = {terminal = outcome, reason = "provider refused"}}})))
                local terminal = assert(bounds.object(ended.terminal))
                test.eq(terminal.outcome, outcome)
                test.eq((assert(bounds.object(terminal.error))).message, "provider refused")
            end
        end)

        test.it("returns decoded common fields with typed descriptor option values", function()
            local api = universal.launch("bee.drivers.claude.descriptor:cli")
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
            local selected = protocol
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
            local selected = assert(descriptor.load("bee.drivers.claude.descriptor:cli"))
            argv, render_error = universal.render_argv(many, {profile_id = "batch", brief = "work"}, selected)
            test.is_nil(argv)
            test.not_nil(render_error)
        end)
    end)
end

return test.run_cases(define_tests)
