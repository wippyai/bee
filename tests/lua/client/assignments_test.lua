-- MIT. Durable assignment drives layout; discovery alone cannot select apps.
local test = require("test")
local assignments = require("assignments")
local workspace = "0123456789abcdef0123456789abcdef"
local function define_tests()
    test.describe("Assigned application layout", function()
        test.it("moves only the exact app and preserves neighboring and foreign tabs", function()
            local targets = {
                {workspace_id = workspace, tab_id = "moving", view_id = "view", instance_id = "instance"},
                {workspace_id = workspace, tab_id = "neighbor", view_id = "other", instance_id = "other-instance"},
                {workspace_id = "foreign", tab_id = "foreign", view_id = "view", instance_id = "instance"}}
            local live = {{workspace_id = workspace, view_id = "view", instance_id = "instance", definition_id = "terminal", title = "Shell"}}
            local decision = {{view_id = "view", instance_id = "instance", display_id = "target", revision = 2, pending = false}}
            local source = assignments.plan(workspace, "source", targets, live, decision)
            test.eq(#source.remove, 1)
            test.eq(source.remove[1], "moving")
            test.eq(#source.add, 0)
            local target = assignments.plan(workspace, "target", {}, live, decision)
            test.eq(#target.add, 1)
            test.eq(target.add[1].instance_id, "instance")
            test.eq(#assignments.plan(workspace, "target", targets, live, decision).add, 0)
        end)
        test.it("does not launch from discovery, pending intent or an old incarnation", function()
            local live = {{workspace_id = workspace, view_id = "view", instance_id = "new", definition_id = "terminal", title = "Shell"}}
            test.eq(#assignments.plan(workspace, "target", {}, live, {}).add, 0)
            local decision = {{view_id = "view", instance_id = "old", display_id = "target", revision = 2, pending = false}}
            test.eq(#assignments.plan(workspace, "target", {}, live, decision).add, 0)
            decision[1].instance_id = "new"
            decision[1].pending = true
            test.eq(#assignments.plan(workspace, "target", {}, live, decision).add, 0)
            decision[1].pending = false
            test.eq(#assignments.plan(workspace, "target", {}, {}, decision).add, 0)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
