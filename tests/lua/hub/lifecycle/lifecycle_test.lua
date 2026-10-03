-- MIT.
local test = require("test")
local funcs = require("funcs")
local registry = require("registry")
local security = require("security")
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
        test.it("admits the receipt migration from the restricted workspace host scope", function()
            local host = assert(security.policy("bee.security.desktop:host_policy"))
            local probe = assert(security.policy("tests.hub.lifecycle:receipt_metadata_probe_policy"))
            local caller = assert(funcs.new():with_scope(security.new_scope({host, probe})))
            local result, call_error = caller:call("tests.hub.lifecycle:receipt_metadata_probe")
            test.is_nil(call_error)
            if type(result) ~= "table" then error("invalid host migration reply") end
            test.is_true(result.ok == true, tostring(result.message))
        end)
        test.it("refuses receipt migration without the host-selected migration grant", function()
            local caller = assert(funcs.new():with_scope(security.new_scope({})))
            local before = assert(registry.snapshot()):version():string()
            local result, call_error = caller:call("bee.hub.binding:receipt_metadata")
            test.is_nil(call_error)
            if type(result) ~= "table" then error("invalid denied migration reply") end
            test.eq(result.ok, false)
            test.eq(result.code, "DENIED")
            test.eq(result.message, "Hub receipt metadata migration is not admitted")
            test.eq(assert(registry.snapshot()):version():string(), before)
        end)
        test.it("tags historical receipt metadata once without changing its measured data", function()
            local id = "bee.hub.operations:" .. string.rep("e", 64)
            local data = {digest = string.rep("e", 64), actor_id = "fixture:actor", component = "fixture/component",
                baseline_revision = 1, message = "complete", state = "complete", action = "update"}
            local snapshot = assert(registry.snapshot())
            local changes = assert(snapshot:changes())
            assert(changes:create({id = id, kind = "registry.entry", meta = {comment = "preserved"}, data = data}))
            assert(changes:apply())
            local migrated, migration_error = funcs.call("bee.hub.binding:receipt_metadata")
            test.is_nil(migration_error)
            if type(migrated) ~= "table" then error("invalid migration reply") end
            test.is_true(migrated.ok == true, tostring(migrated.message))
            local tagged = assert(registry.get(id))
            test.eq(tagged.meta.type, "bee.hub_operation")
            test.eq(tagged.meta.comment, "preserved")
            for field, expected in pairs(data) do test.eq(tagged.data[field], expected) end
            for field in pairs(tagged.data) do test.not_nil(data[field]) end
            local repeated, repeat_error = funcs.call("bee.hub.binding:receipt_metadata")
            test.is_nil(repeat_error)
            if type(repeated) ~= "table" or type(repeated.value) ~= "table" then error("invalid repeated migration reply") end
            test.eq(repeated.value.tagged, 0)
            local cleanup = assert(assert(registry.snapshot()):changes())
            assert(cleanup:delete(id)); assert(cleanup:apply())
        end)
        test.it("reports malformed historical receipts without leaving a partial revision", function()
            local id = "bee.hub.operations:" .. string.rep("f", 64)
            local changes = assert(assert(registry.snapshot()):changes())
            assert(changes:create({id = id, kind = "registry.entry", data = {digest = "broken"}}))
            assert(changes:apply())
            local before = assert(registry.snapshot()):version():string()
            local result, call_error = funcs.call("bee.hub.binding:receipt_metadata")
            local after = assert(registry.snapshot()):version():string()
            local cleanup = assert(assert(registry.snapshot()):changes())
            assert(cleanup:delete(id)); assert(cleanup:apply())
            test.is_nil(call_error)
            if type(result) ~= "table" then error("invalid migration reply") end
            test.is_false(result.ok == true)
            test.eq(result.message, id .. ": Hub operation receipt digest is invalid")
            test.eq(after, before)
        end)
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
            raw.entries[#raw.entries + 1] = {id = "vendor.receipts:operation", kind = "registry.entry", meta = {type = "bee.hub_operation"},
                data = {digest = string.rep("a", 64), actor_id = "fixture:actor", component = "demo/component",
                    baseline_revision = 1, message = "prepared", state = "prepared", action = "uninstall", expected_modules = {{component = "demo/component", change = "remove"}}}}
            local withdrawn = lifecycle.withdrawn(raw)
            test.eq(withdrawn["demo.service:worker"], true)
            test.is_nil(withdrawn["host:worker"])
        end)
        test.it("reports the exact malformed tagged receipt cause instead of dropping the removal fence", function()
            local raw = state()
            if type(raw) ~= "table" or type(raw.entries) ~= "table" then error("invalid test") end
            raw.entries[#raw.entries + 1] = {id = "vendor.receipts:bad", kind = "registry.entry", meta = {type = "bee.hub_operation"}, data = {digest = "invalid"}}
            local valid, problem = pcall(lifecycle.withdrawn, raw)
            test.is_false(valid)
            test.is_true(string.find(tostring(problem), "Hub operation receipt digest is invalid", 1, true) ~= nil)
        end)
        test.it("does not stop services of unchanged owners", function()
            local work, problem = lifecycle.capture(state(), {{component = "demo/component", change = "keep"}}, {})
            test.is_nil(problem)
            test.not_nil(work)
            if work then test.eq(#work.services, 0) end
        end)
        test.it("retains an unchanged service across a component version update", function()
            local raw = state()
            if type(raw) ~= "table" or type(raw.entries) ~= "table" then error("invalid test") end
            raw.entries[2].meta = {}
            local identical = assert(lifecycle.entries(raw))
            local work, problem = lifecycle.capture(raw, {{component = "demo/component", change = "update"}}, identical)
            test.is_nil(problem)
            test.not_nil(work)
            if work then test.eq(#work.services, 0) end
        end)
        test.it("requires owner lifecycle when an imported service library changes", function()
            local raw = state()
            if type(raw) ~= "table" or type(raw.entries) ~= "table" then error("invalid test") end
            raw.entries[1].data.imports = {logic = "demo:logic"}
            raw.entries[2].meta = {}
            raw.entries[#raw.entries + 1] = {id = "demo:logic", kind = "library.lua",
                data = {source = "old library"}, registry = {owner = "demo/component"}}
            local updated = assert(lifecycle.entries(raw))
            updated[#updated].data = {source = "new library"}
            local work, problem = lifecycle.capture(raw, {{component = "demo/component", change = "update"}}, updated)
            test.is_nil(work)
            test.eq(problem, "service needs an explicit lifecycle function from its owner: host:worker")
        end)
    end)
end
local cases = test.run_cases(run)
return {run = function(options) return cases(options) end}
