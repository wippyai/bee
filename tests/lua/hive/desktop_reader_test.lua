-- MIT. Real-sender regression for ephemeral Hive catalog readers.
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local security = require("security")
local funcs = require("funcs")
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
            local self = tostring(process.pid())
            -- The production supervisor uses this routing marker when its
            -- native PID has no node component. It must not determine PID
            -- locality for catalog-reader admission.
            local node = "local"
            local policies: {security.Policy} = {}
            for _, name in ipairs({"bee:desktop_catalog_policy", "bee:desktop_catalog_resource_policy", "bee:workspace_catalog_read_policy",
                "bee.hive.desktop:catalog_call_policy"}) do policies[#policies + 1] = assert(security.policy(name)) end
            local executor = funcs.new():with_actor(security.new_actor("bee.hive.supervisor")):with_scope(security.new_scope(policies))
            local state: owner.State = {
                bridge_name = "bee.retained.bridge/" .. string.rep("0", 32), owner_name = "bee.retained.owner/" .. string.rep("0", 32), stopped = false, node = node,
                allowed = {}, enrolled = {}, config = {execution = WORKSPACE, expires_at = "", allowed_nodes = {}, local_clients = false, folder = true},
                ready = snapshots, results = snapshots, copies = snapshots, launches = snapshots,
                activations = snapshots, reader_updates = snapshots, observers = snapshots, catalog = catalog.new(),
                spawn_scope = security.new_scope({}), executor = executor, folder = nil, served = {}, workspaces = {}, served_count = 0,
                clients = {}, receipts = {}, client_count = 0, receipt_count = 0, expires_at = time.now():add("1h"),
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
                {"grant_recipient", "forward", "forward"}))
            -- The trusted sender stands in for the folder workspace's supervisor.
            local served: owner.Served = {supervisor = tostring(trusted), workspace_id = WORKSPACE, desktop_id = DESKTOP, folder = true,
                ready = true, catalog_readers = {}, pending_catalog_readers = nil}
            state.served[served.supervisor] = served
            state.workspaces[WORKSPACE] = served
            state.folder = served
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

            reader.request(state, self, {
                protocol_revision = types.REVISION, request_id = "admitted", idempotency_key = "admitted",
                owner_ref = {node_id = node, service_id = "bee.desktop"}, target = {operation_ref = reader.OPERATION}, input = {},
            }, 0)
            test.not_nil(state.catalog.pending, "admitted catalog request did not start")

            assert(process.send(tostring(trusted), "bee.test.catalog_reader.command", {version = 1, workspace_id = WORKSPACE, readers = {}}))
            local clear = next_message(snapshots)
            owner.catalog_readers(state, clear)
            test.is_false(owner.catalog_reader(state, self), "complete removal snapshot retained reader")
            test.not_nil(state.catalog.pending)

            -- The catalog read completes after the reader lost its admission.
            while state.catalog.pending do
                local cases = {}
                for _, response in ipairs(owner.catalog_channels(state)) do cases[#cases + 1] = response:case_receive() end
                local deadline = time.after("10s")
                cases[#cases + 1] = deadline:case_receive()
                local selected = channel.select(cases)
                if selected.channel == deadline then error("catalog read did not complete") end
                test.is_true(owner.catalog_result(state, selected.channel, 1))
            end
            local revoked = reply(replies)
            test.is_false(revoked.ok)
            test.eq(revoked.error and revoked.error.code, "DENIED")
            test.is_nil(state.catalog.pending)
            served.catalog_readers[self] = true
            state.stopped = true
            reader.request(state, self, {
                protocol_revision = types.REVISION, request_id = "stopped", idempotency_key = "stopped",
                owner_ref = {node_id = node, service_id = "bee.desktop"}, target = {operation_ref = reader.OPERATION}, input = {},
            }, 0)
            local stopped = reply(replies)
            test.eq(stopped.error and stopped.error.code, "DENIED")
            process.unlisten(snapshots); process.unlisten(replies)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
