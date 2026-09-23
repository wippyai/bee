-- MIT. A ready application that returns normally closed its own view. The
-- broker reports that EXIT as an ordinary close, so the workspace retires the
-- instance instead of preserving it as a failed application.
local test = require("test")
local process = require("process")
local channel = require("channel")
local security = require("security")
local time = require("time")
local appearance = require("appearance")

local WORKSPACE = string.rep("c", 32)
local DEFINITION = "bee.console:app"

local function define_tests()
    test.describe("Workspace broker application exit", function()
        test.it("reports a clean return of a ready application as closed", function()
            local owner = tostring(process.pid())
            local events = assert(process.events())
            local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
            local replies = assert(process.listen("bee.app.reply", {message = true}))
            local broker_pid, broker_error = process.with_context({["bee.workspace_owner"] = owner,
                ["bee.workspace_id"] = WORKSPACE}):with_scope(security.new_scope({assert(security.policy("bee:broker_policy")),
                assert(security.policy("bee:core_spawn_boundary"))}))
                :spawn_monitored("bee.applications:broker", "bee:workers", owner, appearance.defaults())
            if not broker_pid then error("broker spawn failed: " .. tostring(broker_error)) end
            local broker = tostring(broker_pid)
            assert(catalogs:receive():from() == broker)

            local request_id = "broker-exit-open"
            assert(process.send(broker, "bee.app.request", {version = 1, request_id = request_id, op = "open",
                workspace_id = WORKSPACE, definition_id = DEFINITION, arguments = {"/bin/sh", "-c", "sleep 0.3"}}))
            local deadline = time.after("30s")
            local function reply(op: string, id: string?): {[string]: unknown}
                while true do
                    local received = channel.select({replies:case_receive(), deadline:case_receive()})
                    assert(received.ok and received.channel == replies, op .. " reply timed out")
                    local message = received.value
                    local data: unknown = message:payload():data()
                    if tostring(message:from()) == broker and type(data) == "table" then
                        local value = data :: {[string]: unknown}
                        if value.op == op and (id == nil or value.id == id)
                            and (op ~= "open" or value.request_id == request_id) then return value end
                    end
                end
                error("reply channel closed")
            end
            local opened = reply("open")
            test.eq(opened.error_code, "", "terminal did not become ready: " .. tostring(opened.error))
            local closed = reply("closed", tostring(opened.id))
            test.eq(closed.instance_id, opened.instance_id)
            test.eq(closed.error_code, "", "clean application return was reported as " .. tostring(closed.error_code))

            assert(process.cancel(broker, "workspace stopping"))
            local exited = false
            while not exited do
                local received = channel.select({events:case_receive(), deadline:case_receive()})
                assert(received.ok and received.channel == events, "broker did not exit")
                local event = received.value
                exited = event.kind == process.event.EXIT and tostring(event.from) == broker
            end
            process.unlisten(catalogs)
            process.unlisten(replies)
        end)
    end)
end
return test.run_cases(define_tests)
