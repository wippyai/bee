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
    activations: Channel<process.Message>, switches: Channel<process.Message>, events: Channel<process.Event>, folder: string, leased: string,
    unused: {Channel<process.Message>}}

local function harness(tag: string): Harness
    local self = tostring(process.pid())
    local events = assert(process.events())
    local requests, replies = listen("bee.test.standin.request"), listen("bee.test.standin.reply")
    local received = listen("bee.test.retained.received")
    local ready, results, activations = listen("bee.retained.ready"), listen("bee.retained.result"), listen("bee.retained.activated")
    local switches = listen("bee.retained.switch")
    local unused = listen("bee.test.desktop_workspaces." .. tag)
    -- The bridge monitors its clients itself, so the test does not.
    local standin = tostring(assert(process.spawn("bee.hive:display_standin", "bee.hive_host.desktop:display_host", self)))
    local folder = tostring(assert(process.spawn_monitored("bee.hive:retained_standin", "bee:workers", self)))
    local leased = tostring(assert(process.spawn_monitored("bee.hive:retained_standin", "bee:workers", self)))
    local client_node = types.pid_parts(standin)
    if not client_node then error("stand-in has no node") end
    local folder_served: owner.Served = {supervisor = folder, workspace_id = FOLDER, desktop_id = DEFAULT_DISPLAY, folder = true, ready = true}
    local leased_served: owner.Served = {supervisor = leased, workspace_id = LEASED, desktop_id = "", folder = false, ready = false}
    local state: owner.State = {
        bridge_name = "bee.retained.bridge/" .. string.rep("0", 32), owner_name = "bee.retained.owner/" .. string.rep("0", 32), stopped = false, node = NODE,
        allowed = {}, allowed_peers = {}, enrolled = {[client_node] = true}, peers = {}, config = {execution = EXECUTION, expires_at = "2099-01-01T00:00:00.000Z", allowed_nodes = {}, allowed_peers = {}, local_clients = true, folder = true},
        ready = ready, results = results, copies = unused, launches = unused, activations = activations, observers = unused, switches = switches, retiring = {},
        catalog = catalog.new(), spawn_scope = security.new_scope({}), executor = funcs.new(), folder = folder_served,
        served = {[folder] = folder_served, [leased] = leased_served}, workspaces = {[FOLDER] = folder_served, [LEASED] = leased_served}, served_count = 1,
        clients = {}, receipts = {}, client_count = 0, receipt_count = 0, expires_at = time.now():add("1h"),
    }
    return {state = state, standin = standin, requests = requests, replies = replies, received = received, ready = ready, results = results,
        activations = activations, switches = switches, events = events, folder = folder, leased = leased, unused = {unused}}
end
local function close(h: Harness)
    for _, pid in ipairs({h.standin, h.folder, h.leased}) do process.terminate(pid) end
    for _, subscription in ipairs({h.requests, h.replies, h.received, h.ready, h.results, h.activations, h.switches}) do process.unlisten(subscription) end
    for _, subscription in ipairs(h.unused) do process.unlisten(subscription) end
end
-- The stand-in sends one call as the native client; the bridge admits it.
local function send_call(h: Harness, operation: string, key: string, input: Object)
    process.send(h.standin, "bee.test.standin.call", {protocol_revision = types.REVISION, request_id = key, idempotency_key = key,
        owner_ref = {node_id = NODE, service_id = protocol.SERVICE}, target = {operation_ref = operation}, input = input,
        deadline = time.now():add("20s"):utc():format(FORMAT)})
    owner.request(h.state, next_message(h.requests, "stand-in call"), 1)
end
local function request(h: Harness, operation: string, key: string, input: Object)
    input.owner_execution = EXECUTION
    send_call(h, operation, key, input)
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
-- Attach the stand-in with control to the folder workspace's display.
local function attach_folder(h: Harness): Object
    request(h, protocol.ATTACH, "attach-folder", {workspace_id = FOLDER, desktop_id = DISPLAY, mode = "control"})
    local activation = asked(h, "bee.retained.activate")
    send_as(h.folder, "bee.retained.activated", {version = 1, workspace_id = FOLDER, desktop_id = DISPLAY,
        request_id = activation.request_id, error_code = "", error = ""})
    owner.activated(h.state, next_message(h.activations, "folder activation"), 1)
    local attach = asked(h, "bee.retained.request")
    send_as(h.folder, "bee.retained.result", {version = 1, workspace_id = FOLDER, desktop_id = DISPLAY,
        request_id = attach.request_id, mount = "folder-mount", error_code = "", error = ""})
    owner.result(h.state, next_message(h.results, "folder attach result"), 1)
    local attached = answer(h)
    if not attached.ok then error(tostring(attached.error and attached.error.message)) end
    return attached.value :: Object
end
-- The folder workspace's supervisor asks the bridge to show another workspace
-- on the display, as its display did.
local function ask_switch(h: Harness, request_id: string, target: string)
    send_as(h.folder, "bee.retained.switch", {version = 1, workspace_id = FOLDER, desktop_id = DISPLAY,
        request_id = request_id, target_workspace_id = target})
    owner.switch(h.state, next_message(h.switches, "switch request"), 1)
end
-- The leased workspace's supervisor becomes ready and admits the display.
local function admit_leased(h: Harness, activation_error: string?): Object
    send_as(h.leased, "bee.retained.ready", {version = 1, workspace_id = LEASED, desktop_id = DEFAULT_DISPLAY})
    owner.ready(h.state, next_message(h.ready, "leased readiness"), 1)
    local activation = asked(h, "bee.retained.activate")
    test.eq(activation.workspace_id, LEASED)
    test.eq(activation.desktop_id, DISPLAY)
    send_as(h.leased, "bee.retained.activated", {version = 1, workspace_id = LEASED, desktop_id = DISPLAY,
        request_id = activation.request_id, error_code = activation_error and "UNAVAILABLE" or "", error = activation_error or ""})
    owner.activated(h.state, next_message(h.activations, "leased activation"), 1)
    return activation
