-- MIT. Locate keeps executable and login evidence separate from driver policy.
local test = require("test")
local locate = require("locate")
local claude = require("claude")
local codex = require("codex")
local opencode = require("opencode")
local agy = require("agy")
local grok = require("grok")
local muse = require("muse")

local function probe(login_exists: boolean?): {[string]: unknown}
    return {profile_id = "window", configured = true,
        executable = {present = true, version = "1.2.3"},
        login_file_exists = login_exists,
        platform = {os = "linux", arch = "x86_64", compatible = true},
        checked_at = "2026-09-29T12:00:00Z"}
end

local function define_tests()
    test.describe("Driver locate", function()
        test.it("decodes all readiness states and retains safe evidence", function()
            local cases = {
                {input = probe(true), status = "ready"},
                {input = {profile_id = "window", configured = false, platform = {os = "linux", arch = "x86_64", compatible = true}}, status = "unconfigured"},
                {input = {profile_id = "window", configured = true, executable = {present = false}, platform = {os = "linux", arch = "x86_64", compatible = true}}, status = "missing"},
                {input = {profile_id = "window", configured = true, executable = {present = true, version = "1.2.3"}, login_file_exists = true, platform = {os = "windows", arch = "x86_64", compatible = false}}, status = "incompatible"},
                {input = probe(nil), status = "unknown"},
            }
            for _, case in ipairs(cases) do
                local result, err = locate.evaluate({provider = "fixture", executable = "fixture-cli", login_path = ".fixture/auth.json"}, case.input)
                if not result then error(tostring(err)) end
                test.eq(result.status, case.status)
            end
            local result = assert(locate.evaluate({provider = "fixture", executable = "fixture-cli", login_path = ".fixture/auth.json"}, probe(true)))
            test.eq(result.executable.present, true)
            test.eq(result.executable.version, "1.2.3")
            test.eq(result.login.evidence, "file_exists")
            test.eq(result.login.path, ".fixture/auth.json")
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

        test.it("uses spike executable names and existence-only login paths for every CLI", function()
            local cases = {
                {driver = claude, provider = "claude", executable = "claude", path = ".claude/.credentials.json"},
                {driver = codex, provider = "codex", executable = "codex", path = ".codex/auth.json"},
                {driver = opencode, provider = "opencode", executable = "opencode", path = ".local/share/opencode/auth.json"},
                {driver = agy, provider = "agy", executable = "agy", path = ".gemini/antigravity-cli/antigravity-oauth-token"},
                {driver = grok, provider = "grok", executable = "grok", path = ".grok/auth.json"},
                {driver = muse, provider = "muse", executable = "muse", path = ".config/muse/auth.json"},
            }
            for _, case in ipairs(cases) do
                local result, err = case.driver.handle(probe(true))
                if not result then error(tostring(err)) end
                test.eq(result.provider, case.provider)
                test.eq(result.executable.name, case.executable)
                test.eq(result.login.evidence, "file_exists")
                test.eq(result.login.path, case.path)
                test.eq(result.status, "ready")
            end
        end)

        test.it("does not turn provider metadata into a runtime login claim", function()
            for _, driver in ipairs({claude, codex, opencode, agy, grok, muse}) do
                local result = assert(driver.handle(probe(nil)))
                test.eq(result.status, "unknown")
                test.eq(result.login.exists, nil)
            end
        end)

        test.it("refuses malformed and credential-bearing probe data", function()
            local result, err = locate.evaluate({provider = "fixture", executable = "fixture-cli", login_path = ".fixture/auth.json"}, {
                profile_id = "window", configured = true,
                executable = {present = true, version = "1.2.3", token = "must-not-pass"},
                login_file_exists = true, platform = {os = "linux", arch = "x86_64", compatible = true}})
            test.is_nil(result)
            test.not_nil(err)
        end)
    end)
end

return test.run_cases(define_tests)
