-- MIT. Provider-independent configuration delivery boundaries.
local test = require("test")
local hash = require("hash")
local configuration = require("configuration")
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
