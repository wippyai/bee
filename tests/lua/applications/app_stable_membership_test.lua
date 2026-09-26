-- MIT. An app follows the runs it launched across restarts: it launches a
-- run thread, closes, reopens as a new instance, reads the run status and
-- steers the run. Another app in the same workspace is refused, and after
-- the app is uninstalled its stable family is fenced out of every thread.
local test = require("test")
local process = require("process")
local channel = require("channel")
local security = require("security")
local funcs = require("funcs")
local time = require("time")
local registry = require("registry")
local appearance = require("appearance")
local ADMISSION_ID = "bee.security:application_admission"
local DEFINITION = "bee.harness.window:app"
local OTHER_DEFINITION = "bee.apps:welcome"
local RUN_THREAD = "stable-run-thread"
local ATTEMPT = "stable-run-attempt-1"
local BACKEND = "bee.harness.launch:agent_call_backend"
local LAUNCH_SCOPE = "bee.harness.launch:agent_launch_execution_scope"
local THREADS_POLICY = "bee.security.threads:thread_authority_client_policy"
local WORKSPACE = string.rep("a", 32)

local function unwrap(raw: unknown): {[string]: unknown}
    local reply = raw :: {[string]: unknown}
    if reply.ok ~= true then
        local fault = (reply.error :: {[string]: unknown}?) or {}
        error("call failed: " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return reply.value :: {[string]: unknown}
end

local CREATE_POLICY = "bee.security.threads:thread_create_policy"
local function as_app(instance_id: string, target: string, request: unknown): {[string]: unknown}
    local actor = assert(security.new_actor("bee.application:" .. WORKSPACE .. ":" .. instance_id))
    local policy = assert(security.policy(THREADS_POLICY))
    local create_policy = assert(security.policy(CREATE_POLICY))
    local executor = assert(funcs.new():with_actor(actor):with_scope(security.new_scope({policy, create_policy})))
    local raw, call_error = executor:call(target, request)
    if call_error then error(target .. ": " .. tostring(call_error)) end
    return unwrap(raw)
end

local function run_status(instance_id: string): {[string]: unknown}
    local scope = assert(security.named_scope(LAUNCH_SCOPE))
    local actor = assert(security.new_actor("bee.application:" .. WORKSPACE .. ":" .. instance_id))
    local executor = assert(funcs.new():with_actor(actor):with_scope(scope))
    local raw, call_error = executor:call(BACKEND, {operation = "status", thread_id = RUN_THREAD, attempt_id = ATTEMPT})
    if call_error then error("run status: " .. tostring(call_error)) end
    return unwrap(raw)
end

local function app_code(instance_id: string, target: string, request: unknown): string
    local actor = assert(security.new_actor("bee.application:" .. WORKSPACE .. ":" .. instance_id))
    local policy = assert(security.policy(THREADS_POLICY))
    local executor = assert(funcs.new():with_actor(actor):with_scope(security.new_scope({policy})))
    local raw, call_error = executor:call(target, request)
    if call_error then error(target .. ": " .. tostring(call_error)) end
    local reply = raw :: {[string]: unknown}
    assert(reply.ok ~= true, target .. " unexpectedly succeeded")
    return tostring((reply.error :: {[string]: unknown}).code)
end

local function run_code(instance_id: string): string?
    local scope = assert(security.named_scope(LAUNCH_SCOPE))
    local actor = assert(security.new_actor("bee.application:" .. WORKSPACE .. ":" .. instance_id))
    local executor = assert(funcs.new():with_actor(actor):with_scope(scope))
    local raw, call_error = executor:call(BACKEND, {operation = "status", thread_id = RUN_THREAD, attempt_id = ATTEMPT})
    if call_error then error("run status: " .. tostring(call_error)) end
    local reply = raw :: {[string]: unknown}
    if reply.ok == true then return nil end
    return tostring((reply.error :: {[string]: unknown}).code)
end

local function set_admission(admitted: boolean)
    local snap = registry.snapshot()
    local record = assert(snap:get(ADMISSION_ID)) :: {[string]: unknown}
    local data = (record.data :: {[string]: unknown}?) or {}
    local bindings = {}
    for _, raw in ipairs((data.bindings :: {unknown}?) or {}) do
        local binding = raw :: {[string]: unknown}
        if admitted or binding.definition_id ~= DEFINITION then bindings[#bindings + 1] = binding end
    end
    local changes = snap:changes()
    changes:update({id = ADMISSION_ID, kind = "registry.entry", meta = record.meta, data = {bindings = bindings}})
    local applied, apply_error = changes:apply()
    if not applied then error("apply application admission: " .. tostring(apply_error)) end
end

local function define_tests()
    test.describe("Application stable membership", function()
        test.it("follows its runs across restarts and loses them on uninstall", function()
            local owner = tostring(process.pid())
            local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
            local replies = assert(process.listen("bee.app.reply", {message = true}))
            local broker_pid, broker_error = process.with_context({["bee.workspace_owner"] = owner,
                ["bee.workspace_id"] = WORKSPACE}):with_scope(security.new_scope({assert(security.policy("bee.security.desktop:broker_policy")),
                assert(security.policy("bee.security:core_spawn_boundary"))}))
                :spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults())
            if not broker_pid then error("broker spawn failed: " .. tostring(broker_error)) end
            local broker = tostring(broker_pid)
            assert(catalogs:receive():from() == broker)
            local function open(definition_id: string, tag: string): (string, string)
                local request_id = tag .. "-open"
                assert(process.send(broker, "bee.app.request", {version = 1, request_id = request_id, op = "open",
                    workspace_id = WORKSPACE, thread_id = "open-membership-thread", definition_id = definition_id,
                    arguments = {}}))
                local deadline = time.after("30s")
                while true do
                    local received = channel.select({replies:case_receive(), deadline:case_receive()})
                    assert(received.ok and received.channel == replies, tag .. " open reply timed out")
                    local message = received.value
                    if tostring(message:from()) == broker then
                        local data: unknown = message:payload():data()
                        if type(data) == "table" then
                            local reply = data :: {[string]: unknown}
                            if reply.request_id == request_id and reply.op == "open" then
                                assert(reply.error_code == "", tag .. " did not become ready: " .. tostring(reply.error))
                                return tostring(reply.instance_id), tostring(reply.id)
                            end
                        end
                    end
                end
            end
            local function close(view_id: unknown)
                local request_id = tostring(view_id) .. "-close"
                assert(process.send(broker, "bee.app.request", {version = 1, request_id = request_id, op = "close",
                    workspace_id = WORKSPACE, id = tostring(view_id)}))
                local deadline = time.after("30s")
                while true do
                    local received = channel.select({replies:case_receive(), deadline:case_receive()})
                    assert(received.ok and received.channel == replies, request_id .. " timed out")
                    local message = received.value
                    if tostring(message:from()) == broker then
                        local data: unknown = message:payload():data()
                        if type(data) == "table" then
                            local reply = data :: {[string]: unknown}
                            if reply.request_id == request_id and reply.op == "close" then
                                assert(reply.error_code == "", request_id .. " failed: " .. tostring(reply.error))
                                return
                            end
                        end
                    end
                end
            end
            local launched, launch_error = funcs.call("bee.threads.service:create",
                {thread_id = "open-membership-thread", idempotency_key = "open-membership-thread-create", title = "Open membership"})
            if launch_error then error("create launch thread: " .. tostring(launch_error)) end
            unwrap(launched)
            local first, first_view = open(DEFINITION, "stable-view-1")
            local created = as_app(first, "bee.threads.service:create",
                {thread_id = RUN_THREAD, idempotency_key = RUN_THREAD .. "-create", title = "Stable run"})
            test.eq(created.thread_id, RUN_THREAD)
            test.eq(run_status(first).state, "starting")
            close(first_view)
            local second, _ = open(DEFINITION, "stable-view-2")
            test.eq(run_status(second).state, "starting")
            local steered = as_app(second, "bee.threads.service:record",
                {thread_id = RUN_THREAD, idempotency_key = "stable-steer-1", kind = "message",
                    body = {message_id = "stable-steer-1", message_kind = "progress",
                        recipient_ids = {}, content = {text = "continue"}}})
            test.eq(steered.sequence, 1)
            local reread = as_app(second, "bee.threads.service:read_after",
                {thread_id = RUN_THREAD, cursor = 0, limit = 8})
            test.eq(#(reread.records :: {unknown}), 1)
            local other, _ = open(OTHER_DEFINITION, "stable-view-3")
            test.eq(run_code(other), "DENIED")
            test.eq(app_code(other, "bee.threads.service:get", {thread_id = RUN_THREAD}), "DENIED")
            set_admission(false)
            local function revoked_refused()
                local deadline = time.after("15s")
                while true do
                    if run_code(second) == "DENIED" then break end
                    local tick = channel.select({deadline:case_receive(), time.after("200ms"):case_receive()})
                    assert(tick.ok and tick.channel ~= deadline, "revoked app kept its runs")
                end
                test.eq(app_code(second, "bee.threads.service:record",
                    {thread_id = RUN_THREAD, idempotency_key = "stable-steer-2", kind = "message",
                        body = {message_id = "stable-steer-2", message_kind = "progress",
                            recipient_ids = {}, content = {text = "after revoke"}}}), "DENIED")
            end
            local fenced_ok, fence_error = pcall(revoked_refused)
            set_admission(true)
            assert(fenced_ok, fence_error)
            process.cancel(broker)
        end)
    end)
end

return test.run_cases(define_tests)
