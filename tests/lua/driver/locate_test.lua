-- MIT. Locate keeps executable and login evidence separate from driver policy.
local test = require("test")
local locate = require("locate")
local claude = require("claude")
local codex = require("codex")
local opencode = require("opencode")
local agy = require("agy")
local grok = require("grok")
local muse = require("muse")
local descriptor = require("descriptor")
local login_evidence = require("login_evidence")

local function probe(login_exists: boolean?): {[string]: unknown}
    return {profile_id = "window", configured = true,
        executable = {present = true, version = "1.2.3"},
        login_checks = {{present = login_exists}},
        platform = {os = "linux", arch = "x86_64", compatible = true},
        checked_at = "2026-09-29T12:00:00Z"}
end

local function define_tests()
    test.describe("Driver locate", function()
        test.it("decodes all readiness states and retains safe evidence", function()
            local cases = {
                {input = probe(true), status = "ready"},
                {input = probe(false), status = "unconfigured"},
                {input = {profile_id = "window", configured = false, platform = {os = "linux", arch = "x86_64", compatible = true}}, status = "unconfigured"},
                {input = {profile_id = "window", configured = true, executable = {present = false}, platform = {os = "linux", arch = "x86_64", compatible = true}}, status = "missing"},
                {input = {profile_id = "window", configured = true, executable = {present = true, version = "1.2.3"}, login_checks = {{present = true}}, platform = {os = "windows", arch = "x86_64", compatible = false}}, status = "incompatible"},
                {input = probe(nil), status = "unknown"},
            }
            for _, case in ipairs(cases) do
                local result, err = locate.evaluate({provider = "fixture", executable = "fixture-cli", login_evidence = {command = "fixture login", any_of = {{kind = "file_exists", paths = {".fixture/auth.json"}}}}}, case.input)
                if not result then error(tostring(err)) end
                test.eq(result.status, case.status)
            end
            local result = assert(locate.evaluate({provider = "fixture", executable = "fixture-cli", login_evidence = {command = "fixture login", any_of = {{kind = "file_exists", paths = {".fixture/auth.json"}}}}}, probe(true)))
            test.eq(result.executable.present, true)
            test.eq(result.executable.version, "1.2.3")
            test.eq(result.login.evidence, "any_of")
            test.is_nil(result.login.path)
            test.eq(result.platform.os, "linux")
            test.eq(result.platform.arch, "x86_64")
            test.eq(result.checked_at, "2026-09-29T12:00:00Z")
            local decoded, decode_error = locate.decode(result)
            if not decoded then error(tostring(decode_error)) end
            test.eq(decoded.login.exists, true)
            local secret = {}
            for key, value in pairs(result) do secret[key] = value end
            secret.access_token = "must-not-pass"
            decoded, decode_error = locate.decode(secret)
            test.is_nil(decoded)
            test.not_nil(decode_error)
        end)

        test.it("evaluates every declared kind for each installed provider descriptor", function()
            for _, case in ipairs({{driver = claude, provider = "claude"}, {driver = codex, provider = "codex"},
                {driver = opencode, provider = "opencode"}, {driver = agy, provider = "agy"},
                {driver = grok, provider = "grok"}, {driver = muse, provider = "muse"}}) do
                local selected = assert(descriptor.load("bee.driver." .. case.provider .. ".descriptor:cli"))
                for success_index in ipairs(selected.login_evidence.any_of) do
                    local checks: {login_evidence.Check} = {}
                    for index, evidence in ipairs(selected.login_evidence.any_of) do
                        local matched = index == success_index
                        local code: integer? = nil
                        if evidence.kind == "auth_status" then code = matched and evidence.success_exit_code or 1 end
                        checks[index] = {present = matched, exit_code = code}
                    end
                    local input = probe(true)
                    input.login_checks = checks
                    local result = assert(case.driver.handle(input))
                    test.eq(result.provider, case.provider)
                    test.eq(result.executable.name, case.provider)
                    test.eq(result.login.evidence, "any_of")
                    test.eq(result.status, "ready")
                end
                local input = probe(false)
                input.login_checks = login_evidence.probe(selected.login_evidence, {
                    file = function(_path, _variable, _directory) return false end,
                    environment = function(_name) return false end,
                    status = function(_argv, _timeout) return 1 end})
                local missing = assert(case.driver.handle(input))
                test.eq(missing.status, "unconfigured")
            end
        end)

        test.it("requires observed exit codes and preserves uncertainty in any-of evidence", function()
            local input = probe(nil)
            input.login_checks = {{present = false}, {present = false}, {}}
            local result = assert(claude.handle(input))
            test.eq(result.status, "unknown")
            input.login_checks = {{present = false}, {present = false}, {exit_code = 0}}
            test.eq(assert(claude.handle(input)).status, "ready")
            input.login_checks = {{present = false}, {present = true}, {}}
            test.eq(assert(claude.handle(input)).status, "ready")
            input.login_checks = {{present = false}, {present = false}, {present = true, exit_code = 1}}
            local invalid, err = claude.handle(input)
            test.is_nil(invalid)
            test.not_nil(err)
            input.login_checks = {{present = true, token = "must-not-pass"}, {}, {}}
            invalid, err = claude.handle(input)
            test.is_nil(invalid)
            test.not_nil(err)
            input.login_checks = {{present = true}}
            invalid, err = claude.handle(input)
            test.is_nil(invalid)
            test.not_nil(err)
        end)

        test.it("does not turn provider metadata into a runtime login claim", function()
            for _, driver in ipairs({claude, codex, opencode, agy, grok, muse}) do
                local result = assert(driver.handle({profile_id = "window", configured = true, executable = {present = true, version = "1.2.3"},
                    platform = {os = "linux", arch = "x86_64", compatible = true}}))
                test.eq(result.status, "unknown")
                test.eq(result.login.exists, nil)
            end
        end)

        test.it("refuses malformed and credential-bearing probe data", function()
            local result, err = locate.evaluate({provider = "fixture", executable = "fixture-cli", login_evidence = {command = "fixture login", any_of = {{kind = "file_exists", paths = {".fixture/auth.json"}}}}}, {
                profile_id = "window", configured = true,
                executable = {present = true, version = "1.2.3", token = "must-not-pass"},
                login_checks = {{present = true}}, platform = {os = "linux", arch = "x86_64", compatible = true}})
            test.is_nil(result)
            test.not_nil(err)
        end)
    end)
end

return test.run_cases(define_tests)
