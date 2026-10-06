-- MIT. Version and help probes are measured once per executable file and
-- arguments, and measured again when the file changes on disk.
local test = require("test")
local sql = require("sql")
local uuid = require("uuid")
local probe_cache = require("probe_cache")

local function counting(output: string?, code: integer?, failure: string?): ({count: integer}, ({string}) -> (string?, integer?, string?, boolean?))
    local calls = {count = 0}
    return calls, function(_: {string}): (string?, integer?, string?, boolean?)
        calls.count = calls.count + 1
        return output, code, failure, false
    end
end

local function define_tests()
    test.describe("Harness probe cache", function()
        test.it("resolves a bare name on the executor's PATH to the executable file", function()
            local identity = assert(probe_cache.resolve("claude"))
            test.is_true(identity.path:sub(-#"/harness/bin/claude") == "/harness/bin/claude", identity.path)
            test.is_true(identity.size > 0)
            test.is_nil(probe_cache.resolve("no-such-cli-anywhere"))
        end)

        test.it("resolves a CLI installed as a link to the file the link names", function()
            local linked = assert(probe_cache.resolve("linked-claude"))
            local target = assert(probe_cache.resolve("claude"))
            test.eq(linked.size, target.size)
            test.eq(linked.mode, target.mode)
        end)
        test.it("resolves a CLI installed as a link by absolute path, as a user-local installer makes it", function()
            local linked = assert(probe_cache.resolve("absolute-claude"))
            local target = assert(probe_cache.resolve("claude"))
            test.eq(linked.size, target.size)
            test.eq(linked.mode, target.mode)
        end)
        test.it("reuses a measurement while the executable is unchanged and measures again after it changes", function()
            local home = "/fixture-home/" .. assert(uuid.v4())
            local calls, capture = counting("Claude Code 2.1.265\n", 0, nil)
            local first, first_code = probe_cache.measure({"claude", "--version"}, home, capture)
            test.eq(first, "Claude Code 2.1.265\n")
            test.eq(first_code, 0)
            local again = probe_cache.measure({"claude", "--version"}, home, capture)
            test.eq(again, first)
            test.eq(calls.count, 1)
            probe_cache.measure({"claude", "--help"}, home, capture)
            test.eq(calls.count, 2)

            local db = assert(sql.get(probe_cache.DB))
            local identity = assert(probe_cache.resolve("claude"))
            local _, update_error = db:execute("UPDATE bee_harness_probe_outputs SET modified = ? WHERE executable_path = ?",
                {identity.modified - 60, identity.path})
            db:release()
            test.is_nil(update_error)
            probe_cache.measure({"claude", "--version"}, home, capture)
            test.eq(calls.count, 3)
            probe_cache.measure({"claude", "--version"}, home, capture)
            test.eq(calls.count, 3)
        end)

        test.it("never stores a probe that failed or an executable it cannot resolve", function()
            local home = "/fixture-home/" .. assert(uuid.v4())
            local failed_calls, failed = counting(nil, nil, "probe timed out")
            probe_cache.measure({"claude", "--version"}, home, failed)
            probe_cache.measure({"claude", "--version"}, home, failed)
            test.eq(failed_calls.count, 2)
            local missing_calls, missing = counting("1.0\n", 0, nil)
            probe_cache.measure({"no-such-cli-anywhere", "--version"}, home, missing)
            probe_cache.measure({"no-such-cli-anywhere", "--version"}, home, missing)
            test.eq(missing_calls.count, 2)
        end)
    end)
end

return test.run_cases(define_tests)
