-- MIT. Grok launch tests: decode validation, argument construction,
-- quoting and flag semantics across session, batch, and window profiles.
local test = require("test")
local launch = require("launch")
local prepare = require("prepare")
local dispatch = require("dispatch")

local function define_tests()
    test.describe("Grok launch", function()
        test.it("accepts the carrier's admitted window hooks without extra argv", function()
            local input = {profile_id = "window", brief = "", gateway_tools = {"thread_read"},
                gateway_hooks = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"}}
            local decoded, err = launch.decode(input)
            if not decoded then error(tostring(err)) end
            local spec = launch.specification(decoded)
            test.eq(#spec.argv, 2)
            test.eq(spec.argv[1], "--allow")
            test.is_nil(launch.decode({profile_id = "window", brief = "", gateway_hooks = {"Unknown"}}))
            test.is_nil(launch.decode({profile_id = "batch", brief = "task", gateway_hooks = {"Stop"}}))
            test.is_nil(launch.decode({profile_id = "window", brief = "", gateway_hooks = "Stop"}))
        end)
        test.it("decodes minimal session and batch requests", function()
            local decoded, err = launch.decode({profile_id = "session", brief = "hello grok"})
            if not decoded then error(tostring(err)) end
            test.eq(decoded.profile_id, "session")
            test.eq(decoded.brief, "hello grok")
            test.eq(decoded.permission_mode, "default")
            test.eq(decoded.max_turns, 1)
            test.is_nil(decoded.model)
            test.is_nil(decoded.effort)
            test.is_nil(decoded.resume_ref)
            test.eq(#decoded.gateway_tools, 0)

            local spec = launch.specification(decoded)
            test.eq(spec.executable, "grok")
            test.eq(spec.readiness, "none")
            test.eq(spec.argv[1], "-p")
            test.eq(spec.argv[2], "hello grok")
            test.eq(spec.argv[3], "--output-format")
            test.eq(spec.argv[4], "streaming-json")
            test.eq(spec.argv[5], "--permission-mode")
            test.eq(spec.argv[6], "default")
            test.eq(spec.argv[7], "--max-turns")
            test.eq(spec.argv[8], "1")
        end)

        test.it("uses --single= when brief begins with a dash", function()
            local decoded, err = launch.decode({profile_id = "batch", brief = "--version"})
            if not decoded then error(tostring(err)) end
            local spec = launch.specification(decoded)
            test.eq(spec.argv[1], "--single=--version")
            test.eq(spec.argv[2], "--output-format")
            test.eq(spec.argv[3], "streaming-json")

            local dash_p, err2 = launch.decode({profile_id = "session", brief = "-p something"})
            if not dash_p then error(tostring(err2)) end
            local spec_p = launch.specification(dash_p)
            test.eq(spec_p.argv[1], "--single=-p something")
        end)

        test.it("constructs window launch specifications with positional prompt", function()
            local window_empty, err = launch.decode({profile_id = "window", brief = ""})
            if not window_empty then error(tostring(err)) end
            local spec_empty = launch.specification(window_empty)
            test.eq(spec_empty.readiness, "terminal:attached")
            test.eq(#spec_empty.argv, 0)

            local window_prompt, err2 = launch.decode({
                profile_id = "window",
                brief = "-starts with dash",
                permission_mode = "auto",
            })
            if not window_prompt then error(tostring(err2)) end
            local spec_prompt = launch.specification(window_prompt)
            test.eq(spec_prompt.readiness, "terminal:attached")
            test.eq(spec_prompt.argv[1], "--permission-mode")
            test.eq(spec_prompt.argv[2], "auto")
            test.eq(spec_prompt.argv[3], "--")
            test.eq(spec_prompt.argv[4], "-starts with dash")
        end)

        test.it("applies model, effort, resume_ref, and gateway tools", function()
            local decoded, err = launch.decode({
                profile_id = "session",
                brief = "refactor code",
                model = "grok-4.6",
                effort = "high",
                max_turns = 10,
                resume_ref = "session-1234",
                gateway_tools = {"fs_read", "fs_write"},
            })
            if not decoded then error(tostring(err)) end
            test.eq(decoded.model, "grok-4.6")
            test.eq(decoded.effort, "high")
            test.eq(decoded.max_turns, 10)
            test.eq(decoded.resume_ref, "session-1234")
            test.eq(#decoded.gateway_tools, 2)

            local spec = launch.specification(decoded)
            local line = table.concat(spec.argv, " ")
            test.is_true(line:find("--model grok-4.6", 1, true) ~= nil)
            test.is_true(line:find("--reasoning-effort high", 1, true) ~= nil)
            test.is_true(line:find("--max-turns 10", 1, true) ~= nil)
            test.is_true(line:find("-r session-1234", 1, true) ~= nil)
            test.is_true(line:find('--allow MCPTool(bee__*)', 1, true) ~= nil)

            -- Check reasoning_effort alias
            local alias_decoded = assert(launch.decode({
                profile_id = "session",
                brief = "test alias",
                reasoning_effort = "max",
            }))
            test.eq(alias_decoded.effort, "max")
            local alias_spec = launch.specification(alias_decoded)
            test.is_true(table.concat(alias_spec.argv, " "):find("--reasoning-effort max", 1, true) ~= nil)
        end)

        test.it("rejects invalid options and out-of-bounds parameters", function()
            test.is_nil(launch.decode(nil))
            test.is_nil(launch.decode("not an object"))

            -- invalid profile
            local _, err_prof = launch.decode({profile_id = "other", brief = "hi"})
            test.eq(err_prof, "profile_id is not one Bee admits")

            -- empty brief on non-window
            local _, err_brief = launch.decode({profile_id = "session", brief = ""})
            test.eq(err_brief, "brief must be nonempty bounded text")

            -- max_turns on window
            local _, err_win_turns = launch.decode({profile_id = "window", brief = "", max_turns = 5})
            test.eq(err_win_turns, "max_turns is only supported for structured turns")

            -- max_turns bounds
            local _, err_zero = launch.decode({profile_id = "session", brief = "hi", max_turns = 0})
            test.eq(err_zero, "max_turns must be between 1 and 32")
            local _, err_high = launch.decode({profile_id = "session", brief = "hi", max_turns = 33})
            test.eq(err_high, "max_turns must be between 1 and 32")

            -- invalid permission_mode
            local _, err_perm = launch.decode({profile_id = "session", brief = "hi", permission_mode = "yolo"})
            test.eq(err_perm, "permission_mode is not one Bee admits")

            -- invalid effort
            local _, err_eff = launch.decode({profile_id = "session", brief = "hi", effort = "extreme"})
            test.eq(err_eff, "effort is not one Bee admits")

            -- invalid resume_ref (starts with dash)
            local _, err_dash_res = launch.decode({profile_id = "session", brief = "hi", resume_ref = "--resume"})
            test.eq(err_dash_res, "resume_ref must not be a command-line option")

            -- invalid gateway tool
            local _, err_tool = launch.decode({profile_id = "session", brief = "hi", gateway_tools = {"bad-tool!"}})
            test.eq(err_tool, "gateway_tools names a tool that is not a plain identifier")

            -- unknown field
            local _, err_unk = launch.decode({profile_id = "session", brief = "hi", bogus = 123})
            test.eq(err_unk, "launch request: unknown field bogus")
        end)

        test.it("handles prepare and dispatch methods", function()
            local prep_ok = prepare.handle({profile_id = "session", brief = "prepare test"})
            test.is_true(prep_ok.ok)
            test.not_nil(prep_ok.launch)

            local prep_bad = prepare.handle({profile_id = "invalid", brief = "prepare test"})
            test.is_false(prep_bad.ok)
            test.not_nil(prep_bad.error)

            -- Dispatch requires resume_ref
            local disp_missing = dispatch.handle({profile_id = "session", brief = "dispatch test"})
            test.is_false(disp_missing.ok)
            test.eq(disp_missing.error, "a dispatched turn needs resume_ref")

            local disp_ok = dispatch.handle({profile_id = "session", brief = "dispatch test", resume_ref = "sess-42"})
            test.is_true(disp_ok.ok)
            test.not_nil(disp_ok.launch)
            test.is_true(table.concat(disp_ok.launch.argv, " "):find("-r sess-42", 1, true) ~= nil)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
