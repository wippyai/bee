-- MIT. The client trusts only this node's supervisor: found by name, checked
-- by host, correlated by request id, bounded by a deadline.
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local client = require("client")
local types = require("types")
local OWNER = {node_id = "local", service_id = "bee.hive.telemetry"}
local TARGET = {operation_ref = "bee.hive.telemetry.binding:stats"}
local supervisor_sequence = 0
local function spawn_supervisor(host: string): (string, Channel<process.Event>)
    supervisor_sequence = supervisor_sequence + 1
    local topic = "bee.test.supervisor.ready." .. tostring(process.pid()) .. "." .. tostring(supervisor_sequence)
    local ready = assert(process.listen(topic, {message = true}))
    local lifecycle = assert(process.events())
    local pid, spawn_error = process.spawn_monitored("bee.hive:fake_supervisor", host, process.pid(), topic)
    if not pid then process.unlisten(ready); error("spawn supervisor: " .. tostring(spawn_error)) end
    local supervisor = tostring(pid)
    local deadline = time.after("30s")
    while true do
        local selected = channel.select({ready = ready:case_receive(), lifecycle = lifecycle:case_receive(), deadline = deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then
            process.unlisten(ready)
            process.terminate(supervisor)
            error("supervisor did not register its name")
        end
        if selected.channel == lifecycle then
            local event = selected.value
            if event.kind == process.event.EXIT and tostring(event.from) == supervisor then
                process.unlisten(ready)
                error("supervisor exited before registering its name")
            end
        else
            local message = selected.value
            if tostring(message:from()) == supervisor then
                local result = message:payload():data()
                if result.ready then
                    process.unlisten(ready)
                    return supervisor, lifecycle
                end
            end
        end
    end
    error("supervisor readiness wait ended")
end
local function stop_supervisor(supervisor: string, lifecycle: Channel<process.Event>)
    local stopped, stop_error = process.terminate(supervisor)
    if not stopped then error("terminate supervisor: " .. tostring(stop_error)) end
    local deadline = time.after("30s")
    while true do
        local selected = channel.select({lifecycle = lifecycle:case_receive(), deadline = deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("supervisor did not exit") end
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == supervisor then return end
    end
end
local function define_tests()
    test.describe("Hive client", function()
        test.it("reports an absent supervisor without waiting", function()
            local handle, open_error = client.open()
            if not handle then error(tostring(open_error)) end
            local reply = handle:call(OWNER, TARGET, {mode = "echo"}, {timeout = "1s"})
            test.is_false(reply.ok)
            test.eq(reply.error and reply.error.code, "UNAVAILABLE")
            handle:close()
        end)
        test.it("refuses a supervisor name that resolves outside the supervisor host", function()
            local impostor, lifecycle = spawn_supervisor("bee:workers")
            local handle = client.open()
            if not handle then error("open") end
            local reply = handle:call(OWNER, TARGET, {mode = "echo"}, {timeout = "1s"})
            test.eq(reply.error and reply.error.code, "UNAVAILABLE")
            test.eq(reply.error and reply.error.message, "supervisor name resolves outside the supervisor host")
            handle:close()
            stop_supervisor(impostor, lifecycle)
        end)
        test.it("correlates replies from the supervisor and ignores everyone else", function()
            local supervisor, lifecycle = spawn_supervisor(types.SUPERVISOR_HOST)
            local handle = client.open()
            if not handle then error("open") end
            local echoed = handle:call(OWNER, TARGET, {mode = "echo", n = 1}, {idempotency_key = "k1", timeout = "2s"})
            test.is_true(echoed.ok)
            test.eq(echoed.value.echo.n, 1)
            test.eq(echoed.value.owner, "bee.hive.telemetry")
            local stale = handle:call(OWNER, TARGET, {mode = "stale"}, {timeout = "2s"})
            test.is_true(stale.ok)
            test.is_true(stale.value.fresh)
            local delayed = handle:call(OWNER, TARGET, {mode = "delayed"}, {timeout = "2s"})
            test.is_true(delayed.value.late)
            local impostor = handle:call(OWNER, TARGET, {mode = "impostor"}, {timeout = "400ms"})
            test.eq(impostor.error and impostor.error.code, "DEADLINE_EXCEEDED")
            local malformed = handle:call(OWNER, TARGET, {mode = "malformed"}, {timeout = "2s"})
            test.eq(malformed.error and malformed.error.code, "INTERNAL")
            local silent = handle:call(OWNER, TARGET, {mode = "silent"}, {timeout = "200ms"})
            test.eq(silent.error and silent.error.code, "DEADLINE_EXCEEDED")
            local after = handle:call(OWNER, TARGET, {mode = "echo", n = 2}, {timeout = "2s"})
            test.eq(after.value.echo.n, 2)
            local empty_object: {[string]: unknown} = table.create(0, 1)
            local empty = handle:call(OWNER, TARGET, {}, {timeout = "2s"})
            test.is_true(empty.ok)
            test.eq(empty.value.input_digest, assert(types.digest(empty_object)))
            local invalid = handle:call(OWNER, {operation_ref = "a:b", interface_ref = "a:c"}, {}, {timeout = "1s"})
            test.eq(invalid.error and invalid.error.code, "INVALID_ARGUMENT")
            handle:close()
            stop_supervisor(supervisor, lifecycle)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
