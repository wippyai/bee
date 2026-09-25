-- MIT. Stopping the workspace broker stops its applications before the broker
-- exits, and an application that owns a PTY child reaps it first. The shell
-- here ignores SIGTERM, as an interactive shell does, so only an application
-- that waits for its child's completion can satisfy the order.
local test = require("test")
local process = require("process")
local channel = require("channel")
local security = require("security")
local time = require("time")
local exec = require("exec")
local uuid = require("uuid")
local appearance = require("appearance")

local WORKSPACE = string.rep("b", 32)
local DEFINITION = "bee.console:app"

local function running(marker: string): boolean
    local executor = assert(exec.get("bee:placement_executor"))
    local probe = assert(executor:exec("pgrep -f " .. marker))
    assert(probe:start())
    local code = probe:wait()
    executor:release()
    return math.floor(tonumber(code) or -1) == 0
end

local function define_tests()
    test.describe("Workspace broker stop", function()
        test.it("reaps an application's PTY child before the broker exits", function()
            local marker = "bee-broker-stop-" .. uuid.v7()
            local owner = tostring(process.pid())
            local events = assert(process.events())
            local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
            local replies = assert(process.listen("bee.app.reply", {message = true}))
            local broker_pid, broker_error = process.with_context({["bee.workspace_owner"] = owner,
                ["bee.workspace_id"] = WORKSPACE}):with_scope(security.new_scope({assert(security.policy("bee.security.desktop:broker_policy")),
                assert(security.policy("bee.security:core_spawn_boundary"))}))
                :spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults())
            if not broker_pid then error("broker spawn failed: " .. tostring(broker_error)) end
            local broker = tostring(broker_pid)
            assert(catalogs:receive():from() == broker)

            local request_id = "broker-stop-open"
            assert(process.send(broker, "bee.app.request", {version = 1, request_id = request_id, op = "open",
                workspace_id = WORKSPACE, definition_id = DEFINITION,
                arguments = {"/bin/sh", "-c", "trap \"\" TERM; while :; do sleep 0.1; done", marker}}))
            local opened: {[string]: unknown}? = nil
            local deadline = time.after("30s")
            while not opened do
                local received = channel.select({replies:case_receive(), deadline:case_receive()})
                assert(received.ok and received.channel == replies, "open reply timed out")
                local message = received.value
                if tostring(message:from()) == broker then
                    local data: unknown = message:payload():data()
                    if type(data) == "table" and (data :: {[string]: unknown}).request_id == request_id
                        and (data :: {[string]: unknown}).op == "open" then opened = data :: {[string]: unknown} end
                end
            end
            test.eq(opened.error_code, "", "terminal did not become ready: " .. tostring(opened.error))
            test.is_true(running(marker), "the terminal child is not running")

            assert(process.cancel(broker, "workspace stopping"))
            local exited = false
            while not exited do
                local received = channel.select({events:case_receive(), deadline:case_receive()})
                assert(received.ok and received.channel == events, "broker did not exit")
                local event = received.value
                exited = event.kind == process.event.EXIT and tostring(event.from) == broker
            end
            test.is_false(running(marker), "the terminal child outlived the broker")
            process.unlisten(catalogs)
            process.unlisten(replies)
        end)
    end)
end
return test.run_cases(define_tests)
