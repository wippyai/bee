-- MIT. Exercise form input, confirmation and bounded hit regions.
local test = require("test")
local view = require("view")
local editor = require("editor")
local appearance = require("appearance")
local caller = require("caller")
type Object = {[string]: unknown}
local function ok(value: unknown): caller.Reply
    return {ok = true, error = nil, value = value, replayed = false}
end
-- The owner calls the folder and thread choosers make, answered in place.
local calls: {string} = {}
local function ask(target: string, request: Object): caller.Reply
    calls[#calls + 1] = target
    if target == "bee.workspace.catalog:roots" then return ok({roots = {{root_ref = "bee.env:workspace_root", access = "write"}}}) end
    if target == "bee.workspace.catalog:folders" then
        local path = tostring(request.path)
        local folders = path == "" and {{name = "legacy"}} or {}
        return ok({root_ref = request.root_ref, path = path, access = "write", folders = folders})
    end
    if target == "bee.threads.service:list" then
        return ok({threads = {{thread_id = "thread-1", title = "Earlier work"}, {thread_id = "bad\27id", title = "x"}}})
    end
    return {ok = false, error = {code = "NOT_FOUND", message = target}, value = nil, replayed = false}
end
local function state(): view.State
    local draft, err = editor.new({schema_revision = "bee.agent-profile@2", name = "Agent", definition_ref = "host:agent", driver_binding_ref = "bee.driver.codex:binding", provider = {system_prompt_append = ""}, bee = {mcp = {{tool = "thread_read", scope = {}}}}}, {options = {}, mcp_tools = {"thread_read"}, instructions = true})
    if not draft then error(tostring(err)) end
    return view.new({workspace_id = "workspace", profile_id = "profile", revision = 1, draft = draft, save_key = "save", remove_key = "remove"}, ask)
end
local function text_state(): view.State
    local draft, err = editor.new({schema_revision = "bee.agent-profile@2", name = "Agent", definition_ref = "host:agent", driver_binding_ref = "bee.driver.codex:binding", provider = {options = {label = "ds-flash"}, system_prompt_append = "Keep changes small."}, bee = {mcp = {{tool = "thread_read", scope = {}}}}},
        {options = {label = {kind = "text", max_bytes = 64}}, mcp_tools = {"thread_read"}, instructions = true})
    if not draft then error(tostring(err)) end
    return view.new({workspace_id = "workspace", profile_id = "agent", revision = 1, draft = draft,
        save_key = "save-agent", remove_key = "remove-agent"}, ask)
end
local function launch_state(workdir: boolean, thread: boolean): view.State
    local draft, err = editor.new({schema_revision = "bee.agent-profile@2", name = "Agent", definition_ref = "host:agent", driver_binding_ref = "bee.driver.codex:binding", provider = {system_prompt_append = ""}, bee = {mcp = {}}}, {options = {}, mcp_tools = {}, instructions = false, workdir = workdir, thread = thread})
    if not draft then error(tostring(err)) end
    return view.new({workspace_id = "workspace", profile_id = "profile", revision = 1, draft = draft, save_key = "save", remove_key = "remove"}, ask)
end
local function key(name: string, rune: string?)
    return {type = "key", action = "press", key = rune or "", key_type = name, ctrl = false, alt = false, shift = false}
end
local function define_tests()
    test.describe("Agent profile form input", function()
        test.it("loads session limits without inventing turn limits", function()
            local s = state()
            s.form.draft.budgets = {session = {tokens = 100}}
            local loaded = view.new(s.form, ask)
            test.eq(loaded.settings["session.tokens"], "100")
            test.eq(loaded.settings["turn.tokens"], "")
            test.eq(view.action(loaded, "save"), "save")
            test.is_nil(loaded.form.draft.budgets and loaded.form.draft.budgets.turn)
        end)
        test.it("edits named budgets and supervision with units and preserves unrelated Docker requests", function()
            local s = state()
            s.form.draft._allowed.placements = {"bee.placement.docker:coding"}
            s.form.draft.placement = {kind = "docker", profile_ref = "bee.placement.docker:coding", overrides = {user = "1000:1000"}}
            s.settings["turn.wall_time_ms"] = "2000"
            s.settings["session.tokens"] = "10000"
            s.settings.quiet_period_ms = "5000"
            s.settings["docker.memory_bytes"] = "33554432"
            view.action(s, "advanced")
            local rendered = table.concat(view.draw(120, 45, appearance.defaults(), s).rows, "\n")
            test.is_true(rendered:find("Time limit (ms)", 1, true) ~= nil)
            test.is_true(rendered:find("Docker memory (bytes)", 1, true) ~= nil)
            test.is_false(rendered:find("JSON", 1, true) ~= nil)
            test.eq(view.action(s, "save"), "save")
            local limits = s.form.draft.budgets
            test.eq(limits and limits.turn and limits.turn.wall_time_ms, 2000)
            test.eq(limits and limits.session and limits.session.tokens, 10000)
            test.is_nil(limits and limits.turn and limits.turn.tokens)
            test.eq(s.form.draft.supervision and s.form.draft.supervision.quiet_period_ms, 5000)
            local placement = s.form.draft.placement
            test.eq(placement and placement.kind == "docker" and placement.overrides and placement.overrides.user, "1000:1000")
            s.settings["turn.wall_time_ms"] = "2.5"
            test.is_nil(view.action(s, "save"))
            test.is_true(s.status:find("whole number", 1, true) ~= nil)
            test.eq(limits and limits.turn and limits.turn.wall_time_ms, 2000)
            s.settings["turn.wall_time_ms"] = ""
            s.settings["session.tokens"] = ""
            test.eq(view.action(s, "save"), "save")
            test.is_nil(s.form.draft.budgets)
        end)
        test.it("requires confirmation before the person revokes Docker access", function()
            local s = state()
            s.form.draft.placement = {kind = "docker", profile_ref = "bee.placement.docker:coding"}
            local revoked = false
            s.ask = function(target: string, request: Object): caller.Reply
                test.eq(target, "bee.placement.docker.binding:prepare_environment")
                test.eq(request.revoke, true)
                test.eq(request.workspace_id, "workspace")
                revoked = true; return ok({address = "revoked"})
            end
            view.action(s, "advanced")
            view.action(s, "revoke_docker")
            test.is_true(s.confirming_revoke == true)
            test.is_false(revoked)
            view.action(s, "cancel")
            test.is_false(s.confirming_revoke == true)
            view.action(s, "revoke_docker")
            local drawn = view.draw(90, 20, appearance.defaults(), s)
            view.input(s, key("enter"), drawn)
            test.is_true(revoked)
            test.is_true(s.status:find("revoked", 1, true) ~= nil)
        end)
        test.it("decodes owner replies only when their exact result shape is consistent", function()
            local success = caller.decode({ok = true, value = false, replayed = false})
            test.not_nil(success)
            test.is_true(success ~= nil and success.ok)

            local refusal = caller.decode({ok = false, value = nil, error = {code = "DENIED", message = "revoked"}})
            test.not_nil(refusal)
            test.is_true(refusal ~= nil and not refusal.ok)
            local retryable = caller.decode({ok = false, value = nil, error = {code = "BUSY", message = "retry later", retryable = true}})
            test.not_nil(retryable)
            test.is_true(retryable ~= nil and not retryable.ok and retryable.error ~= nil and retryable.error.retryable == true)
            test.is_nil(caller.decode({ok = true, value = {}, error = {code = "DENIED", message = "mixed"}}))
            test.is_nil(caller.decode({ok = true, value = nil}))
            test.is_nil(caller.decode({ok = false, value = {}, error = {code = "DENIED", message = "mixed"}}))
            test.is_nil(caller.decode({ok = false, value = nil, error = {code = 4, message = "bad"}}))
            test.is_nil(caller.decode({ok = false, value = nil, error = {code = "DENIED", message = 4}}))
            test.is_nil(caller.decode({ok = false, value = nil,
                error = {code = "DENIED", message = "bad", unexpected = true}}))
            test.is_nil(caller.decode({ok = false, value = nil, error = {code = "BUSY", message = "retry later", retryable = "yes"}}))
            test.is_nil(caller.decode({ok = true, value = {}, replayed = "yes"}))
            test.is_nil(caller.decode({ok = true, value = {}, unexpected = true}))
        end)
        test.it("picks a folder under an admitted root and an existing thread only where the launch allows them", function()
            local s = launch_state(true, true)
            view.action(s, "advanced")
            local drawn = view.draw(60, 16, appearance.defaults(), s)
            test.is_true(table.concat(drawn.rows, "\n"):find("Folder: Definition folder", 1, true) ~= nil)
            test.is_true(table.concat(drawn.rows, "\n"):find("Thread: New thread", 1, true) ~= nil)
            -- Name, then the folder.
            view.input(s, key("tab"), drawn)
            view.input(s, key("enter"), drawn)
            test.not_nil(s.browsing)
            drawn = view.draw(60, 16, appearance.defaults(), s)
            test.is_true(table.concat(drawn.rows, "\n"):find("bee.env:workspace_root", 1, true) ~= nil)
            view.input(s, key("enter"), drawn)
            view.input(s, key("enter"), drawn)
            test.eq(s.browsing and s.browsing.path, "legacy")
            view.input(s, key("rune", "u"), drawn)
            test.is_nil(s.browsing)
            test.eq(s.form.draft.workdir and s.form.draft.workdir.path, "legacy")
            test.eq(s.form.draft.workdir and s.form.draft.workdir.root_ref, "bee.env:workspace_root")
            -- Presentation, native home and permission answers precede the thread.
            view.input(s, key("tab"), drawn)
            view.input(s, key("tab"), drawn)
            view.input(s, key("tab"), drawn)
            view.input(s, key("tab"), drawn)
            view.input(s, key("enter"), drawn)
            local threads = s.threads
            if not threads then error("thread chooser did not open") end
            test.eq(#threads.items, 2)
            view.input(s, key("down"), drawn)
            view.input(s, key("enter"), drawn)
            test.eq(s.form.draft.thread and s.form.draft.thread.thread_id, "thread-1")
            drawn = view.draw(60, 16, appearance.defaults(), s)
            test.is_true(table.concat(drawn.rows, "\n"):find("Thread: Earlier work", 1, true) ~= nil)
            test.eq(view.action(s, "save"), "save")
            local result = editor.result(s.form.draft)
            test.eq(result and result.workdir and result.workdir.path, "legacy")
            test.eq(result and result.thread and result.thread.thread_id, "thread-1")
            -- The definition folder and a new thread clear the choices.
            view.input(s, key("up"), drawn)
            view.input(s, key("up"), drawn)
            view.input(s, key("up"), drawn)
            view.input(s, key("up"), drawn)
            view.input(s, key("enter"), drawn)
            view.input(s, key("rune", "d"), drawn)
            test.is_nil(s.form.draft.workdir)
            local closed = launch_state(false, false)
            local closed_rows = table.concat(view.draw(60, 16, appearance.defaults(), closed).rows, "\n")
            test.is_nil(closed_rows:find("Folder:", 1, true))
            test.is_nil(closed_rows:find("Thread:", 1, true))
        end)
        test.it("edits text, preserves UTF-8 on backspace and prepares a save without I/O", function()
            local s = state()
            view.action(s, "advanced")
            local frame = view.draw(60, 16, appearance.defaults(), s)
            view.input(s, {type = "key", action = "press", key = "u", key_type = "rune", ctrl = true, alt = false, shift = false}, frame)
            view.input(s, {type = "paste", text = "Bee 🐝"}, frame)
            view.input(s, {type = "key", action = "press", key = "", key_type = "backspace", ctrl = false, alt = false, shift = false}, frame)
            test.eq(s.title, "Bee ")
            view.input(s, {type = "key", action = "press", key = "space", key_type = "space", ctrl = false, alt = false, shift = false}, frame)
            test.eq(s.title, "Bee  ")
            view.input(s, {type = "key", action = "press", key = "", key_type = "tab", ctrl = false, alt = false, shift = false}, frame)
            view.input(s, key("tab"), frame)
            view.input(s, key("tab"), frame)
            view.input(s, key("tab"), frame)
            view.input(s, {type = "paste", text = "Use small changes.\nVerify them."}, frame)
            test.eq(view.action(s, "save"), "save")
            test.eq(s.form.draft.provider.system_prompt_append, "Use small changes.\nVerify them.")
            test.is_nil(s.form.pending)
        end)
        test.it("requires confirmation for removal and keeps submitted values frozen", function()
            local s = state()
            test.is_nil(view.action(s, "remove"))
            test.is_nil(view.action(s, "save"))
            test.is_nil(view.action(s, "cancel"))
            test.is_false(s.confirming_remove)
            view.action(s, "remove")
            test.eq(view.action(s, "remove"), "remove")
            s.confirming_remove = false
            s.form.pending = "save"
            local frame = view.draw(60, 16, appearance.defaults(), s)
            view.input(s, {type = "paste", text = "Cannot append"}, frame)
            test.eq(s.title, "Agent")
            test.eq(view.action(s, "save"), "save")
        end)
        test.it("edits a bounded text option from its own value", function()
            local s = text_state()
            view.action(s, "advanced")
            local frame = view.draw(60, 16, appearance.defaults(), s)
            -- Name, presentation, native home, permission answers, instructions, option.
            for _ = 1, 5 do
                view.input(s, {type = "key", action = "press", key = "", key_type = "tab",
                    ctrl = false, alt = false, shift = false}, frame)
            end
            view.input(s, {type = "key", action = "press", key = "", key_type = "backspace",
                ctrl = false, alt = false, shift = false}, frame)
            view.input(s, {type = "paste", text = "h"}, frame)
            test.eq(s.option_text.label, "ds-flash")
            test.eq(s.guidance, "Keep changes small.")
            test.eq(view.action(s, "save"), "save")
            test.eq(s.form.draft.provider.options.label, "ds-flash")
            test.eq(s.form.draft.provider.system_prompt_append, "Keep changes small.")
        end)
        test.it("keeps rows and mouse targets within compact terminal sizes", function()
            for _, size in ipairs({{1, 1}, {12, 4}, {30, 8}, {60, 16}}) do
                local frame = view.draw(size[1], size[2], appearance.defaults(), state())
                test.eq(#frame.rows, size[2])
                for _, hit in ipairs(frame.hits) do
                    test.is_true(hit.x >= 1 and hit.y >= 1 and hit.y <= size[2])
                    test.is_true(hit.width >= 0 and hit.x + hit.width - 1 <= size[1])
                end
            end
        end)
        test.it("hides technical grants until Advanced and preserves help at both sizes", function()
            for _, size in ipairs({{120, 36}, {80, 24}}) do
                local s = state()
                s.status = "Name is required"
                local shown = view.draw(size[1], size[2], appearance.defaults(), s)
                local plain = table.concat(shown.rows, "\n"):gsub("\27%[[0-9;]*m", "")
                test.is_nil((plain:find("thread_read", 1, true)))
                test.is_true(plain:find("Advanced", 1, true) ~= nil)
                test.is_true(shown.rows[size[2]]:find("Ctrl+S save", 1, true) ~= nil)
                test.is_true(shown.rows[size[2]]:find("? help", 1, true) ~= nil)
                view.action(s, "advanced")
                plain = table.concat(view.draw(size[1], size[2], appearance.defaults(), s).rows, "\n")
                test.is_true(plain:find("Read conversation history", 1, true) ~= nil)
                test.is_nil((plain:find("thread_read", 1, true)))
            end
        end)
        test.it("shows only actions that the current profile state accepts", function()
            local s = state()
            s.form.pending = "save"
            local pending = view.draw(60, 16, appearance.defaults(), s)
            local actions: {[string]: boolean} = {}
            for _, hit in ipairs(pending.hits) do actions[hit.kind] = true end
            test.is_true(actions.save)
            test.is_nil(actions.remove)
            test.is_true(actions.cancel)
            s.form.pending = nil
            s.confirming_remove = true
            local confirming = view.draw(60, 16, appearance.defaults(), s)
            actions = {}
            for _, hit in ipairs(confirming.hits) do actions[hit.kind] = true end
            test.is_nil(actions.save)
            test.is_true(actions.remove)
            test.is_true(actions.cancel)
            test.is_true(table.concat(confirming.rows, "\n"):find("Confirm", 1, true) ~= nil)
        end)
    end)
end
return test.run_cases(define_tests)
