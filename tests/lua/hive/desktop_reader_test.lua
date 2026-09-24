-- MIT. Real-sender regression for ephemeral Hive catalog readers.
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local types = require("types")
local owner = require("owner")
local reader = require("reader")
local catalog = require("catalog")
type Channel = channel.Channel
local WORKSPACE = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local DESKTOP = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
local function listen(topic: string): Channel<process.Message>
    local messages, err = process.listen(topic, {message = true})
    if not messages then error(tostring(err)) end
    return messages
end
local function call(node: string): types.Call
    local value = types.decode_call({protocol_revision = types.REVISION, request_id = "reader-call", idempotency_key = "reader-call",
        owner_ref = {node_id = node, service_id = "bee.desktop"}, target = {operation_ref = reader.OPERATION}, input = {}})
    if not value then error("invalid catalog reader call") end
    return value
end
local function next_message(messages: Channel<process.Message>): process.Message
    local selected = channel.select({messages:case_receive(), time.after("2s"):case_receive()})
    if not selected.ok or selected.channel ~= messages then error("missing reader test message") end
    return selected.value
end
local function reply(replies: Channel<process.Message>): types.Reply
    local selected = channel.select({replies:case_receive(), time.after("2s"):case_receive()})
    if not selected.ok or selected.channel ~= replies then error("missing reader denial") end
    local value = types.decode_reply(selected.value:payload():data())
    if not value then error("invalid reader denial") end
    return value
end
local function define_tests()
    test.describe("Hive desktop catalog readers", function()
        test.it("uses authenticated supervisor sender snapshots, revokes before a result, and never widens native control", function()
            local snapshots = listen("bee.test.catalog_reader")
            local replies = listen(types.TOPIC_REPLY)
            local requests = listen("bee.retained.desktops")
            local self = tostring(process.pid())
            -- The production supervisor uses this routing marker when its
            -- native PID has no node component. It must not determine PID
            -- locality for catalog-reader admission.
            local node = "local"
            local state: owner.State = {
                supervisor = "", bridge_name = "bee.retained.bridge/" .. string.rep("0", 32), owner_name = "bee.retained.owner/" .. string.rep("0", 32), stopped = false, workspace_id = WORKSPACE, desktop_id = "", node = node,
                allowed = {}, enrolled = {}, config = {execution = WORKSPACE, expires_at = "", allowed_nodes = {}, local_clients = false},
                ready = snapshots, results = snapshots, copies = snapshots, launches = snapshots, catalogs = snapshots,
                activations = snapshots, reader_updates = snapshots, observers = snapshots, catalog_readers = {}, pending_catalog_readers = nil,
                catalog = catalog.new(), clients = {}, receipts = {}, client_count = 0, receipt_count = 0, expires_at = time.now(),
            }
            local forged = assert(process.spawn_monitored("bee.hive:reader_sender", "bee:workers", self, WORKSPACE, {"grant_self"}))
            local forged_message = next_message(snapshots)
            owner.catalog_readers(state, forged_message)
            test.is_false(owner.catalog_reader(state, tostring(forged)), "untrusted actor granted itself")

            local denied = reader.request(state, self, {
                protocol_revision = types.REVISION, request_id = "unapproved", idempotency_key = "unapproved",
                owner_ref = {node_id = node, service_id = "bee.desktop"}, target = {operation_ref = reader.OPERATION}, input = {},
            }, 0)
            test.is_nil(denied)
            local refused = reply(replies)
            test.is_false(refused.ok)
            test.eq(refused.error and refused.error.code, "DENIED")

            local trusted = assert(process.spawn_monitored("bee.hive:reader_sender", "bee:workers", self, WORKSPACE,
                {"grant_recipient", "forward", "forward", "forward"}))
            state.supervisor = tostring(trusted)
            local grant = next_message(snapshots)
            owner.catalog_readers(state, grant)
            test.is_true(owner.catalog_reader(state, self))
            -- A catalog reader process is still outside the native client host,
            -- including when its own actor sends the native request.
            assert(process.send(self, "bee.test.catalog_reader", {}))
            local reader_message = next_message(snapshots)
            test.is_false(owner.handles(state, reader_message), "catalog reader gained native control admission")

            assert(process.send(tostring(trusted), "bee.test.catalog_reader.command", {version = 1, workspace_id = WORKSPACE,
                readers = {"{foreign@bee:workers|catalog-reader}"}}))
            local foreign = next_message(snapshots)
            local foreign_state: owner.State = state
            local accepted = pcall(function() owner.catalog_readers(foreign_state, foreign) end)
            test.is_false(accepted, "foreign native node entered catalog readers")
            test.is_true(owner.catalog_reader(state, self), "foreign snapshot changed reader state")

            catalog.request(state.catalog, self, WORKSPACE, self, call(node), nil, 1000)
            local pending = state.catalog.pending
            if not pending then error("admitted catalog request did not start") end
            local dispatched = next_message(requests):payload():data()
            test.eq(dispatched.request_id, pending.id)
            test.eq(dispatched.workspace_id, WORKSPACE)

            assert(process.send(tostring(trusted), "bee.test.catalog_reader.command", {version = 1, workspace_id = WORKSPACE, readers = {}}))
            local clear = next_message(snapshots)
            owner.catalog_readers(state, clear)
            test.is_false(owner.catalog_reader(state, self), "complete removal snapshot retained reader")
            test.not_nil(state.catalog.pending)

            assert(process.send(tostring(trusted), "bee.test.catalog_reader.command", {version = 1, workspace_id = WORKSPACE,
                request_id = pending.id, desktop_id = "", code = "OK", message = "", desktops = {{desktop_id = DESKTOP, is_default = true}}}))
            local result = next_message(snapshots)
            owner.catalog_result(state, result, 1)
            local revoked = reply(replies)
            test.is_false(revoked.ok)
            test.eq(revoked.error and revoked.error.code, "DENIED")
            test.is_nil(state.catalog.pending)
            state.catalog_readers[self] = true
            state.stopped = true
            reader.request(state, self, {
                protocol_revision = types.REVISION, request_id = "stopped", idempotency_key = "stopped",
                owner_ref = {node_id = node, service_id = "bee.desktop"}, target = {operation_ref = reader.OPERATION}, input = {},
            }, 0)
            local stopped = reply(replies)
            test.eq(stopped.error and stopped.error.code, "DENIED")
            process.unlisten(snapshots); process.unlisten(replies); process.unlisten(requests)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
