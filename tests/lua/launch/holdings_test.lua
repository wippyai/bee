-- MIT. The node host manager's holdings view: one bounded page of the live
-- workspaces a node holds, with each host's phase, load and lease count, so a
-- Hive peer can see which node holds which workspaces without reading the
-- manager's private state.
local test = require("test")
local hosts = require("hosts")

local A, B, C = string.rep("a", 32), string.rep("b", 32), string.rep("c", 32)

local function started(state: hosts.State, workspace_id: string, lease: string, holder: string)
    test.eq(hosts.acquire(state, workspace_id, lease, holder).kind, "start")
    hosts.started(state, workspace_id, "pid-" .. workspace_id:sub(1, 1))
    hosts.ready(state, workspace_id, 0)
end

local function define_tests()
    test.describe("Node workspace holdings", function()
        test.it("pages live workspaces in identity order with phase, load and leases", function()
            local state = hosts.new(4, 10)
            started(state, C, "lease-c", "holder-c")
            started(state, A, "lease-a", "holder-a")
            test.eq(hosts.acquire(state, A, "lease-a2", "holder-b").kind, "ready")
            local page = assert(hosts.holdings(state, {limit = 1}))
            test.eq(#page.workspaces, 1)
            test.eq(page.workspaces[1].workspace_id, A)
            test.eq(page.workspaces[1].phase, "ready")
            test.eq(page.workspaces[1].lease_count, 2)
            test.eq(page.has_more, true)
            test.eq(page.next_after, A)
            local rest = assert(hosts.holdings(state, {after = A, limit = 8}))
            test.eq(#rest.workspaces, 1)
            test.eq(rest.workspaces[1].workspace_id, C)
            test.eq(rest.has_more, false)
            test.is_nil(rest.next_after)
        end)

        test.it("reports load as the count of leases a host currently holds", function()
            local state = hosts.new(4, 10)
            started(state, A, "lease-a", "holder-a")
            local page = assert(hosts.holdings(state, {limit = 8}))
            test.eq(page.workspaces[1].lease_count, 1)
            hosts.release(state, "lease-a", 1)
            test.eq((assert(hosts.holdings(state, {limit = 8}))).workspaces[1].lease_count, 0)
        end)

        test.it("bounds the page and accepts only a cursor it returned", function()
            local state = hosts.new(4, 10)
            started(state, A, "lease-a", "holder-a")
            local bounded, bounded_error = hosts.holdings(state, {limit = 0})
            test.is_nil(bounded)
            test.not_nil(bounded_error)
            local cursor, cursor_error = hosts.holdings(state, {after = "short", limit = 8})
            test.is_nil(cursor)
            test.not_nil(cursor_error)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