end
local function current(h: Harness): types.Reply
    request(h, protocol.CURRENT, "current-" .. tostring(time.now():unix_nano()), {})
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
        test.it("lists for a client that learns the owner execution from the listing", function()
            local h = harness("discover")
            send_call(h, protocol.LIST, "list-1", {limit = 1})
            silent(h.replies, "refusal of a listing that names no owner execution")
            test.not_nil(h.state.catalog.pending, "the listing did not start")
            send_call(h, protocol.LIST, "list-2", {owner_execution = string.rep("f", 32), limit = 1})
            local stale = answer(h)
            test.eq(stale.error and stale.error.code, "DENIED")
            send_call(h, protocol.ATTACH, "attach-0", {workspace_id = LEASED, desktop_id = DISPLAY, mode = "control"})
            local unnamed = answer(h)
            test.eq(unnamed.error and unnamed.error.code, "INVALID_ARGUMENT")
            close(h)
        end)
        test.it("moves a display's controller to another workspace and releases the folder's grant", function()
            local h = harness("move")
            local first = attach_folder(h)
            ask_switch(h, "switch-1", LEASED)
            silent(h.received, "a request before the target workspace's supervisor is ready")
            admit_leased(h, nil)
            local attach = asked(h, "bee.retained.request")
            test.eq(attach.op, "attach")
            test.eq(attach.workspace_id, LEASED)
            test.eq(attach.mode, "control")
            test.eq(attach.recipient, h.standin)
            send_as(h.leased, "bee.retained.result", {version = 1, workspace_id = LEASED, desktop_id = DISPLAY,
                request_id = attach.request_id, mount = "leased-mount", error_code = "", error = ""})
            owner.result(h.state, next_message(h.results, "switch attach result"), 1)
            local switched = asked(h, "bee.retained.switched")
            test.eq(switched.request_id, "switch-1")
            test.eq(switched.workspace_id, FOLDER)
            test.eq(switched.error_code, "")
            -- The folder workspace keeps serving; only the client's grant there ends.
            local release = asked(h, "bee.retained.request")
            test.eq(release.op, "detach")
            test.eq(release.workspace_id, FOLDER)
            test.eq(release.recipient, h.standin)
            silent(h.replies, "a reply to the native client for the switch")
            send_as(h.folder, "bee.retained.result", {version = 1, workspace_id = FOLDER, desktop_id = DISPLAY,
                request_id = release.request_id, mount = "", error_code = "", error = ""})
            owner.result(h.state, next_message(h.results, "folder release result"), 1)
            silent(h.replies, "a reply to the native client for the release")
            test.is_nil(next(h.state.retiring))
            local now = current(h)
            if not now.ok then error(tostring(now.error and now.error.message)) end
            local value = now.value :: Object
            test.eq(value.workspace_id, LEASED)
            test.eq(value.desktop_id, DISPLAY)
            test.eq(value.mount_ref, "leased-mount")
            test.eq(value.mode, "control")
            test.neq(value.session_id, first.session_id)
            test.not_nil(h.state.workspaces[FOLDER])
            request(h, protocol.DETACH, "detach-old", {workspace_id = FOLDER, desktop_id = DISPLAY, session_id = first.session_id})
            local stale = answer(h)
            test.is_false(stale.ok)
            close(h)
        end)
        test.it("keeps the display on its workspace when the target refuses it", function()
            local h = harness("revert")
            local first = attach_folder(h)
            ask_switch(h, "switch-2", LEASED)
            admit_leased(h, "the workspace refused the display")
            local switched = asked(h, "bee.retained.switched")
            test.eq(switched.request_id, "switch-2")
            test.eq(switched.error_code, "UNAVAILABLE")
            silent(h.received, "a release of the folder's grant after a refused switch")
            local now = current(h)
            local value = now.value :: Object
            test.eq(value.workspace_id, FOLDER)
            test.eq(value.session_id, first.session_id)
            test.eq(value.mount_ref, "folder-mount")
            -- The target workspace had no other client: its supervisor stopped.
            test.is_nil(h.state.workspaces[LEASED])
            test.eq(h.state.served_count, 0)
            close(h)
        end)
        test.it("refuses a switch with no controlling client or to the same workspace", function()
            local h = harness("refuse")
            ask_switch(h, "switch-3", LEASED)
            local none = asked(h, "bee.retained.switched")
            test.eq(none.error_code, "NOT_FOUND")
            attach_folder(h)
            ask_switch(h, "switch-4", FOLDER)
            local same = asked(h, "bee.retained.switched")
            test.eq(same.error_code, "INVALID_ARGUMENT")
            -- A refused switch starts no supervisor and stops none.
            test.eq(h.state.served_count, 1)
            close(h)
        end)
        test.it("serves no catalog-reader operation and admits no local application sender", function()
            local h = harness("catalog")
            request(h, "bee.desktop:catalog", "catalog-1", {})
            local refused = answer(h)
            test.eq(refused.error and refused.error.code, "INVALID_ARGUMENT")
            local self = tostring(process.pid())
            local own = listen("bee.test.desktop_workspaces.local")
            process.send(self, "bee.test.desktop_workspaces.local", {})
            test.is_false(owner.handles(h.state, next_message(own, "local sender")))
            process.unlisten(own)
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
