local test = require("test")
local host = require("host")
local harness = require("harness")
local bounds = require("bounds")
local response = require("response")
local funcs = require("funcs")
local process = require("process")
local events = require("events")
local channel = require("channel")
local security = require("security")
local function dispatch(session: host.Session, point: string, input: unknown?, output: unknown?, occurrence: string?): {[string]: unknown}
    return host.call("bee.threads.hooks:dispatch", {session_ref = session.session, thread_id = session.thread,
        workspace_id = host.WORKSPACE, point = point, occurrence_id = occurrence or harness.key(), input = input, output = output})
end
local function define_tests()
    test.describe("Session extension hooks", function()
        test.after_all(host.close_all)
        test.it("concurrent deliveries of one PreToolUse both receive its durable denial", function()
            local session = host.open(nil, "bee.tests.memory:hooks_a")
            local ready = assert(process.listen("bee.tests.hook.ready", {message = true}))
            local executor = funcs.new():with_actor(security.new_actor("memory-fixture-host", {workspace_id = host.WORKSPACE}))
            local request = {session_ref = session.session, thread_id = session.thread, workspace_id = host.WORKSPACE,
                point = "tool.before", occurrence_id = harness.key(), input = {mode = "held_deny", controller = tostring(process.pid())}}
            local first = assert(executor:async("bee.threads.hooks:dispatch", request))
            local message = assert((ready:receive()))
            local held = assert(bounds.object(message:payload():data()))
            local waiting = assert(events.subscribe("bee.session.hook/" .. assert(bounds.id(held.invocation_id)), "waiting"))
            local second = assert(executor:async("bee.threads.hooks:dispatch", request))
            channel.select({assert(second:response()):case_receive(), waiting:channel():case_receive()})
            assert(process.send(assert(bounds.id(held.pid)), "bee.tests.hook.release", {}))
            for _, future in ipairs({first, second}) do
                if not future:is_complete() then assert(future:response()):receive() end
                local value, err = future:result()
                test.is_nil(err)
                local reply = host.value(assert(value):data())
                test.is_true(reply.denied)
                test.eq(reply.reason, "fixture concurrent denial")
            end
            waiting:close()
            process.unlisten(ready)
        end)
        test.it("concurrent replay chains the earlier accepted change before a later trait", function()
            local session = host.open(nil, "bee.tests.memory:hooks_a")
            host.approve(session.binding, nil, "bee.tests.memory:hooks_b")
            local ready = assert(process.listen("bee.tests.hook.ready", {message = true}))
            local executor = funcs.new():with_actor(security.new_actor("memory-fixture-host", {workspace_id = host.WORKSPACE}))
            local request = {session_ref = session.session, thread_id = session.thread, workspace_id = host.WORKSPACE,
                point = "tool.before", occurrence_id = harness.key(), input = {text = "seed", mode = "held_change", controller = tostring(process.pid())}}
            local first = assert(executor:async("bee.threads.hooks:dispatch", request))
            local message = assert((ready:receive()))
            local held = assert(bounds.object(message:payload():data()))
            local waiting = assert(events.subscribe("bee.session.hook/" .. assert(bounds.id(held.invocation_id)), "waiting"))
            local second = assert(executor:async("bee.threads.hooks:dispatch", request))
            channel.select({assert(second:response()):case_receive(), waiting:channel():case_receive()})
            assert(process.send(assert(bounds.id(held.pid)), "bee.tests.hook.release", {}))
            for _, future in ipairs({first, second}) do
                if not future:is_complete() then assert(future:response()):receive() end
                local value, err = future:result()
                test.is_nil(err)
                local reply = host.value(assert(value):data())
                test.eq(assert(bounds.object(reply.input)).text, "seed:a:b")
            end
            waiting:close()
            process.unlisten(ready)
        end)
    end)
end
return test.run_cases(define_tests)
