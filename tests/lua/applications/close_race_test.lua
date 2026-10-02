local test = require("test")
local bounds = require("bounds")
local process = require("process")
local channel = require("channel")
local security = require("security")
local time = require("time")
local appearance = require("appearance")
local fixture = require("fixture")
local WORKSPACE = string.rep("e", 32)
local function define_tests()
    test.describe("Broker close and monitored exit", function()
        test.it("acknowledges close when escalation finds an exited producer before consuming EXIT", fixture.case(function(scope: fixture.State)
            local owner = tostring(process.pid())
            local events = scope.events
            local catalogs = scope.catalogs
            local replies = scope.replies
            local gates = assert(process.listen("bee.test.close_gate", {message = true}))
            local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner,
                ["bee.workspace_id"] = WORKSPACE, ["bee.test.close_exit_order"] = true})
                :with_scope(security.new_scope({assert(security.policy("bee.security.desktop:broker_policy")),
                    assert(security.policy("bee.security:core_spawn_boundary"))}))
                :spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults(), {})))
            scope.brokers[broker] = true
            local function reply(request_id: string): {[string]: unknown}
                local deadline = time.after("10s")
                while true do
                    local selected = channel.select({replies:case_receive(), deadline:case_receive()})
                    assert(selected.ok and selected.channel == replies, "reply timed out: " .. request_id)
                    local message = selected.value
                    local data = assert(bounds.object(message:payload():data()))
                    if tostring(message:from()) == broker and data.request_id == request_id then return data end
                end
                error("reply channel closed")
            end
            local function exit(pid: string)
                local deadline = time.after("10s")
                while true do
                    local selected = channel.select({events:case_receive(), deadline:case_receive()})
                    assert(selected.ok and selected.channel == events, "exit timed out: " .. pid)
                    local event = selected.value
                    if event.kind == process.event.EXIT and tostring(event.from) == pid then return event end
                end
                error("event channel closed")
            end
            local ok, fault = pcall(function()
                assert(tostring(catalogs:receive():from()) == broker)
                assert(process.send(broker, "bee.app.request", {version = 1, op = "open", request_id = "race-open",
                    workspace_id = WORKSPACE, definition_id = "bee.apps:welcome", arguments = {}}))
                local opened = reply("race-open")
                test.eq(opened.error_code, "")
                assert(process.send(broker, "bee.app.request", {version = 1, op = "close", request_id = "race-close",
                    workspace_id = WORKSPACE, id = opened.id}))
                local deadline = time.after("10s")
                local selected = channel.select({gates:case_receive(), deadline:case_receive()})
                assert(selected.ok and selected.channel == gates, "close gate timed out")
                test.eq(tostring(selected.value:from()), broker)
                local data = assert(bounds.object(selected.value:payload():data()))
                assert(type(data.pid) == "string")
                assert(process.monitor(data.pid))
                assert(process.send(broker, "bee.test.close_release", {}))
                local event = exit(data.pid)
                test.is_nil(event.result and event.result.error)
                assert(process.send(broker, "bee.test.close_release", {}))
                local closed = reply("race-close")
                test.eq(closed.error_code, "", tostring(closed.error))
                test.eq(closed.op, "close")
                test.eq(closed.instance_id, opened.instance_id)
            end)
            if not ok then
                assert(process.terminate(broker))
                exit(broker)
                scope.brokers[broker] = nil
            end
            process.unlisten(gates)
            assert(ok, tostring(fault))
        end))
        test.it("releases the close case's readiness publication before the next broker starts", fixture.case(function(scope: fixture.State)
            local owner = tostring(process.pid())
            local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner,
                ["bee.workspace_id"] = WORKSPACE}):with_scope(security.new_scope({
                    assert(security.policy("bee.security.desktop:broker_policy")),
                    assert(security.policy("bee.security:core_spawn_boundary"))}))
                :spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults(), {})))
            scope.brokers[broker] = true
            test.eq(tostring(scope.catalogs:receive():from()), broker)
            local deadline = time.after("10s")
            local selected = channel.select({scope.ready:case_receive(), deadline:case_receive()})
            assert(selected.ok and selected.channel == scope.ready, "broker readiness timed out")
            test.eq(tostring(selected.value:from()), broker, "previous close case's readiness escaped its scope")
        end))
    end)
end
return test.run_cases(define_tests)
