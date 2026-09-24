-- MIT. The desktop bridge serves several workspaces: a client attaching to a
-- leased workspace waits for that workspace's supervisor, every answer is
-- routed by the supervisor that sent it, the workspace's last detach stops
-- its supervisor (releasing its host lease), and a leased supervisor that
-- exits ends only its own sessions.
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local security = require("security")
local funcs = require("funcs")
local types = require("types")
local owner = require("owner")
local catalog = require("catalog")
local protocol = require("protocol")
type Channel = channel.Channel
type Object = {[string]: unknown}
local EXECUTION = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
local FOLDER = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local LEASED = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
local DEFAULT_DISPLAY = "cccccccccccccccccccccccccccccccc"
local DISPLAY = "dddddddddddddddddddddddddddddddd"
local NODE = "owner-node"
local FORMAT = "2006-01-02T15:04:05.000Z07:00"

local function listen(topic: string): Channel<process.Message>
    local messages, err = process.listen(topic, {message = true})
    if not messages then error(tostring(err)) end
    return messages
end
local function next_message(messages: Channel<process.Message>, what: string): process.Message
    local selected = channel.select({messages:case_receive(), time.after("3s"):case_receive()})
    if not selected.ok or selected.channel ~= messages then error("missing " .. what) end
    return selected.value
end
local function silent(messages: Channel<process.Message>, what: string)
    local selected = channel.select({messages:case_receive(), time.after("200ms"):case_receive()})
    if selected.channel == messages then
        local reply = types.decode_reply(selected.value:payload():data())
        error("unexpected " .. what .. ": " .. tostring(reply and reply.error and (reply.error.code .. " " .. reply.error.message)))
    end
end
type Harness = {state: owner.State, standin: string, requests: Channel<process.Message>, replies: Channel<process.Message>,
    received: Channel<process.Message>, ready: Channel<process.Message>, results: Channel<process.Message>,
    activations: Channel<process.Message>, events: Channel<process.Event>, folder: string, leased: string, unused: {Channel<process.Message>}}

local function harness(tag: string): Harness
    local self = tostring(process.pid())
    local events = assert(process.events())
    local requests, replies = listen("bee.test.standin.request"), listen("bee.test.standin.reply")
    local received = listen("bee.test.retained.received")
    local ready, results, activations = listen("bee.retained.ready"), listen("bee.retained.result"), listen("bee.retained.activated")
    local unused = listen("bee.test.desktop_workspaces." .. tag)
    -- The bridge monitors its clients itself, so the test does not.
    local standin = tostring(assert(process.spawn("bee.hive:display_standin", "bee.hive.desktop:display_host", self)))
    local folder = tostring(assert(process.spawn_monitored("bee.hive:retained_standin", "bee:workers", self)))
    local leased = tostring(assert(process.spawn_monitored("bee.hive:retained_standin", "bee:workers", self)))
    local client_node = types.pid_parts(standin)
    if not client_node then error("stand-in has no node") end
    local folder_served: owner.Served = {supervisor = folder, workspace_id = FOLDER, desktop_id = DEFAULT_DISPLAY, folder = true, ready = true,
        catalog_readers = {}, pending_catalog_readers = nil}
    local leased_served: owner.Served = {supervisor = leased, workspace_id = LEASED, desktop_id = "", folder = false, ready = false,
        catalog_readers = {}, pending_catalog_readers = nil}
    local state: owner.State = {
        bridge_name = "bee.retained.bridge/" .. string.rep("0", 32), owner_name = "bee.retained.owner/" .. string.rep("0", 32), stopped = false, node = NODE,
        allowed = {}, enrolled = {[client_node] = true}, config = {execution = EXECUTION, expires_at = "2099-01-01T00:00:00.000Z", allowed_nodes = {}, local_clients = true},
        ready = ready, results = results, copies = unused, launches = unused, activations = activations, reader_updates = unused, observers = unused,
        catalog = catalog.new(), spawn_scope = security.new_scope({}), executor = funcs.new(), folder = folder_served,
        served = {[folder] = folder_served, [leased] = leased_served}, workspaces = {[FOLDER] = folder_served, [LEASED] = leased_served}, served_count = 1,
        clients = {}, receipts = {}, client_count = 0, receipt_count = 0, expires_at = time.now():add("1h"),
    }
    return {state = state, standin = standin, requests = requests, replies = replies, received = received, ready = ready, results = results,
        activations = activations, events = events, folder = folder, leased = leased, unused = {unused}}
