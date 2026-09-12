-- MIT. Provider-independent configuration delivery boundaries.
local test = require("test")
local hash = require("hash")
local configuration = require("configuration")
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
local function refused(value: unknown, provider: string?)
    local result, err = configuration.decode_reply(value, provider)
    test.is_nil(result); test.is_true(err ~= nil)
end
local function gateway(action: string): configuration.GatewayInput
    return {endpoint = "127.0.0.1:4312", action_id = action, tools = {"thread_read"}, hooks = {"SessionStart"}, token_environment = "BEE_GATEWAY_TOKEN", hook_token_environment = "BEE_GATEWAY_HOOK_TOKEN"}
end
local function define_tests()
    test.describe("Driver configuration delivery boundary", function()
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
    end)
end
return test.run_cases(define_tests)
