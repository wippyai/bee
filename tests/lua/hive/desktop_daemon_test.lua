-- MIT. A daemon's desktop bridge composes no folder workspace: it starts no
-- retained supervisor of its own, lists no default workspace and serves only
-- the workspaces clients attach to, each through a host lease.
local test = require("test")
local protocol = require("protocol")
local owner = require("owner")
local EXECUTION = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
local function configuration(folder: unknown): (protocol.Configuration?, string?)
    return protocol.configuration({execution = EXECUTION, expires_at = "2099-01-01T00:00:00.000Z", allowed_nodes = {},
        local_clients = true, folder = folder})
end
local function define_tests()
    test.describe("Daemon desktop bridge", function()
        test.it("composes the folder workspace unless the host selects a daemon", function()
            local folder = configuration(nil)
            if not folder then error("folder configuration refused") end
            test.is_true(folder.folder)
            local daemon = configuration(false)
            if not daemon then error("daemon configuration refused") end
            test.is_false(daemon.folder)
            test.is_nil(configuration("no"))
        end)
        test.it("keeps static client grants separate from revocable Hive peer grants", function()
            local common = {execution = EXECUTION, expires_at = "2099-01-01T00:00:00.000Z", local_clients = false}
            local selected = protocol.configuration({execution = common.execution, expires_at = common.expires_at,
                local_clients = false, allowed_nodes = {"client-node"}, allowed_peers = {"peer-node"}})
            if not selected then error("host desktop grants were refused") end
            test.eq(selected.allowed_nodes[1], "client-node")
            test.eq(selected.allowed_peers[1], "peer-node")
            test.is_nil(protocol.configuration({execution = common.execution, expires_at = common.expires_at,
                local_clients = false, allowed_nodes = {"peer-node"}, allowed_peers = {"peer-node"}}))
        end)
        test.it("starts no folder supervisor and lists no default workspace", function()
            local daemon = configuration(false)
            if not daemon then error("daemon configuration refused") end
            local state = owner.start(daemon, "daemon-node")
            test.is_nil(state.folder)
            test.eq(state.served_count, 0)
            test.is_nil(next(state.served))
            test.is_nil(owner.folder_workspace(state))
            test.is_nil(owner.listing(state).default_workspace)
            owner.close(state)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
