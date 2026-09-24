-- MIT. The profile editor is a pure, host-bounded form model.
local test = require("test")
local editor = require("profile_editor")
local protocol = require("protocol")

local function profile(): protocol.Profile
    local value, err = protocol.profile({title = "Original", definition_ref = "bee:codex",
        options = {model = "small", enabled = false, note = "initial"}, mcp_tools = {"thread_read"},
        instructions = "Keep changes small."})
    if not value then error(tostring(err)) end
    return value
end

local function allowed(): {[string]: unknown}
    return {options = {model = {"small", "large"}, enabled = {false, true}, note = {kind = "text", max_bytes = 16}},
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
            test.eq(value.options.note, "initial")
            local result, err = editor.result(value)
            if not result then error(tostring(err)) end
            test.is_false(result.options.enabled)
        end)

        test.it("keeps a folder and a thread choice only where the launch allows the override", function()
            local open, open_error = editor.new(profile(), {options = {model = {"small", "large"}, enabled = {false, true}, note = {kind = "text", max_bytes = 16}},
                mcp_tools = {"thread_read", "thread_wait"}, instructions = true, workdir = true, thread = true})
            if not open then error(tostring(open_error)) end
            test.is_true(editor.set_workdir(open, "bee:workspace_root", "legacy/app"))
            test.is_true(editor.set_thread(open, "thread-1"))
            local result, result_error = editor.result(open)
            if not result then error(tostring(result_error)) end
            test.eq(result.workdir and result.workdir.path, "legacy/app")
            test.eq(result.thread and result.thread.thread_id, "thread-1")
            test.is_false(editor.set_workdir(open, "bee:workspace_root", "../escape"))
            test.eq(open.workdir and open.workdir.path, "legacy/app")
            test.is_true(editor.set_workdir(open, nil, nil))
            test.is_nil(open.workdir)
            local closed = draft()
            local refused, refusal = editor.set_workdir(closed, "bee:workspace_root", "legacy")
            test.is_false(refused)
            test.eq(refusal, "this launch does not allow choosing a folder")
            test.is_false(editor.set_thread(closed, "thread-1"))
            -- A saved choice the launch no longer allows is refused, not dropped.
            local saved = protocol.profile({title = "Original", definition_ref = "bee:codex", options = {}, mcp_tools = {},
                instructions = "", workdir = {root_ref = "bee:workspace_root", path = "legacy"}})
            if not saved then error("saved profile with a folder") end
            test.is_nil(editor.new(saved, {options = {}, mcp_tools = {}, instructions = false}))
            test.is_nil(protocol.profile({title = "T", definition_ref = "bee:codex", workdir = {root_ref = "r", path = "/abs"}}))
            test.is_nil(protocol.profile({title = "T", definition_ref = "bee:codex", thread = {thread_id = "t", title = "x"}}))
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
            test.eq(rows[3].name, "note")
            test.eq(rows[3].kind, "text")
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

        test.it("edits bounded text options without applying enum rules", function()
            local value = draft()
            local changed, err = editor.set_text_option(value, "note", "updated")
            if not changed then error(tostring(err)) end
            test.eq(value.options.note, "updated")
            changed = editor.cycle_option(value, "note")
            test.is_false(changed)
            changed = editor.set_text_option(value, "note", "")
            test.is_true(changed)
            test.is_nil(value.options.note)
            changed = editor.set_text_option(value, "note", "bad\27value")
            test.is_false(changed)
            changed = editor.set_text_option(value, "note", "restored")
            test.is_true(changed)
            changed = editor.set_text_option(value, "note", 17)
            test.is_false(changed)
            changed = editor.set_text_option(value, "note", string.rep("x", 17))
            test.is_false(changed)
            local result, result_error = editor.result(value)
            if not result then error(tostring(result_error)) end
            test.eq(result.options.note, "restored")
        end)
    end)
end

return test.run_cases(define_tests)
