-- MIT. Provider-independent configuration delivery boundaries.
local test = require("test")
local hash = require("hash")
local json = require("json")
local configuration = require("configuration")
local placement_configuration = require("placement_configuration")
local placement_types = require("placement_types")
local claude = require("claude")
local codex = require("codex")
local grok = require("grok")
local agy = require("agy")
local PROVIDER = "fixture:provider"
local function file(content: string?): {[string]: unknown}
    local body = content or '{"model":"fixture"}\n'
    return {revision = "fixture.config@1", path = ".fixture-agent/provider.json", content = body, digest = assert(hash.sha256(body)), provider_ref = PROVIDER}
end
local function delivery(files: {unknown}?, arguments: {unknown}?): {[string]: unknown}
    return {arguments = arguments or {}, files = files or {}}
end
local function measured_digest(value: unknown, target: string): string
    local digest, digest_error = configuration.digest(value, target)
    if not digest then error(tostring(digest_error or "configuration digest failed")) end
    return digest
end
local function refused(value: unknown, provider: string?)
    local result, err = configuration.decode_reply(value, provider)
    test.is_nil(result); test.is_true(err ~= nil)
end
local function gateway(action: string): configuration.GatewayInput
    return {endpoint = "127.0.0.1:4312", action_id = action, tools = {"thread_read"}, hooks = {"SessionStart"}, token_environment = "BEE_GATEWAY_TOKEN", hook_token_environment = "BEE_GATEWAY_HOOK_TOKEN"}
