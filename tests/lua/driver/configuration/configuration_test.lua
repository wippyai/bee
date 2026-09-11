-- MIT. Provider-independent configuration boundaries, before any file write.
local test = require("test")
local hash = require("hash")
local configuration = require("configuration")
local PROVIDER = "fixture:provider"
local function file(content: string?): {[string]: unknown}
    local body = content or '{"model":"fixture"}\n'
    local digest, err = hash.sha256(body)
    if not digest then error(tostring(err)) end
    return {revision = "fixture.config@1", path = ".fixture-agent/provider.json", content = body, digest = digest, provider_ref = PROVIDER}
end
local function refused(value: unknown, provider: string?)
    local result, err = configuration.decode_reply(value, provider)
    test.is_nil(result)
    test.is_true(err ~= nil)
end
local function define_tests()
    test.describe("Driver configuration boundary", function()
        test.it("accepts a measured third-driver file and an explicit no-provider result", function()
            local result, err = configuration.decode_reply({ok = true, configuration = file(nil)}, PROVIDER)
            if not result then error(tostring(err)) end
            test.eq(result.path, ".fixture-agent/provider.json")
            test.eq(result.provider_ref, PROVIDER)
            local absent, absent_error = configuration.decode_reply({ok = true}, nil)
            test.is_nil(absent)
            test.is_nil(absent_error)
        end)
        test.it("rejects contradictory replies and provider substitution", function()
            refused({ok = true}, PROVIDER)
            refused({ok = true, configuration = file(nil)}, nil)
            refused({ok = true, configuration = file(nil)}, "fixture:other")
            refused({ok = true, error = "ignored", configuration = file(nil)}, PROVIDER)
            refused({ok = false, error = "refused", configuration = file(nil)}, PROVIDER)
            refused({ok = "true", configuration = file(nil)}, PROVIDER)
            refused({ok = true, configuration = file(nil), extra = true}, PROVIDER)
            local extra = file(nil)
            extra.mode = "executable"
            refused({ok = true, configuration = extra}, PROVIDER)
        end)
        test.it("rejects paths that escape or alias the private home", function()
            for _, path in ipairs({"", "/etc/config", "../config", "a/../config", "./config", "a//config", "a/", "a\\config", "a\0config", string.rep("x", 513)}) do
                local entry = file(nil)
                entry.path = path
                refused({ok = true, configuration = entry}, PROVIDER)
            end
        end)
        test.it("checks measured content and the exact size boundary", function()
            local changed = file(nil)
            changed.content = "changed"
            refused({ok = true, configuration = changed}, PROVIDER)
            local malformed = file(nil)
            malformed.digest = string.rep("z", 64)
            refused({ok = true, configuration = malformed}, PROVIDER)
            local maximum = file(string.rep("x", configuration.MAX_CONFIGURATION_BYTES))
            local result, err = configuration.decode_reply({ok = true, configuration = maximum}, PROVIDER)
            if not result then error(tostring(err)) end
            test.eq(#result.content, configuration.MAX_CONFIGURATION_BYTES)
            refused({ok = true, configuration = file(string.rep("x", configuration.MAX_CONFIGURATION_BYTES + 1))}, PROVIDER)
            refused({ok = true, configuration = file("")}, PROVIDER)
        end)
        test.it("requires paired provider inputs and rejects extra request authority", function()
            local result, err = configuration.decode_request({fixture = false})
            if not result then error(tostring(err)) end
            test.is_false(result.fixture)
            local cases: {unknown} = {
                {fixture = false, provider_ref = PROVIDER},
                {fixture = false, provider = {}},
                {fixture = "false"},
                {fixture = false, scope = "admin"},
                {fixture = false, gateway_section = ""},
                {fixture = false, gateway_section = string.rep("x", configuration.MAX_GATEWAY_SECTION_BYTES + 1)},
            }
            for _, value in ipairs(cases) do
                local decoded, decode_error = configuration.decode_request(value)
                test.is_nil(decoded)
                test.is_true(decode_error ~= nil)
            end
        end)
    end)
end
return test.run_cases(define_tests)
