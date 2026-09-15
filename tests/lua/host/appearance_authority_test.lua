-- SPDX-License-Identifier: MIT
local test = require("test")
local connections = require("connections")
local identity = "0123456789abcdef0123456789abcdef"
local function define_tests()
    test.describe("Display appearance authority", function()
        test.it("rejects unadmitted, observing and stale display notifications before forwarding", function()
            -- This denial-only test must not rely on an omitted assignment
            -- store.  Any accidental assignment read is a test failure.
            local assignments = connections.assignment_access(
                function(_: unknown): (nil, string) error("appearance denial read assignments") end,
                function(): (nil, string) error("appearance denial reconciled assignments") end,
                function(_: unknown): (nil, string) error("appearance denial claimed assignments") end
            )
            local host = connections.new("owner", "invalid-broker", identity, assignments)
            local update = {version = 1, workspace_id = identity, connection_id = "connection",
                renderer = "renderer", renderer_generation = "generation", revision = 7,
                theme = "classic", background = "solid", taskbar = "labels"}
            test.is_false(connections.appearance_changed(host, "unadmitted", update))
            host.admitted["client"] = {recipient = "client", connection_id = "connection",
                permissions = {open = false, close = false, control = false}, detaching = false,
                renderer = "renderer", renderer_generation = "generation", rendering = false}
            test.is_false(connections.appearance_changed(host, "client", update))
            host.admitted["client"].permissions.control = true
            update.connection_id = "old-connection"
            test.is_false(connections.appearance_changed(host, "client", update))
            update.connection_id = "connection"
            update.renderer_generation = "old-generation"
            test.is_false(connections.appearance_changed(host, "client", update))
            update.renderer_generation = "generation"
            update.renderer = "old-renderer"
            test.is_false(connections.appearance_changed(host, "client", update))
            update.renderer = "renderer"
            update.workspace_id = string.rep("f", 32)
            test.is_false(connections.appearance_changed(host, "client", update))
            update.workspace_id = identity
            host.admitted["client"].rendering = true
            test.is_false(connections.appearance_changed(host, "client", update))
            host.admitted["client"].rendering = false
            host.admitted["client"].detaching = true
            test.is_false(connections.appearance_changed(host, "client", update))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
