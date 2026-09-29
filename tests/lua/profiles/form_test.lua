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
    test.describe("Agent profile form subject", function()
        test.it("opens a saved profile under its own definition and refuses a different one", function()
            local workspace = "profile-form-subject"
            local created, err = form.load(workspace, {definition_ref = "bee.driver.claude:default_window", title = "Claude Code"}, true)
            if not created then error(tostring(err)) end
            test.is_true(form.save(created))
            local saved, saved_error = form.saved(workspace, created.profile_id, 1)
            if not saved then error(tostring(saved_error)) end
            test.eq(saved.definition_ref, "bee.driver.claude:default_window")
            local reopened, reopen_error = form.load(workspace, {title = "Claude Code", saved_profile_id = created.profile_id,
                saved_profile_revision = 1}, false)
            if not reopened then error(tostring(reopen_error)) end
            test.eq(reopened.draft.definition_ref, "bee.driver.claude:default_window")
            local mismatched = form.load(workspace, {definition_ref = "bee.driver.codex:default_window", title = "x",
                saved_profile_id = created.profile_id, saved_profile_revision = 1}, false)
            test.is_nil(mismatched)
            local stale, stale_error = form.saved(workspace, created.profile_id, 2)
            test.is_nil(stale)
            test.eq(stale_error, "Profile changed. Refresh and select it again.")
        end)
    end)
end
return test.run_cases(define_tests)