end
local function define_tests()
    test.describe("Driver configuration delivery boundary", function()
        test.it("fills admitted private JSON fields without modifying the recorded template", function()
            local selected: configuration.GatewayInput = {endpoint = "127.0.0.1:4312", action_id = "action-secret", tools = {"thread_read"}, hooks = {}, token_environment = "BEE_GATEWAY_TOKEN"}
            local output, output_error = configuration.decode_reply(agy.handle({fixture = false, gateway = selected}), nil, selected)
            if not output then error(tostring(output_error)) end
            local template = output.files[1]
            local before = template.content
            test.eq(template.revision, "bee.agy-mcp@2")
            test.is_nil(before:find("BEE_GATEWAY_TOKEN", 1, true))
            local secret = 'fixture-"quoted"-token'
            local content, content_error = placement_configuration.render(template, {BEE_GATEWAY_TOKEN = secret},
                {endpoint = selected.endpoint, tools = selected.tools, hooks = {}, destination = selected.token_environment})
            if not content then error(tostring(content_error)) end
            local actual = json.decode(content) :: {mcpServers: {bee: {headers: {Authorization: string}}}}
            test.eq(actual.mcpServers.bee.headers.Authorization, "Bearer " .. secret)
            test.eq(template.content, before)
            test.is_nil(before:find(secret, 1, true))
            test.is_nil(placement_configuration.render(template, {}, {endpoint = selected.endpoint, tools = selected.tools, hooks = {}, destination = selected.token_environment}))
            test.is_nil(placement_configuration.render(template, {BEE_GATEWAY_TOKEN = secret}, nil))
            test.is_nil(placement_configuration.render(template, {BEE_GATEWAY_TOKEN = secret}, {endpoint = selected.endpoint, tools = selected.tools, hooks = {}, destination = "OTHER_TOKEN"}))
        end)
        test.it("rejects secret fields outside the admitted credential selection", function()
            local item = file('{"auth":""}')
            item.secret_fields = {{path = {"auth"}, environment = "UNSELECTED_SECRET", prefix = "Bearer "}}
            item.provider_ref = configuration.GATEWAY_PROVIDER_REF
            test.is_nil(configuration.decode_reply({ok = true, delivery = delivery({item})}, nil, gateway("action-a")))
            item.provider_ref = PROVIDER
            test.is_nil(configuration.decode_reply({ok = true, delivery = delivery({item})}, PROVIDER))
            item.secret_fields = {{path = {}, environment = "BEE_GATEWAY_TOKEN", prefix = "Bearer "}}
            test.is_nil(configuration.decode_file(item))
            item.secret_fields = {{path = {"auth"}, environment = "BEE_GATEWAY_TOKEN", prefix = "Bearer "}, {path = {"auth"}, environment = "BEE_GATEWAY_TOKEN", prefix = "Bearer "}}
            test.is_nil(configuration.decode_file(item))
        end)
        test.it("refuses nonempty secret targets and oversized materialized content without exposing values", function()
            local item = file('{"auth":"existing"}')
            item.provider_ref = configuration.GATEWAY_PROVIDER_REF
            item.secret_fields = {{path = {"auth"}, environment = "BEE_GATEWAY_TOKEN", prefix = "Bearer "}}
            local decoded, decode_error = configuration.decode_file(item)
            if not decoded then error(tostring(decode_error)) end
            local selected: placement_types.Gateway = {endpoint = "127.0.0.1:4312", tools = {"thread_read"}, hooks = {}, destination = "BEE_GATEWAY_TOKEN"}
            local content, err = placement_configuration.render(decoded, {BEE_GATEWAY_TOKEN = "PRIVATE_FIXTURE_TOKEN"}, selected)
            test.is_nil(content); test.eq(err, "configuration secret target must be an empty string")
            item.content = '{"auth":""}'; item.digest = assert(hash.sha256(item.content :: string))
            decoded, decode_error = configuration.decode_file(item)
            if not decoded then error(tostring(decode_error)) end
            content, err = placement_configuration.render(decoded, {BEE_GATEWAY_TOKEN = string.rep("x", 8192)}, selected)
            test.is_nil(content); test.eq(err, "materialized configuration exceeds its encoding bound")
        end)

        test.it("renders observation-only Agy command hooks with quoted host inputs", function()
            local selected: configuration.GatewayInput = {endpoint = "127.0.0.1:4312", action_id = "action-a", tools = {},
                hooks = {"PreToolUse", "PostToolUse", "Stop"}, token_environment = "MCP_TOKEN", hook_token_environment = "HOOK_TOKEN",
                hook_command = "/private/Bee's bin/bee"}
            local reply = agy.handle({fixture = false, gateway = selected})
            local output, err = configuration.decode_reply(reply, nil, selected)
            if not output then error(tostring(err)) end
            test.eq(#output.files, 1)
            test.eq(output.files[1].path, ".gemini/config/hooks.json")
            local raw, decode_error = json.decode(output.files[1].content)
            if decode_error then error(tostring(decode_error)) end
            local doc = raw :: {bee: {PreToolUse: {{matcher: string, hooks: {{type: string, command: string}}}},
                PostToolUse: {{hooks: {{type: string}}}}, Stop: {{type: string, command: string, hooks: unknown}}}}
            test.eq(doc.bee.PreToolUse[1].matcher, "")
            test.eq(doc.bee.PreToolUse[1].hooks[1].type, "command")
            test.eq(doc.bee.PostToolUse[1].hooks[1].type, "command")
            test.eq(doc.bee.Stop[1].type, "command")
            test.is_nil(doc.bee.Stop[1].hooks)
            test.is_true(doc.bee.Stop[1].command:find("hook-post 127.0.0.1:4312 action-a HOOK_TOKEN Stop", 1, true) ~= nil)
            test.is_true(doc.bee.Stop[1].command:find("MCP_TOKEN", 1, true) == nil)
            local original = measured_digest({fixture = false, gateway = selected}, "bee.driver.agy:configure")
            selected.hook_command = "/other/bee"
            test.neq(original, measured_digest({fixture = false, gateway = selected}, "bee.driver.agy:configure"))
            selected.hook_command = nil
            test.eq(agy.handle({fixture = false, gateway = selected}).ok, false)
            selected.hook_command = "/bee"
            selected.hooks = {"SessionStart"}
            test.eq(agy.handle({fixture = false, gateway = selected}).ok, false)
            for _, path in ipairs({"bee", "", "/bad\npath"}) do
                selected.hook_command = path
                test.is_nil(configuration.decode_request({fixture = false, gateway = selected}))
            end
        end)
        test.it("keeps profile instructions separate from turn prompts and measures changes", function()
            local text = 'Review carefully.\nKeep "quoted" text and `literal` $(words).'
            local input = {fixture = false, instructions = text}
            local decoded, err = configuration.decode_request(input)
            if not decoded then error(tostring(err)) end
            test.eq(decoded.instructions, text)
            local original = assert(configuration.digest(input, "fixture:configure"))
            input.instructions = "Different persistent guidance"
            test.neq(original, assert(configuration.digest(input, "fixture:configure")))
            test.is_nil(configuration.decode_request({fixture = false, prompt = "not profile guidance"}))
            for _, invalid in ipairs({"", string.rep("x", 4097), "bad\0text", "bad\27text"}) do
                test.is_nil(configuration.decode_request({fixture = false, instructions = invalid}))
            end
            local claude_reply = claude.handle({fixture = false, instructions = text})
            local claude_delivery, claude_error = configuration.decode_reply(claude_reply, nil)
            if not claude_delivery then error(tostring(claude_error)) end
            test.eq(claude_delivery.arguments[#claude_delivery.arguments - 1], "--append-system-prompt")
            test.eq(claude_delivery.arguments[#claude_delivery.arguments], text)
            local grok_delivery, grok_error = configuration.decode_reply(grok.handle({fixture = false, instructions = text}), nil)
            if not grok_delivery then error(tostring(grok_error)) end
            test.eq(grok_delivery.arguments[1], "--rules")
            test.eq(grok_delivery.arguments[2], text)
            local agy_reply = agy.handle({fixture = false, instructions = text})
            local agy_delivery, agy_error = configuration.decode_reply(agy_reply, nil, nil, text)
            if not agy_delivery then error(tostring(agy_error)) end
            test.eq(#agy_delivery.arguments, 0)
            test.eq(agy_delivery.files[1].path, ".gemini/GEMINI.md")
            test.eq(agy_delivery.files[1].content, text)
            test.is_nil(configuration.decode_reply(agy_reply, nil))
            test.is_nil(configuration.decode_reply(agy_reply, nil, nil, "different instructions"))
        end)
        test.it("renders Codex instructions and refuses ambiguous provider guidance", function()
            local data = {schema_revision = "bee.codex-provider@1", name = "openai", authentication = "chatgpt"}
            local provider = {kind = "registry.entry", meta = {type = "bee.codex_provider"}, data = data}
            local request = {fixture = false, provider_ref = PROVIDER, provider = provider, instructions = "Review carefully.\nKeep boundaries."}
            local result, err = configuration.decode_reply(codex.handle(request), PROVIDER)
            if not result then error(tostring(err)) end
            test.is_true(result.files[1].content:find('developer_instructions = "Review carefully.\\nKeep boundaries."', 1, true) ~= nil)
            local conflicting = {kind = "registry.entry", meta = {type = "bee.codex_provider"}, data = {schema_revision = "bee.codex-provider@1", name = "openai", authentication = "chatgpt", developer_instructions = "Other guidance"}}
            test.eq(codex.handle({fixture = false, provider_ref = PROVIDER, provider = conflicting, instructions = "Profile guidance"}).ok, false)
        end)
        test.it("accepts measured files and a bounded empty argv literal", function()
            local result, err = configuration.decode_reply({ok = true, delivery = delivery({file(nil)}, {"--setting-sources", ""})}, PROVIDER)
            if not result then error(tostring(err)) end
            test.eq(result.files[1].path, ".fixture-agent/provider.json")
            test.eq(result.arguments[2], "")
            local absent, absent_error = configuration.decode_reply({ok = true, delivery = delivery()}, nil)
            if not absent then error(tostring(absent_error)) end
            test.eq(#absent.files, 0); test.eq(#absent.arguments, 0)
            local gateway_file = file(nil)
            gateway_file.provider_ref = configuration.GATEWAY_PROVIDER_REF
            local gateway_delivery, gateway_error = configuration.decode_reply({ok = true, delivery = delivery({gateway_file})}, nil, gateway("action-a"))
            if not gateway_delivery then error(tostring(gateway_error)) end
            test.eq(gateway_delivery.files[1].provider_ref, configuration.GATEWAY_PROVIDER_REF)
        end)
        test.it("rejects contradictory, unsafe, duplicate, and oversized deliveries", function()
            refused({ok = true, delivery = delivery()}, PROVIDER)
            refused({ok = true, delivery = delivery({file(nil)}), extra = true}, PROVIDER)
            refused({ok = false, error = "refused", delivery = delivery()}, PROVIDER)
            refused({ok = true, delivery = delivery({file(nil)}), error = "ignored"}, PROVIDER)
            refused({ok = true, delivery = delivery({file(nil), file(nil)})}, PROVIDER)
            refused({ok = true, delivery = delivery({}, {true})}, nil)
            refused({ok = true, delivery = delivery({}, {"a\0b"})}, nil)
            refused({ok = true, delivery = delivery({}, {string.rep("x", configuration.MAX_DELIVERY_ARGUMENT_BYTES + 1)})}, nil)
            local sparse_arguments: {[number]: unknown} = {[2] = "late"}
            refused({ok = true, delivery = delivery({}, sparse_arguments)}, nil)
            local mapped_files: {[string]: unknown} = {wrong = file(nil)}
            refused({ok = true, delivery = delivery(mapped_files)}, PROVIDER)
            refused({ok = true, delivery = delivery({file(nil)})}, nil)
            local bad = file(nil); bad.path = "../escape"
            refused({ok = true, delivery = delivery({bad})}, PROVIDER)
            local changed = file(nil); changed.content = "changed"
            refused({ok = true, delivery = delivery({changed})}, PROVIDER)
        end)
        test.it("decodes host-only gateway names and fingerprints them without the home", function()
            local request = {fixture = false, gateway = gateway("action-a"), home_directory = "/private/home"}
            local decoded, decode_error = configuration.decode_request(request)
            if not decoded then error(tostring(decode_error)) end
            test.eq(decoded.gateway and decoded.gateway.token_environment, "BEE_GATEWAY_TOKEN")
            local first = assert(configuration.digest(request, "fixture:configure"))
            request.home_directory = "/other/home"
            test.eq(first, assert(configuration.digest(request, "fixture:configure")))
            request.gateway.action_id = "action-b"
            test.neq(first, assert(configuration.digest(request, "fixture:configure")))
            for _, value in ipairs({
                {fixture = false, provider_ref = PROVIDER}, {fixture = false, provider = {}}, {fixture = "false"},
                {fixture = false, gateway_section = "x"}, {fixture = false, gateway = gateway("a"), home_directory = "relative"},
                {fixture = false, gateway = {endpoint = "example.test:1", action_id = "a", tools = {"x"}, hooks = {}, token_environment = "TOKEN"}},
            }) do test.is_nil(configuration.decode_request(value)) end
        end)
        test.it("decodes instruction_builder and measures its selection in configuration digest", function()
            local valid_builder = {func_id = "bee.driver:fixture_builder_ok", args = {tag = "unit", count = 1}}
            local request = {fixture = false, instruction_builder = valid_builder}
            local decoded, err = configuration.decode_request(request)
            if not decoded then error(tostring(err)) end
            test.is_true(decoded.instruction_builder ~= nil)
            test.eq(decoded.instruction_builder and decoded.instruction_builder.func_id, "bee.driver:fixture_builder_ok")
            test.eq(decoded.instruction_builder and decoded.instruction_builder.args.tag, "unit")

            -- Digest measurement
            local digest1 = measured_digest(request, "bee.driver.claude:configure")
            -- Key ordering in args should produce the same canonical digest
            local reordered = {fixture = false, instruction_builder = {func_id = "bee.driver:fixture_builder_ok", args = {count = 1, tag = "unit"}}}
            local digest_reordered = measured_digest(reordered, "bee.driver.claude:configure")
            test.eq(digest1, digest_reordered)

            -- Changing func_id changes digest
            local diff_func = {fixture = false, instruction_builder = {func_id = "bee.driver:fixture_builder_bad_output", args = {tag = "unit", count = 1}}}
            test.neq(digest1, measured_digest(diff_func, "bee.driver.claude:configure"))

            -- Changing args changes digest
            local diff_args = {fixture = false, instruction_builder = {func_id = "bee.driver:fixture_builder_ok", args = {tag = "different", count = 1}}}
            test.neq(digest1, measured_digest(diff_args, "bee.driver.claude:configure"))

            -- Malformed args / builder validation
            for _, invalid in ipairs({
                "not_an_object",
                {args = {}}, -- missing func_id
                {func_id = "", args = {}}, -- empty func_id
                {func_id = "bad\0func", args = {}}, -- non-identifier func_id
                {func_id = "bee.driver:builder"}, -- missing args
                {func_id = "bee.driver:builder", args = "not_an_object"}, -- non-object args
                {func_id = "bee.driver:builder", args = {large = string.rep("x", 4097)}}, -- oversized args
                {func_id = "bee.driver:builder", args = {}, extra_field = "invalid"}, -- unexpected fields
            }) do
                test.is_nil(configuration.decode_request({fixture = false, instruction_builder = invalid}))
            end
        end)
        test.it("accepts an empty memory result without adding or replacing guidance", function()
            local builder = {func_id = "bee.driver:fixture_builder_empty", args = {}}
            local empty, empty_error = configuration.call("bee.driver.agy:configure", {fixture = false, instruction_builder = builder})
            if not empty then error(tostring(empty_error)) end
            test.eq(#empty.files, 0)
            test.eq(#empty.arguments, 0)
            local retained, retained_error = configuration.call("bee.driver.claude:configure", {
                fixture = false, instructions = "Persistent guidance.", instruction_builder = builder,
            })
            if not retained then error(tostring(retained_error)) end
            test.eq(retained.arguments[#retained.arguments - 1], "--append-system-prompt")
            test.eq(retained.arguments[#retained.arguments], "Persistent guidance.")
        end)
        test.it("evaluates builder in configuration.call, appends with blank line, and enforces bounds", function()
            local static_text = "Static profile guidance."
            local builder_target = "bee.driver:fixture_builder_ok"
            local request = {
                fixture = false,
                instructions = static_text,
                instruction_builder = {func_id = builder_target, args = {tag = "custom_test"}},
            }

            -- Static + Dynamic append for Claude
            local claude_delivery, claude_err = configuration.call("bee.driver.claude:configure", request)
            if not claude_delivery then error(tostring(claude_err)) end
            local expected_combined = "Static profile guidance.\n\nDynamic memory rules from custom_test"
            test.eq(claude_delivery.arguments[#claude_delivery.arguments - 1], "--append-system-prompt")
            test.eq(claude_delivery.arguments[#claude_delivery.arguments], expected_combined)

            -- Static + Dynamic append for Agy
            local agy_delivery, agy_err = configuration.call("bee.driver.agy:configure", request)
            if not agy_delivery then error(tostring(agy_err)) end
            test.eq(#agy_delivery.arguments, 0)
            test.eq(agy_delivery.files[1].path, ".gemini/GEMINI.md")
            test.eq(agy_delivery.files[1].content, expected_combined)

            -- Dynamic only (no static instructions)
            local dynamic_only_request = {
                fixture = false,
                instruction_builder = {func_id = builder_target, args = {tag = "standalone"}},
            }
            local dyn_delivery, dyn_err = configuration.call("bee.driver.agy:configure", dynamic_only_request)
            if not dyn_delivery then error(tostring(dyn_err)) end
            test.eq(dyn_delivery.files[1].content, "Dynamic memory rules from standalone")

            -- Malformed output: non-string
            local bad_output_req = {fixture = false, instruction_builder = {func_id = "bee.driver:fixture_builder_bad_output", args = {}}}
            local res1, err1 = configuration.call("bee.driver.agy:configure", bad_output_req)
            test.is_nil(res1)
            test.is_true(err1 ~= nil and tostring(err1):find("output must be a plain string", 1, true) ~= nil)

            -- Malformed output: control bytes
            local control_req = {fixture = false, instruction_builder = {func_id = "bee.driver:fixture_builder_control_chars", args = {}}}
            local res2, err2 = configuration.call("bee.driver.agy:configure", control_req)
            test.is_nil(res2)
            test.is_true(err2 ~= nil and tostring(err2):find("unsupported control bytes", 1, true) ~= nil)

            -- Malformed output: oversized builder output
            local oversized_req = {fixture = false, instruction_builder = {func_id = "bee.driver:fixture_builder_oversized", args = {}}}
            local res3, err3 = configuration.call("bee.driver.agy:configure", oversized_req)
            test.is_nil(res3)
            test.is_true(err3 ~= nil and tostring(err3):find("up to 4096 bytes", 1, true) ~= nil)

            -- Malformed output: combined oversized (static + dynamic > 4096 bytes)
            local large_static = string.rep("A", 3000)
            local combined_oversized_req = {
                fixture = false,
                instructions = large_static,
                instruction_builder = {func_id = builder_target, args = {tag = string.rep("B", 1500)}},
            }
            local res4, err4 = configuration.call("bee.driver.agy:configure", combined_oversized_req)
            test.is_nil(res4)
            test.is_true(err4 ~= nil and tostring(err4):find("combined instructions must be nonempty text up to 4096 bytes", 1, true) ~= nil)

            -- Builder runtime error
            local error_req = {fixture = false, instruction_builder = {func_id = "bee.driver:fixture_builder_error", args = {}}}
            local res5, err5 = configuration.call("bee.driver.agy:configure", error_req)
            test.is_nil(res5)
            test.is_true(err5 ~= nil and tostring(err5):find("intentional builder failure", 1, true) ~= nil)

            -- Nonexistent builder
            local missing_req = {fixture = false, instruction_builder = {func_id = "bee.driver:nonexistent_builder_target", args = {}}}
            local res6, err6 = configuration.call("bee.driver.agy:configure", missing_req)
            test.is_nil(res6)
            test.is_true(err6 ~= nil)
        end)
    end)
end
return test.run_cases(define_tests)
