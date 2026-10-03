-- SPDX-License-Identifier: MIT
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local funcs = require("funcs")
local security = require("security")
local store = require("store")
local request = require("request")
local json = require("json")
local principals = require("principals")
local decode = require("decode")
local registry = require("registry")
local counter = 0
local OWNER = "bee.test.startup"
local function state(id: string)
    local db = assert(store.open())
    local attempt = assert(store.attempt(db, id))
    db:release()
    return attempt
end
local function begin(mode: string)
    counter = counter + 1
    local id = "startup-" .. tostring(time.now():unix_nano()) .. "-" .. tostring(counter)
    local launch = assert(request.decode({idempotency_key = id, owner_id = OWNER, owner_incarnation = 1,
        action_id = id, attempt_id = id, binding_ref = "bee.placement.native:fixture_agent_binding",
        policy_ref = "bee.placement.native:test_launch_policy_without_provider", profile_id = "batch",
        binding_digest = string.rep("a", 64), profile_digest = string.rep("a", 64),
        launch = {executable = "sh", argv = {mode}, environment = {}, working_directory_ref = "project", readiness = "none"},
        resources = {{name = "project", grant_ref = "grant-1", root_ref = "bee.placement.native:project_fixture", subpath = "", access = "write", purpose = "project"}},
        environment = {}, required_cleanup = "direct_process", required_exit_observation = "eof_gated"}))
    launch.delivery = {arguments = {}, files = {}}
    local db = assert(store.open())
    assert(store.intend(db, launch, assert(request.digest(launch)), assert(json.encode(launch)),
        {capability = "direct_process", exit_observation = "eof_gated"}, nil, nil).ok)
    assert(store.transition(db, id, {fields = {recipient = process.pid(), attachment_generation = 1}, evidence = {kind = "test.attached", detail = "controllable runner"}}).ok)
    db:release()
    local client = funcs.new():with_actor(principals.actor(OWNER)):with_scope(security.new_scope({assert(security.policy("bee.placement.native:client_test_policy"))}))
    local future = assert(client:async("bee.placement.native:fixture_start_unacknowledged", {attempt_id = id}))
    local deadline = time.after("2s")
    local selected = channel.select({future:response():case_receive(), deadline:case_receive()})
    assert(selected.ok and selected.channel ~= deadline, "start blocked waiting for runner acknowledgement")
    local payload, err = future:result()
    assert(not err, tostring(err))
    local reply = principals.reply(assert(payload):data())
    assert(reply.ok, tostring(reply.error and reply.error.message))
    local attempt = assert(decode.attempt(reply.value))
    test.eq(attempt.execution_state, "starting")
    return id, assert(attempt.runner)
end
local function await_state(id: string, expected: string)
    local deadline = time.after("3s")
    while true do
        local attempt = state(id)
        if attempt.execution_state == expected then return attempt end
        local tick = time.after("10ms")
        local selected = channel.select({tick:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel ~= deadline, "state remained " .. attempt.execution_state .. "; expected " .. expected)
    end
end
local function run()
    test.describe("Monitored asynchronous startup", function()
        test.it("returns starting while a controllable runner waits and later acknowledges", function()
            local id, runner = begin("slow")
            test.eq(state(id).execution_state, "starting")
            assert(process.send(runner, "bee.test.startup.advance", {}))
            test.eq(await_state(id, "running").start_failure, nil)
            process.terminate(runner)
        end)
        test.it("waits for the stdin closure acknowledgement while the live runner holds it", function()
            local held = assert(process.listen("bee.test.closure.held", {message = true}))
            local id, runner = begin("closure")
            assert(process.send(runner, "bee.test.startup.advance", {}))
            await_state(id, "running")
            local client = funcs.new():with_actor(principals.actor(OWNER)):with_scope(security.new_scope({assert(security.policy("bee.placement.native:client_test_policy"))}))
            local closing = assert(client:with_context({["bee.test.stdin.expired"] = true}):async("bee.placement.native.binding:close_stdin", {attempt_id = id}))
            local selected = channel.select({held:case_receive(), closing:response():case_receive()})
            if selected.channel == held then
                assert(tostring(selected.value:from()) == runner)
                assert(process.send(runner, "bee.test.startup.advance", {}))
                assert(closing:response():receive())
            end
            local payload, err = closing:result()
            assert(not err, tostring(err))
            local reply = principals.reply(assert(payload):data())
            assert(reply.ok, tostring(reply.error and reply.error.message))
            test.eq(assert(decode.stdin_closure(reply.value, id)).closed, true)
            process.unlisten(held)
            process.terminate(runner)
        end)
        test.it("cancels during starting and records a late acknowledgement without reviving the attempt", function()
            local id, runner = begin("cancel")
            local client = funcs.new():with_actor(principals.actor(OWNER)):with_scope(security.new_scope({assert(security.policy("bee.placement.native:client_test_policy"))}))
            local raw, err = client:call("bee.placement.native.binding:stop", {attempt_id = id})
            assert(not err, tostring(err))
            assert(principals.reply(raw).ok)
            await_state(id, "exited")
            assert(process.send(runner, "bee.test.startup.advance", {}))
            local deadline = time.after("3s")
            while true do
                local db = assert(store.open())
                local page = assert(store.evidence(db, id, 0, 64))
                db:release()
                local found = false
                for _, event in ipairs(page.evidence) do if event.kind == "runner.ack_late" then found = true end end
                if found then break end
                local tick = time.after("10ms")
                local selected = channel.select({tick:case_receive(), deadline:case_receive()})
                assert(selected.ok and selected.channel ~= deadline, "late acknowledgement disappeared")
            end
            test.eq(state(id).execution_state, "exited")
            test.is_true(state(id).start_cancelled)
            test.is_nil(state(id).start_failure)
            process.terminate(runner)
        end)
        test.it("records a runner exit before acknowledgement with its exact cause", function()
            local id, runner = begin("exit")
            assert(process.send(runner, "bee.test.startup.advance", {}))
            local failed = await_state(id, "start_failed")
            test.is_true(assert(failed.start_failure):find("fixture runner crashed before acknowledgement", 1, true) ~= nil)
        end)
        test.it("records a runner refusal without replacing its cause", function()
            local id, runner = begin("refuse")
            assert(process.send(runner, "bee.test.startup.advance", {}))
            test.eq(await_state(id, "start_failed").start_failure, "fixture daemon refused containers/create")
        end)
    end)
end
local cases = test.run_cases(run)
return {run = function(options)
    local mode = assert(registry.get("bee.placement.native.env:placement_resource_mode"))
    local original = mode.data
    mode.data = {mode = "host_configured"}
    local changes = registry.snapshot():changes(); changes:update(mode); assert(changes:apply())
    local ok, result = pcall(cases, options)
    mode.data = original
    local restore = registry.snapshot():changes(); restore:update(mode); assert(restore:apply())
    if not ok then error(result) end
    return result
end}
