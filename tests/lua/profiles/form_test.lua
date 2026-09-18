-- MIT. The form writes through the real profile owner, preserving retry identity.
local test = require("test")
local form = require("form")
local editor = require("editor")
local funcs = require("funcs")
local bounds = require("bounds")
local M = {}
local function read(workspace: string, id: string): {[string]: unknown}
    local raw, err = funcs.call("bee.harness.profiles:call", {operation = "get", workspace_id = workspace, profile_id = id})
    if err then error(tostring(err)) end
    local reply = bounds.object(raw)
    if not reply or reply.ok ~= true then error("read profile failed") end
    local value = bounds.object(reply.value)
    if not value then error("read profile returned no value") end
    return value
end
local function define_tests()
    test.describe("Agent profile form persistence", function()
        test.it("creates a profile and retries the original submission despite later draft edits", function()
            local workspace = "profile-form-workspace"
            local opened, err = form.load(workspace, {definition_ref = "bee.driver.claude:default_window",
                title = "Claude Code", launch_id = "claude-window", plan_digest = ""}, true)
            if not opened then error(tostring(err)) end
            test.is_true(editor.set_title(opened.draft, "My Claude"))
            test.is_true(form.save(opened))
            test.is_true(editor.set_title(opened.draft, "Later draft"))
            test.is_true(form.save(opened))
            local saved = read(workspace, opened.profile_id)
            test.eq(saved.revision, 1)
            local profile = bounds.object(saved.profile)
            if not profile then error("profile missing") end
            test.eq(profile.title, "My Claude")
            test.is_false(form.remove(opened))
            local editing, edit_error = form.load(workspace, {definition_ref = opened.draft.definition_ref,
                title = "My Claude", launch_id = "claude-window", plan_digest = "",
                saved_profile_id = opened.profile_id, saved_profile_revision = 1}, false)
            if not editing then error(tostring(edit_error)) end
            test.eq(editing.draft.title, "My Claude")
            test.is_true(form.remove(editing))
            test.is_true(form.remove(editing))
            test.eq(read(workspace, opened.profile_id).tombstone, true)
            test.is_false(form.save(editing))
            test.is_nil(form.load(workspace, {definition_ref = opened.draft.definition_ref,
                title = "My Claude", launch_id = "claude-window", plan_digest = "",
                saved_profile_id = opened.profile_id, saved_profile_revision = 1}, false))
        end)
    end)
end
return test.run_cases(define_tests)
