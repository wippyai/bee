-- MIT. The profile editor is a pure, host-bounded form model.
local test = require("test")
local editor = require("profile_editor")
local protocol = require("protocol")

local function profile(): protocol.Profile
    local value, err = protocol.profile({title = "Original", definition_ref = "bee:codex",
        options = {model = "small", enabled = false}, mcp_tools = {"thread_read"},
        instructions = "Keep changes small."})
    if not value then error(tostring(err)) end
    return value
end

local function allowed(): {[string]: unknown}
    return {options = {model = {"small", "large"}, enabled = {false, true}},
        mcp_tools = {"thread_read", "thread_wait"}, instructions = true}
end

local function profile_without_model(): protocol.Profile
    local value, err = protocol.profile({title = "Original", definition_ref = "bee:codex",
        options = {enabled = false}, mcp_tools = {"thread_read"}, instructions = "Keep changes small."})
    if not value then error(tostring(err)) end
    return value
end

local function draft()
    local value, err = editor.new(profile(), allowed())
    if not value then error(tostring(err)) end
    return value
end

local function define_tests()
    test.describe("Saved profile editor", function()
        test.it("preserves the initial profile, including a false scalar", function()
            local value = draft()
            test.eq(value.title, "Original")
            test.eq(value.definition_ref, "bee:codex")
            test.eq(value.options.model, "small")
            test.is_false(value.options.enabled)
            test.eq(value.mcp_tools[1], "thread_read")
            test.eq(value.instructions, "Keep changes small.")
            local result, err = editor.result(value)
            if not result then error(tostring(err)) end
            test.is_false(result.options.enabled)
        end)

        test.it("edits bounded titles and appends multiline guidance", function()
            local value = draft()
            local changed, err = editor.set_title(value, "Edited")
            if not changed then error(tostring(err)) end
            changed, err = editor.append_guidance(value, "Review each change.\nRun tests.")
            if not changed then error(tostring(err)) end
            test.eq(value.title, "Edited")
            test.eq(value.instructions, "Keep changes small.\n\nReview each change.\nRun tests.")
            changed = editor.set_title(value, string.rep("x", 81))
            test.is_false(changed)
            changed = editor.append_guidance(value, "bad\27value")
            test.is_false(changed)
            changed = editor.append_guidance(value, string.rep("x", 4096))
            test.is_false(changed)
            local result, result_error = editor.result(value)
            if not result then error(tostring(result_error)) end
            test.eq(result.instructions, "Keep changes small.\n\nReview each change.\nRun tests.")
            changed, err = editor.set_guidance(value, "Replacement\nwith two lines.")
            if not changed then error(tostring(err)) end
            test.eq(value.instructions, "Replacement\nwith two lines.")
        end)

        test.it("cycles only through host allowed values, retaining false", function()
            local value = draft()
            local changed, err = editor.cycle_option(value, "model")
            if not changed then error(tostring(err)) end
            test.eq(value.options.model, "large")
            changed, err = editor.cycle_option(value, "model")
            if not changed then error(tostring(err)) end
            test.eq(value.options.model, "small")
            changed, err = editor.cycle_option(value, "enabled")
            if not changed then error(tostring(err)) end
            test.is_true(value.options.enabled)
            changed, err = editor.cycle_option(value, "foreign")
            test.is_false(changed)
            test.not_nil(err)
            local rows, rows_error = editor.options(value)
            if not rows then error(tostring(rows_error)) end
            test.eq(rows[1].name, "enabled")
            test.is_true(rows[1].value == true)
        end)

        test.it("starts an unset allowed option at the selected end", function()
            local value, err = editor.new(profile_without_model(), allowed())
            if not value then error(tostring(err)) end
            local changed, changed_error = editor.cycle_option(value, "model")
            if not changed then error(tostring(changed_error)) end
            test.eq(value.options.model, "small")
        end)

        test.it("toggles a host tool and refuses tool widening", function()
            local value = draft()
            local changed, err = editor.toggle_tool(value, "thread_wait")
            if not changed then error(tostring(err)) end
            test.eq(value.mcp_tools[2], "thread_wait")
            changed, err = editor.toggle_tool(value, "thread_wait")
            if not changed then error(tostring(err)) end
            test.eq(#value.mcp_tools, 1)
            changed, err = editor.toggle_tool(value, "outside")
            test.is_false(changed)
            test.not_nil(err)
            local rows, rows_error = editor.tools(value)
            if not rows then error(tostring(rows_error)) end
            test.eq(rows[1].name, "thread_read")
            test.is_true(rows[1].selected)
            test.eq(rows[2].name, "thread_wait")
            test.is_false(rows[2].selected)
            value.mcp_tools[#value.mcp_tools + 1] = "outside"
            local result = editor.result(value)
            test.is_nil(result)
        end)

        test.it("refuses profile guidance when the host disables it", function()
            local host = allowed()
            host.instructions = false
            local value, err = editor.new(profile(), host)
            test.is_nil(value)
            test.not_nil(err)
        end)

        test.it("names a Codex config profile only where the host offers it", function()
            -- The host does not enable the field: the editor must refuse it.
            local value = draft()
            local changed, err = editor.set_config_profile(value, "ds-flash")
            test.is_false(changed)
            test.not_nil(err)
            -- With the field enabled, a plain name round-trips and an empty
            -- value clears it back to the base configuration.
            local host = allowed()
            host.config_profile = true
            local enabled, open_error = editor.new(profile(), host)
            if not enabled then error(tostring(open_error)) end
            changed, err = editor.set_config_profile(enabled, "ds-flash")
            if not changed then error(tostring(err)) end
            test.eq(enabled.config_profile, "ds-flash")
            local result, result_error = editor.result(enabled)
            if not result then error(tostring(result_error)) end
            test.eq(result.config_profile, "ds-flash")
            changed, err = editor.set_config_profile(enabled, "")
            if not changed then error(tostring(err)) end
            test.is_nil(enabled.config_profile)
            -- A path, a dot, a leading dash, a space and an overlong name are refused.
            for _, name in ipairs({"/etc/passwd", "a.b", "-x", "a b", "a/b", string.rep("x", 65)}) do
                changed = editor.set_config_profile(enabled, name)
                test.is_false(changed)
            end
        end)
    end)
end

return test.run_cases(define_tests)
