-- MIT. The profile editor is a pure, host-bounded form model.
local test = require("test")
local editor = require("profile_editor")
local protocol = require("protocol")

local function profile(): protocol.Profile
    local value, err = protocol.profile({schema_revision = "bee.agent-profile@2", name = "Original", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {model = "small", options = {enabled = false, note = "initial"}, system_prompt_append = "Keep changes small."}, bee = {mcp = {{tool = "thread_read", scope = {}}}}})
    if not value then error(tostring(err)) end
    return value
end

local function allowed(): {[string]: unknown}
    return {options = {model = {"small", "large"}, enabled = {false, true}, note = {kind = "text", max_bytes = 16}},
        mcp_tools = {"thread_read", "thread_wait"}, instructions = true}
end

local function profile_without_model(): protocol.Profile
    local value, err = protocol.profile({schema_revision = "bee.agent-profile@2", name = "Original", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {options = {enabled = false}, system_prompt_append = "Keep changes small."}, bee = {mcp = {{tool = "thread_read", scope = {}}}}})
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
        test.it("requires host authority for machine home and preserves native selection", function()
            local host = allowed()
            host.placements = {"bee.placement.profiles:native"}
            local closed = assert(editor.new(profile(), host))
            test.is_false(editor.cycle_home(closed))
            test.is_nil(closed.placement)
            host.host_home = true
            local admitted = assert(editor.new(profile(), host))
            test.is_true(editor.cycle_home(admitted))
            test.eq(admitted.placement and admitted.placement.kind, "native")
            test.eq(admitted.placement and admitted.placement.home, "machine")
            test.is_true(editor.cycle_home(admitted))
            test.eq(admitted.placement and admitted.placement.home, "private")
            local saved = assert(editor.result(admitted))
            saved.placement = {kind = "native", home = "machine"}
            host.host_home = false
            test.is_nil(editor.new(saved, host))
        end)
        test.it("preserves the initial profile, including a false scalar", function()
            local value = draft()
            test.eq(value.name, "Original")
            test.eq(value.definition_ref, "bee:codex")
            test.eq(value.provider.model, "small")
            test.is_false(value.provider.options.enabled)
            test.eq(value.bee.mcp[1].tool, "thread_read")
            test.eq(value.provider.system_prompt_append, "Keep changes small.")
            test.eq(value.provider.options.note, "initial")
            local result, err = editor.result(value)
            if not result then error(tostring(err)) end
            test.is_false(result.provider.options.enabled)
        end)

        test.it("keeps a folder and a thread choice only where the launch allows the override", function()
            local open, open_error = editor.new(profile(), {options = {model = {"small", "large"}, enabled = {false, true}, note = {kind = "text", max_bytes = 16}},
                mcp_tools = {"thread_read", "thread_wait"}, instructions = true, workdir = true, thread = true})
            if not open then error(tostring(open_error)) end
            test.is_true(editor.set_workdir(open, "bee.env:workspace_root", "legacy/app"))
            test.is_true(editor.set_thread(open, "thread-1"))
            local result, result_error = editor.result(open)
            if not result then error(tostring(result_error)) end
            test.eq(result.workdir and result.workdir.path, "legacy/app")
            test.eq(result.thread and result.thread.thread_id, "thread-1")
            test.is_false(editor.set_workdir(open, "bee.env:workspace_root", "../escape"))
            test.eq(open.workdir and open.workdir.path, "legacy/app")
            test.is_true(editor.set_workdir(open, nil, nil))
            test.is_nil(open.workdir)
            local closed = draft()
            local refused, refusal = editor.set_workdir(closed, "bee.env:workspace_root", "legacy")
            test.is_false(refused)
            test.eq(refusal, "this launch does not allow choosing a folder")
            test.is_false(editor.set_thread(closed, "thread-1"))
            -- A saved choice the launch no longer allows is refused, not dropped.
            local saved = protocol.profile({schema_revision = "bee.agent-profile@2", name = "Original", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {system_prompt_append = ""}, bee = {mcp = {}} , workdir = {root_ref = "bee.env:workspace_root", path = "legacy"}})
            if not saved then error("saved profile with a folder") end
            test.is_nil(editor.new(saved, {options = {}, mcp_tools = {}, instructions = false}))
            test.is_nil(protocol.profile({schema_revision = "bee.agent-profile@2", name = "T", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {}, bee = {mcp = {}} , workdir = {root_ref = "r", path = "/abs"}}))
            test.is_nil(protocol.profile({schema_revision = "bee.agent-profile@2", name = "T", definition_ref = "bee:codex", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {}, bee = {mcp = {}} , thread = {thread_id = "t", title = "x"}}))
        end)

        test.it("edits bounded titles and appends multiline guidance", function()
            local value = draft()
            local changed, err = editor.set_title(value, "Edited")
            if not changed then error(tostring(err)) end
            changed, err = editor.append_guidance(value, "Review each change.\nRun tests.")
            if not changed then error(tostring(err)) end
            test.eq(value.name, "Edited")
            test.eq(value.provider.system_prompt_append, "Keep changes small.\n\nReview each change.\nRun tests.")
            changed = editor.set_title(value, string.rep("x", 81))
            test.is_false(changed)
            changed = editor.append_guidance(value, "bad\27value")
            test.is_false(changed)
            changed = editor.append_guidance(value, string.rep("x", 4096))
            test.is_false(changed)
            local result, result_error = editor.result(value)
            if not result then error(tostring(result_error)) end
            test.eq(result.provider.system_prompt_append, "Keep changes small.\n\nReview each change.\nRun tests.")
            changed, err = editor.set_guidance(value, "Replacement\nwith two lines.")
            if not changed then error(tostring(err)) end
            test.eq(value.provider.system_prompt_append, "Replacement\nwith two lines.")
        end)

        test.it("cycles only through host allowed values, retaining false", function()
            local value = draft()
            local changed, err = editor.cycle_option(value, "model")
            if not changed then error(tostring(err)) end
            test.eq(value.provider.model, "large")
            changed, err = editor.cycle_option(value, "model")
            if not changed then error(tostring(err)) end
            test.eq(value.provider.model, "small")
            changed, err = editor.cycle_option(value, "enabled")
            if not changed then error(tostring(err)) end
            test.is_true(value.provider.options.enabled)
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
            test.eq(value.provider.model, "small")
        end)

        test.it("toggles a host tool and refuses tool widening", function()
            local value = draft()
            local changed, err = editor.toggle_tool(value, "thread_wait")
            if not changed then error(tostring(err)) end
            test.eq(value.bee.mcp[2].tool, "thread_wait")
            changed, err = editor.toggle_tool(value, "thread_wait")
            if not changed then error(tostring(err)) end
            test.eq(#(value.bee.mcp or {}), 1)
            changed, err = editor.toggle_tool(value, "outside")
            test.is_false(changed)
            test.not_nil(err)
            local rows, rows_error = editor.tools(value)
            if not rows then error(tostring(rows_error)) end
            test.eq(rows[1].name, "thread_read")
            test.is_true(rows[1].selected)
            test.eq(rows[2].name, "thread_wait")
            test.is_false(rows[2].selected)
            table.insert(value.bee.mcp or {}, {tool = "outside", scope = {}})
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
            test.eq(value.provider.options.note, "updated")
            changed = editor.cycle_option(value, "note")
            test.is_false(changed)
            changed = editor.set_text_option(value, "note", "")
            test.is_true(changed)
            test.is_nil(value.provider.options.note)
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
            test.eq(result.provider.options.note, "restored")
        end)
    end)
end

return test.run_cases(define_tests)
