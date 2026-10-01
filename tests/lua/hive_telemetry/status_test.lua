-- MIT.
local test = require("test")
local status = require("status")
local types = require("types")
local funcs = require("funcs")
local bounds = require("bounds")
local security = require("security")
local function define_tests()
    test.describe("Approved Hive status", function()
        test.it("retains enrolled offline peers and excludes native clients", function()
            local nodes = assert(status.members({{id = "local", is_local = true},
                {id = "remote", is_local = false, link = {remote = "127.0.0.1:1", dialed = true}},
                {id = "client", is_local = false, meta = {["bee.role"] = "client"}}}, {"remote", "offline"}, "local"))
            test.eq(#nodes, 3)
            test.eq(nodes[1].node_id, "local")
            test.is_true(nodes[1].online)
            test.eq(nodes[2].node_id, "offline")
            test.is_false(nodes[2].online)
            test.eq(nodes[3].node_id, "remote")
            test.is_true(nodes[3].online)
            test.eq(status.members({{id = "other", is_local = true}}, {}, "local"), nil)
            test.eq(status.members({{id = "local", is_local = true}, {id = "local", is_local = true}}, {}, "local"), nil)
        end)
        test.it("reports unavailable counts separately from zero and rejects foreign node replies", function()
            local nodes = assert(status.members({{id = "local", is_local = true}}, {"offline", "wrong-reply"}, "local"))
            local counts = 0
            local function call(owner: types.OwnerRef, target: types.Target, _: {[string]: unknown}, _options: {timeout: string?}): types.Reply
                test.eq(target.operation_ref, "bee.hive.telemetry:node_summary")
                if owner.node_id == "offline" then return types.reply_error("id", types.fault("UNAVAILABLE", "offline")) end
                return types.reply_ok("id", {node_id = owner.node_id == "wrong-reply" and "wrong" or owner.node_id,
                    name = "Friendly node", running_sessions = counts, pending_approvals = 0})
            end
            local result = status.aggregate(call, nodes)
            test.eq(result[1].running_sessions, 0)
            test.eq(result[1].name, "Friendly node")
            test.eq(result[2].running_sessions, nil)
            test.eq(result[2].status, "unavailable")
            test.eq(result[3].status, "unavailable")
            counts = 1
            test.eq(status.aggregate(call, nodes)[1].running_sessions, 1)
            test.eq(status.decode_summary({node_id = "local", name = "x", running_sessions = -1, pending_approvals = 0}, "local"), nil)
            test.eq(status.decode_summary({node_id = "local", name = "x", running_sessions = 0, pending_approvals = 0, requests = {}}, "local"), nil)
        end)
        test.it("reads real owners through host bindings and refuses direct ungranted calls", function()
            local raw, err = funcs.call("bee.hive.telemetry:node_summary", {})
            test.eq(err, nil)
            local summary = bounds.object(raw)
            if not summary or type(summary.node_id) ~= "string" then error("node summary missing") end
            if not status.decode_summary(summary, summary.node_id) then error("real summary failed strict decode") end
            local denied = funcs.new():with_actor(security.new_actor("ungranted-status-reader")):with_scope(security.new_scope({assert(security.policy("bee.hive.telemetry:gateway_only_test_policy"))}))
            local _, denial = denied:call("bee.hive.telemetry.binding:snapshot", {})
            if not denial then error("ungranted direct function call was admitted") end
        end)
        test.it("accepts only empty snapshot and one enrolled identity for detail", function()
            test.eq(status.query({extra = true}, false), nil)
            test.eq(status.query({node_id = "local", extra = true}, true), nil)
            test.eq(status.query({}, true), nil)
            test.eq(assert(status.query({node_id = "local"}, true)).node_id, "local")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
