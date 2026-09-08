-- MIT. Recovery selection follows owned inventory and pending reservations.
local test = require("test")
local recovery = require("recovery")
local records = require("records")
local inventory = require("inventory")
local function record(id: string, definition: string): records.Record
    return {id = "view-" .. id, instance_id = id, definition_id = definition,
        resume_schema = "state.v1", restart_policy = "manual", resume_state = '{"count":7}', window = nil}
end
local function define_tests()
    test.describe("Host checkpoint selection", function()
        test.it("skips running and reserved identities without changing saved state", function()
            local live: inventory.State = inventory.new("0123456789abcdef0123456789abcdef")
            live.views = {{workspace_id = live.workspace_id, view_id = "view-first", instance_id = "first",
                definition_id = "probe:app", title = "Probe"}}
            local saved = {record("foreign", "other:app"), record("first", "probe:app"),
                record("second", "probe:app"), record("third", "probe:app")}
            local selected = recovery.select(saved, live, "probe:app", {second = true})
            if not selected then error("Missing available checkpoint") end
            test.eq(selected.instance_id, "third")
            test.eq(selected.state, '{"count":7}')
            selected.state = "changed"
            test.eq(saved[4].resume_state, '{"count":7}')
            test.is_nil(recovery.select(saved, live, "probe:app", {second = true, third = true}))
        end)
        test.it("does not reuse a live view under a different instance", function()
            local live: inventory.State = inventory.new("0123456789abcdef0123456789abcdef")
            live.views = {{workspace_id = live.workspace_id, view_id = "view-first", instance_id = "replacement",
                definition_id = "probe:app", title = "Probe"}}
            test.is_nil(recovery.select({record("first", "probe:app")}, live, "probe:app", {}))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
