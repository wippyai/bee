-- MIT. The desktop bridge admits a local client node exactly while the host
-- enrolls it. Enrollment is the host's selection; transport membership and a
-- client-host PID alone admit nothing.
local test = require("test")
local time = require("time")
local process = require("process")
local channel = require("channel")
local security = require("security")
local funcs = require("funcs")
local owner = require("owner")
local catalog = require("catalog")
local enrollment = require("enrollment")
local protocol = require("protocol")
local WORKSPACE = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local function client(node: string, tag: string): string
    return "{" .. node .. "@" .. protocol.CLIENT_HOST .. "|" .. tag .. "}"
end
type Channel = channel.Channel
local function listen(topic: string): Channel<process.Message>
    local messages, err = process.listen(topic, {message = true})
    if not messages then error(tostring(err)) end
    return messages
end
local function bridge(local_clients: boolean, topic: string): owner.State
    local unused = listen("bee.test.desktop_enrollment." .. topic)
    local state: owner.State = {
        bridge_name = "bee.retained.bridge/" .. string.rep("0", 32), owner_name = "bee.retained.owner/" .. string.rep("0", 32), stopped = false, node = "owner-node",
        allowed = {}, enrolled = {}, config = {execution = WORKSPACE, expires_at = "", allowed_nodes = {}, local_clients = local_clients, folder = true},
        ready = unused, results = unused, copies = unused, launches = unused,
        activations = unused, reader_updates = unused, observers = unused, catalog = catalog.new(),
        spawn_scope = security.new_scope({}), executor = funcs.new(), folder = nil, served = {}, workspaces = {}, served_count = 0,
        clients = {}, receipts = {}, client_count = 0, receipt_count = 0, expires_at = time.now(),
    }
    return state
end
local function define_tests()
    test.describe("Hive desktop local client enrollment", function()
        test.it("admits a local client node only while the host enrolls it", function()
            local state = bridge(true, "admits")
            test.is_false(owner.admits(state, client("client-1", "a")), "unenrolled local client admitted")
            owner.enroll(state, {["client-1"] = true}, 0)
            test.is_true(owner.admits(state, client("client-1", "a")))
            test.is_false(owner.admits(state, client("client-2", "a")), "another node rode on an enrollment")
            test.is_false(owner.admits(state, "{client-1@bee:workers|a}"), "a non-client host was admitted")
            owner.enroll(state, {}, 0)
            test.is_false(owner.admits(state, client("client-1", "a")), "retired node still admitted")
        end)

        test.it("ignores enrollment when the host did not select local clients", function()
            local state = bridge(false, "unselected")
            owner.enroll(state, {["client-1"] = true}, 0)
            test.is_false(owner.admits(state, client("client-1", "a")))
        end)

        test.it("revokes an attached client whose node leaves the enrollment", function()
            local state = bridge(true, "revokes")
            owner.enroll(state, {["client-1"] = true, ["client-2"] = true}, 0)
            local leaving, staying = client("client-1", "a"), client("client-2", "b")
            state.clients[leaving] = {recipient = leaving, workspace_id = WORKSPACE, desktop_id = "", closing = false, dirty = false}
            state.clients[staying] = {recipient = staying, workspace_id = WORKSPACE, desktop_id = "", closing = false, dirty = false}
            state.client_count = 2
            owner.enroll(state, {["client-2"] = true}, 0)
            test.is_nil(state.clients[leaving], "retired node kept its attachment")
            test.not_nil(state.clients[staying])
            test.eq(state.client_count, 1)
        end)

        test.it("derives the local clients from the configured nodes the boot set does not own", function()
            local decoded = enrollment.decode({nodes = {"forge", "client-1", "client-2"}, peers = {"hive-1"}})
            if not decoded then error("expected a decoded enrollment") end
            local configured = {forge = true, ["client-1"] = true, ["hive-1"] = true}
            local clients = enrollment.set(decoded.nodes, {forge = true}, configured)
            test.is_true(clients["client-1"] == true)
            test.is_nil(clients.forge, "a boot peer took the local client role")
            test.is_nil(clients["client-2"], "an unconfigured node was presented as admitted")
            test.is_nil(clients["hive-1"], "a Hive peer reached the desktop bridge")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
