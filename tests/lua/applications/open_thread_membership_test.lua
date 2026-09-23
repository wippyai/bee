-- MIT. A managed window app launched through the broker is admitted into its
-- launch thread. The broker's launch path, acting as the workspace owner that
-- owns the thread, joins the host-issued application principal
-- (bee.application:<workspace>:<instance>) as a participant before the app
-- starts, so the app's own admission and every later carrier commit can read
-- the thread it was launched for.
local test = require("test")
local process = require("process")
local channel = require("channel")
local security = require("security")
local funcs = require("funcs")
local time = require("time")
local appearance = require("appearance")

local WORKSPACE = string.rep("a", 32)
local THREAD = "open-membership-thread"
local DEFINITION = "bee.harness.window:app"

-- The threads authority answers either a bounded reply envelope or the
-- operation's own value; the probe reads both without inventing a result.
local function unwrap(reply: unknown): {[string]: unknown}
    local object = type(reply) == "table" and reply or nil
    if not object then error("call returned " .. type(reply)) end
    if object.ok == false then
        local fault = object.error :: {[string]: unknown}?
        error("call refused: " .. tostring(fault and fault.code) .. ": " .. tostring(fault and fault.message))
    end
    if object.ok == true then
        if type(object.value) ~= "table" then error("call returned no value") end
        return object.value :: {[string]: unknown}
    end
    return object
end

local function call(target: string, request: unknown): {[string]: unknown}
    local raw, call_error = funcs.call(target, request)
    if call_error then error(target .. ": " .. tostring(call_error)) end
    return unwrap(raw)
end

-- The application principal is host-derived from the trusted workspace and the
-- instance the broker reported; a caller cannot name it.
local function as_application(instance_id: string, target: string, request: unknown): {[string]: unknown}
    local actor = assert(security.new_actor("bee.application:" .. WORKSPACE .. ":" .. instance_id))
    local policy = assert(security.policy("bee:thread_authority_client_policy"))
    local executor = assert(funcs.new():with_actor(actor):with_scope(security.new_scope({policy})))
    local raw, call_error = executor:call(target, request)
    if call_error then error(target .. ": " .. tostring(call_error)) end
    return unwrap(raw)
end

local function define_tests()
    test.describe("Application open thread membership", function()
        test.it("admits the managed window principal into the thread the open names", function()
            call("bee.threads.service:create", {thread_id = THREAD,
                idempotency_key = THREAD .. "-create", title = "Open membership"})

            local owner = tostring(process.pid())
            local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
            local replies = assert(process.listen("bee.app.reply", {message = true}))
            local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner,
                ["bee.workspace_id"] = WORKSPACE}):with_scope(security.new_scope({assert(security.policy("bee:broker_policy")),
                assert(security.policy("bee:core_spawn_boundary"))}))
                :spawn_monitored("bee.applications:broker", "bee:workers", owner, appearance.defaults())))
            assert(catalogs:receive():from() == broker)

            local request_id = "open-membership-request"
            assert(process.send(broker, "bee.app.request", {version = 1, request_id = request_id, op = "open",
                workspace_id = WORKSPACE, thread_id = THREAD, definition_id = DEFINITION, arguments = {}}))
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
            assert(opened.error_code == "", "managed window did not become ready: " .. tostring(opened.error))
            local instance_id = assert(opened.instance_id) :: string

            local joined = as_application(instance_id, "bee.threads.service:get", {thread_id = THREAD})
            local member = assert(joined.membership) :: {[string]: unknown}
            test.eq(member.member_id, "bee.application:" .. WORKSPACE .. ":" .. instance_id)
            test.eq(member.role, "participant")
            test.is_true(member.active == true)
        end)
    end)
end
return test.run_cases(define_tests)
