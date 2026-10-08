-- SPDX-License-Identifier: MIT
local test = require("test")
local appearance = require("appearance")
local picker = require("picker")
local directory = require("directory")
local view = require("view")
local editor = require("editor")
local caller = require("caller")
local agents = require("agents")
local function state(): view.State
    local draft = assert(editor.new({schema_revision = "bee.agent-profile@3", name = "Small worker", definition_ref = "host:worker",
        driver_binding_ref = "driver:binding", provider = {options = {temperature = "cool"}}, bee = {mcp = {{tool = "thread_read", scope = {}}}}},
        {options = {temperature = {"cool", "warm"}}, mcp_tools = {"thread_read"}, instructions = true}))
    return view.new({workspace_id = "workspace", profile_id = "profile", revision = 1, draft = draft,
        fields = {temperature = {label = "Temperature", section = "basic", order = 1}}, save_key = "save", remove_key = "remove"},
        function(target, _request): caller.Reply return {ok = false, value = nil, replayed = false, error = {code = "NOT_FOUND", message = target}} end)
end
local function define_tests()
    test.describe("Profile discovery", function()
        test.it("offers only installed definitions as driver choices", function()
            local drivers = agents.profile_drivers({items = {
                {ref = "installed:one", kind = "definition", title = "One", status = "ready", ready = true, reason = ""},
                {ref = "installed:two", kind = "definition", title = "Two", status = "unconfigured", ready = false, reason = "Login needed"},
                {ref = "absent:three", kind = "definition", title = "Three", status = "missing", ready = false, reason = "Missing"},
                {ref = "saved", kind = "profile", title = "Saved", status = "ready", ready = true, reason = ""}}, unavailable = 2, notes = {}})
            test.eq(#drivers, 2)
            test.eq(drivers[1].definition_ref, "installed:one")
            test.eq(drivers[2].definition_ref, "installed:two")
        end)
        test.it("offers Start agent, New profile and Edit as visible actions", function()
            local prefs = appearance.defaults()
            test.contains(directory.draw(160, 24, prefs, {}, 0, "", false).rows[24], "Start agent")
            local shown = picker.draw(160, 24, prefs, {items = {
                {ref = "profile", kind = "profile", title = "Small worker", status = "ready", ready = true, reason = ""}}, unavailable = 0, notes = {}}, 1, "")
            test.contains(shown.rows[24], "N New profile")
            test.contains(shown.rows[24], "E Edit")
        end)
        test.it("shows driver identity, declared options, permissions and prompt in basic fields", function()
            local s = state()
            local shown = table.concat(view.draw(160, 45, appearance.defaults(), s).rows, "\n")
            for _, value in ipairs({"Driver:", "Temperature: cool", "Permission answers:", "System prompt:"}) do test.contains(shown, value) end
        end)
        test.it("saves validated MCP scopes and traits without replacing unrelated grants", function()
            local s = state()
            s.settings["mcp.thread_read"] = '{"workspace_id":"workspace","traits":["docs"]}'
            test.eq(view.action(s, "save"), "save")
            test.eq(s.form.draft.bee.mcp[1].scope.workspace_id, "workspace")
            test.eq(s.form.draft.bee.mcp[1].scope.traits[1], "docs")
            s.settings["mcp.thread_read"] = '{"access":"root"}'
            test.is_nil(view.action(s, "save"))
            test.eq(s.form.draft.bee.mcp[1].scope.traits[1], "docs")
        end)
    end)
end
return test.run_cases(define_tests)
