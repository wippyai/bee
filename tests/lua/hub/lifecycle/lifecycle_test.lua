-- MIT.
local test = require("test")
local lifecycle = require("lifecycle")
local function state(): unknown
    return {entries = {
        {id = "demo.service:worker", kind = "process.lua", data = {source = "old"}, registry = {owner = "demo/component"}},
        {id = "host:worker", kind = "process.service", meta = {component_lifecycle = "demo.binding:lifecycle"},
            data = {process = "demo.service:worker", host = "host:workers", lifecycle = {auto_start = true}}},
        {id = "demo.binding:lifecycle", kind = "function.lua", data = {source = "handler"}, registry = {owner = "demo/component"}},
    }}
end
local function candidates(): {lifecycle.Entry}
    return {
        {id = "demo.service:worker", kind = "process.lua", data = {source = "new"}, meta = {}, owner = "demo/component"},
        {id = "demo.binding:lifecycle", kind = "function.lua", data = {source = "handler"}, meta = {}, owner = "demo/component"},
    }
end
local function run()
    test.describe("Hub service lifecycle intent", function()
        test.it("captures host-selected services of changed process owners", function()
            local work, problem = lifecycle.capture(state(), {{component = "demo/component", change = "update"}}, candidates())
            test.is_nil(problem)
            test.not_nil(work)
            if not work then return end
            test.eq(#work.services, 1)
            test.eq(work.services[1].id, "host:worker")
            test.eq(work.services[1].owner, "demo/component")
            test.eq(work.services[1].retention, "retain")
            test.eq(work.phase, "prepared")
            test.eq(work.services[1].change, "update")
            test.is_false(work.services[1].before == work.services[1].candidate)
            test.eq(work.services[1].registration_before, work.services[1].registration_candidate)
            test.not_nil(lifecycle.decode(work))
        end)
        test.it("refuses lifecycle declarations outside the owner", function()
            local raw = state()
            if type(raw) ~= "table" or type(raw.entries) ~= "table" then error("invalid test") end
            raw.entries[2].meta.component_lifecycle = "foreign:handler"
            local work, problem = lifecycle.capture(raw, {{component = "demo/component", change = "remove"}}, {})
            test.is_nil(work)
            test.not_nil(problem)
        end)
        test.it("refuses service changes without explicit owner drain evidence", function()
            local raw = state()
            if type(raw) ~= "table" or type(raw.entries) ~= "table" then error("invalid test") end
            raw.entries[2].meta = {}
            local work, problem = lifecycle.capture(raw, {{component = "demo/component", change = "update"}}, {})
            test.is_nil(work)
            test.not_nil(problem)
        end)
        test.it("rejects malformed and duplicate persisted lifecycle services", function()
            test.is_nil(lifecycle.decode({version = 1, phase = "complete", services = {}}))
            test.is_nil(lifecycle.decode({version = 1, phase = "prepared", services = {{id = "demo:bad"}}}))
        end)
        test.it("keeps host-owned service definitions from dangling on removal", function()
            local work, problem = lifecycle.capture(state(), {{component = "demo/component", change = "remove"}}, {})
            test.is_nil(work)
            test.not_nil(problem)
        end)
        test.it("withdraws application admission while removal intent is pending", function()
            local raw = state()
            if type(raw) ~= "table" or type(raw.entries) ~= "table" then error("invalid test") end
            raw.entries[#raw.entries + 1] = {id = "bee.hub.operations:" .. string.rep("a", 64), kind = "registry.entry",
                data = {digest = string.rep("a", 64), actor_id = "fixture:actor", component = "demo/component",
                    baseline_revision = 1, message = "prepared", state = "prepared", action = "uninstall", expected_modules = {{component = "demo/component", change = "remove"}}}}
            local withdrawn = lifecycle.withdrawn(raw)
            test.eq(withdrawn["demo.service:worker"], true)
            test.is_nil(withdrawn["host:worker"])
        end)
        test.it("does not stop services of unchanged owners", function()
            local work, problem = lifecycle.capture(state(), {{component = "demo/component", change = "keep"}}, {})
            test.is_nil(problem)
            test.not_nil(work)
            if work then test.eq(#work.services, 0) end
        end)
    end)
end
local cases = test.run_cases(run)
return {run = function(options) return cases(options) end}
