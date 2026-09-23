-- MIT. Correlation and uncertainty checks for the asynchronous desktop catalog.
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local catalog = require("catalog")
local protocol = require("protocol")
local types = require("types")
type Channel = channel.Channel
local WORKSPACE = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local DESKTOP = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
local function request(id: string): types.Call
    local value = types.decode_call({protocol_revision = types.REVISION, request_id = id, idempotency_key = DESKTOP,
        owner_ref = {node_id = "fixture", service_id = protocol.SERVICE}, target = {operation_ref = protocol.CREATE}, input = {}})
    if not value then error("invalid test request") end
    return value
end
local function receive(replies: Channel<process.Message>): types.Reply
    local selected = channel.select({replies:case_receive(), time.after("1s"):case_receive()})
    if not selected.ok or selected.channel ~= replies then error("missing catalog response") end
    local reply = types.decode_reply(selected.value:payload():data())
    if not reply then error("invalid catalog response") end
    return reply
end
local function listen(): Channel<process.Message>
    local replies, err = process.listen(types.TOPIC_REPLY, {message = true})
    if not replies then error(tostring(err)) end
    return replies
end
local function define_tests()
    test.describe("Desktop catalog correlation", function()
        test.it("bounds pending work and does not let an expired reply retire its successor", function()
            local replies = listen()
            local self = tostring(process.pid())
            local state = catalog.new()
            catalog.request(state, self, WORKSPACE, self, request("old"), DESKTOP, 10)
            local old = state.pending
            if not old then error("request did not start") end
            catalog.request(state, self, WORKSPACE, self, request("busy"), DESKTOP, 20)
            local busy = receive(replies)
            test.is_false(busy.ok)
            test.eq(busy.error and busy.error.code, "BUSY")
            catalog.tick(state, 10)
            local expired = receive(replies)
            test.eq(expired.error and expired.error.code, "UNCERTAIN")
            test.eq(expired.request_id, "old")
            catalog.request(state, self, WORKSPACE, self, request("new"), DESKTOP, 30)
            local current = state.pending
            if not current then error("successor did not start") end
            catalog.result(state, {version = 1, workspace_id = WORKSPACE, request_id = old.id,
                desktop_id = DESKTOP, code = "OK", message = "", desktops = {}}, WORKSPACE, WORKSPACE, 11)
            test.eq(state.pending and state.pending.id, current.id)
            catalog.result(state, {version = 1, workspace_id = WORKSPACE, request_id = current.id,
                desktop_id = DESKTOP, code = "OK", message = "", desktops = {}}, WORKSPACE, WORKSPACE, 12)
            local completed = receive(replies)
            test.is_true(completed.ok)
            test.eq(completed.request_id, "new")
            test.is_nil(state.pending)
            process.unlisten(replies)
        end)
        test.it("answers concurrent listings from one catalog read and keeps allocation exclusive", function()
            local replies = listen()
            local self = tostring(process.pid())
            local state = catalog.new()
            catalog.request(state, self, WORKSPACE, self, request("first-list"), nil, 10)
            local pending = state.pending
            if not pending then error("listing did not start") end
            catalog.request(state, self, WORKSPACE, self, request("second-list"), nil, 20)
            test.eq(state.pending and state.pending.id, pending.id, "a second listing started another catalog read")
            catalog.request(state, self, WORKSPACE, self, request("create-during-list"), DESKTOP, 20)
            local busy = receive(replies)
            test.eq(busy.request_id, "create-during-list")
            test.eq(busy.error and busy.error.code, "BUSY")
            catalog.result(state, {version = 1, workspace_id = WORKSPACE, request_id = pending.id,
                desktop_id = "", code = "OK", message = "", desktops = {{desktop_id = DESKTOP, is_default = true}}}, WORKSPACE, WORKSPACE, 5)
            local answered: {[string]: boolean} = {}
            for _ = 1, 2 do
                local reply = receive(replies)
                test.is_true(reply.ok)
                answered[reply.request_id] = true
            end
            test.is_true(answered["first-list"] == true)
            test.is_true(answered["second-list"] == true)
            test.is_nil(state.pending)
            process.unlisten(replies)
        end)
        test.it("does not accept a substituted committed allocation identity", function()
            local replies = listen()
            local self = tostring(process.pid())
            local state = catalog.new()
            catalog.request(state, self, WORKSPACE, self, request("create"), DESKTOP, 10)
            local pending = state.pending
            if not pending then error("request did not start") end
            catalog.result(state, {version = 1, workspace_id = WORKSPACE, request_id = pending.id,
                desktop_id = WORKSPACE, code = "OK", message = "", desktops = {}}, WORKSPACE, WORKSPACE, 1)
            local reply = receive(replies)
            test.is_false(reply.ok)
            test.eq(reply.error and reply.error.code, "UNCERTAIN")
            process.unlisten(replies)
        end)
        test.it("rejects duplicate catalog identities without claiming an uncertain mutation", function()
            local replies = listen()
            local self = tostring(process.pid())
            local state = catalog.new()
            catalog.request(state, self, WORKSPACE, self, request("list"), nil, 10)
            local pending = state.pending
            if not pending then error("request did not start") end
            catalog.result(state, {version = 1, workspace_id = WORKSPACE, request_id = pending.id,
                desktop_id = "", code = "OK", message = "", desktops = {
                    {desktop_id = DESKTOP, is_default = true}, {desktop_id = DESKTOP, is_default = false},
                }}, WORKSPACE, WORKSPACE, 1)
            local reply = receive(replies)
            test.is_false(reply.ok)
            test.eq(reply.error and reply.error.code, "UNAVAILABLE")
            process.unlisten(replies)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
