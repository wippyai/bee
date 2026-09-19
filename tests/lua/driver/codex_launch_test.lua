-- MIT. Codex launch argv: a named config profile is a top-level option that
-- Codex layers on top of the base user configuration. The installed binary
-- accepts `-p/--profile` before `exec` and before its subcommand, rejects a
-- duplicate flag, and lets a later `-c` override win, so Bee's own session
-- arguments still land on top of the named profile.
local test = require("test")
local launch = require("launch")
local quote = require("quote")
local function define_tests()
    test.describe("Codex named config profile launch", function()
        test.it("places --profile before the window argv and declares the required file", function()
            local decoded, err = launch.decode({profile_id = "window", brief = "", sandbox = "workspace-write", config_profile = "ds-flash"})
            if not decoded then error(tostring(err)) end
            local spec = launch.specification(decoded)
            test.eq(quote.line(spec.argv), "--profile ds-flash --sandbox workspace-write")
            test.eq(spec.readiness, "terminal:attached")
            test.eq(#spec.required_files, 1)
            test.eq(spec.required_files[1].variable, "CODEX_HOME")
            test.eq(spec.required_files[1].path, "ds-flash.config.toml")
            test.eq(spec.required_files[1].default_directory, ".codex")
        end)

        test.it("places --profile before exec and before a resume subcommand", function()
            local fresh, fresh_error = launch.decode({profile_id = "batch", brief = "research", sandbox = "read-only", config_profile = "ds-flash"})
            if not fresh then error(tostring(fresh_error)) end
            test.eq(quote.line(launch.specification(fresh).argv),
                "--profile ds-flash exec --json --skip-git-repo-check --sandbox read-only -")
            local resumed, resumed_error = launch.decode({profile_id = "batch", brief = "research", sandbox = "read-only", resume_ref = "session-1", config_profile = "ds-flash"})
            if not resumed then error(tostring(resumed_error)) end
            test.eq(quote.line(launch.specification(resumed).argv),
                "--profile ds-flash --sandbox read-only exec resume session-1 --json --skip-git-repo-check -")
        end)

        test.it("keeps effort and the named profile in one stable order", function()
            local decoded = assert(launch.decode({profile_id = "window", brief = "", sandbox = "read-only", effort = "high", config_profile = "ds-flash"}))
            test.eq(quote.line(launch.specification(decoded).argv),
                "--profile ds-flash --config 'model_reasoning_effort=\"high\"' --sandbox read-only")
        end)

        test.it("carries no required file and no --profile when none is named", function()
            local decoded = assert(launch.decode({profile_id = "window", brief = "", sandbox = "read-only"}))
            local spec = launch.specification(decoded)
            test.eq(quote.line(spec.argv), "--sandbox read-only")
            test.is_nil(spec.required_files)
        end)

        test.it("refuses a profile name that could escape the Codex home", function()
            for _, name in ipairs({"a.b", "a/b", "..", "-x", "a b", "x;rm", "", string.rep("x", 65)}) do
                local decoded, decode_error = launch.decode({profile_id = "window", brief = "", sandbox = "read-only", config_profile = name})
                test.is_nil(decoded)
                test.not_nil(decode_error)
            end
        end)
    end)
end
return test.run_cases(define_tests)