end
local function close(h: Harness)
    for _, pid in ipairs({h.standin, h.folder, h.leased}) do process.terminate(pid) end
    for _, subscription in ipairs({h.requests, h.replies, h.received, h.ready, h.results, h.activations}) do process.unlisten(subscription) end
    for _, subscription in ipairs(h.unused) do process.unlisten(subscription) end
end
-- The stand-in sends one call as the native client; the bridge admits it.
local function request(h: Harness, operation: string, key: string, input: Object)
    input.owner_execution = EXECUTION
    process.send(h.standin, "bee.test.standin.call", {protocol_revision = types.REVISION, request_id = key, idempotency_key = key,
        owner_ref = {node_id = NODE, service_id = protocol.SERVICE}, target = {operation_ref = operation}, input = input,
        deadline = time.now():add("20s"):utc():format(FORMAT)})
    owner.request(h.state, next_message(h.requests, "stand-in call"), 1)
end
local function answer(h: Harness): types.Reply
    local reply = types.decode_reply(next_message(h.replies, "bridge reply"):payload():data())
    if not reply then error("invalid bridge reply") end
    return reply
end
local function asked(h: Harness, topic: string): Object
    local message = next_message(h.received, topic)
    local data = message:payload():data() :: Object
    test.eq(data.topic, topic)
    return data.value :: Object
end
local function send_as(supervisor: string, topic: string, value: Object)
    process.send(supervisor, "bee.test.retained.send", {topic = topic, value = value})
end
-- Attach the stand-in to the leased workspace through its readiness,
-- activation and admission.
local function attach_leased(h: Harness): types.Reply
    request(h, protocol.ATTACH, "attach-1", {workspace_id = LEASED, desktop_id = DISPLAY, mode = "control"})
    silent(h.replies, "answer while the leased supervisor starts")
    silent(h.received, "request before the leased supervisor is ready")
    send_as(h.leased, "bee.retained.ready", {version = 1, workspace_id = LEASED, desktop_id = DEFAULT_DISPLAY})
    owner.ready(h.state, next_message(h.ready, "leased readiness"), 1)
    local activation = asked(h, "bee.retained.activate")
    test.eq(activation.workspace_id, LEASED)
    test.eq(activation.desktop_id, DISPLAY)
    send_as(h.leased, "bee.retained.activated", {version = 1, workspace_id = LEASED, desktop_id = DISPLAY,
        request_id = activation.request_id, error_code = "", error = ""})
    owner.activated(h.state, next_message(h.activations, "activation"), 1)
    local attach = asked(h, "bee.retained.request")
    test.eq(attach.op, "attach")
    test.eq(attach.recipient, h.standin)
    -- The folder supervisor answering the same request identity settles nothing.
    send_as(h.folder, "bee.retained.result", {version = 1, workspace_id = LEASED, desktop_id = DISPLAY,
        request_id = attach.request_id, mount = "forged-mount", error_code = "", error = ""})
    owner.result(h.state, next_message(h.results, "forged result"), 1)
    silent(h.replies, "reply to a result from another workspace's supervisor")
    send_as(h.leased, "bee.retained.result", {version = 1, workspace_id = LEASED, desktop_id = DISPLAY,
        request_id = attach.request_id, mount = "leased-mount", error_code = "", error = ""})
    owner.result(h.state, next_message(h.results, "attach result"), 1)
    return answer(h)
end
local function define_tests()
    test.describe("Desktop bridge workspaces", function()
        test.it("attaches a leased workspace after its supervisor is ready and stops it on the last detach", function()
            local h = harness("detach")
            local attached = attach_leased(h)
            if not attached.ok then error(tostring(attached.error and attached.error.message)) end
            local value = attached.value :: Object
            test.eq(value.workspace_id, LEASED)
            test.eq(value.mount_ref, "leased-mount")
            test.is_true(owner.serves(h.state, LEASED))
            request(h, protocol.DETACH, "detach-1", {workspace_id = LEASED, desktop_id = DISPLAY, session_id = value.session_id})
            local detach = asked(h, "bee.retained.request")
            test.eq(detach.op, "detach")
            send_as(h.leased, "bee.retained.result", {version = 1, workspace_id = LEASED, desktop_id = DISPLAY,
                request_id = detach.request_id, mount = "", error_code = "", error = ""})
            owner.result(h.state, next_message(h.results, "detach result"), 1)
            local detached = answer(h)
            test.is_true(detached.ok)
            test.eq((detached.value :: Object).detached, true)
            test.is_nil(h.state.clients[h.standin])
            test.is_nil(h.state.workspaces[LEASED])
            test.eq(h.state.served_count, 0)
            test.not_nil(h.state.workspaces[FOLDER], "the folder workspace stopped with a leased one")
            local deadline = time.after("3s")
            while true do
                local selected = channel.select({h.events:case_receive(), deadline:case_receive()})
                if selected.channel == deadline then error("the leased supervisor was not stopped") end
                local event = selected.value
                if event.kind == process.event.EXIT and tostring(event.from) == h.leased then break end
            end
            close(h)
        end)
        test.it("attaches a Hive display client from an admitted node to a workspace by identity", function()
            local h = harness("remote")
            -- The client's node is admitted by the host grant, not local enrollment.
            local node = types.pid_parts(h.standin)
            if not node then error("stand-in has no node") end
            h.state.enrolled = {}
            h.state.config.local_clients = false
            h.state.config.allowed_nodes = {node}
            h.state.allowed = {[node] = true}
            local attached = attach_leased(h)
            test.is_true(attached.ok)
            test.eq((attached.value :: Object).workspace_id, LEASED)
            close(h)
        end)
        test.it("refuses to switch workspaces without a detach", function()
            local h = harness("switch")
            local attached = attach_leased(h)
            test.is_true(attached.ok)
            request(h, protocol.ATTACH, "attach-2", {workspace_id = FOLDER, desktop_id = DISPLAY, mode = "control"})
            local refused = answer(h)
            test.eq(refused.error and refused.error.code, "CONFLICT")
            close(h)
        end)
        test.it("ends only the sessions of a leased workspace whose supervisor exits", function()
            local h = harness("exit")
            request(h, protocol.ATTACH, "attach-3", {workspace_id = LEASED, desktop_id = DISPLAY, mode = "control"})
            process.terminate(h.leased)
            local deadline = time.after("3s")
            while true do
                local selected = channel.select({h.events:case_receive(), deadline:case_receive()})
                if selected.channel == deadline then error("the leased supervisor did not exit") end
                local event = selected.value
                if event.kind == process.event.EXIT and tostring(event.from) == h.leased then
                    owner.event(h.state, event, 1)
                    break
                end
            end
            local ended = answer(h)
            test.eq(ended.error and ended.error.code, "UNAVAILABLE")
            test.is_nil(h.state.clients[h.standin])
            test.is_nil(h.state.workspaces[LEASED])
            test.not_nil(h.state.workspaces[FOLDER])
            process.terminate(h.folder)
            local stopped = time.after("3s")
            while true do
                local selected = channel.select({h.events:case_receive(), stopped:case_receive()})
                if selected.channel == stopped then error("the folder supervisor did not exit") end
                local event = selected.value
                if event.kind == process.event.EXIT and tostring(event.from) == h.folder then
                    test.is_false(pcall(owner.event, h.state, event, 1), "the folder supervisor's exit was not fatal")
                    break
                end
            end
            close(h)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
