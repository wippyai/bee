-- MIT. The Hive holdings operation reports one bounded page of the workspaces
-- this node holds live, as its own host manager answers. The page's shape and
-- the paging decisions are covered exhaustively at the manager's own model
-- (bee.launch:holdings_test); here the live manager must answer the operation
-- end to end, an invalid request must refuse, and a malformed manager answer
-- must refuse rather than look like an empty node.
local test = require("test")
local funcs = require("funcs")
local time = require("time")
local leases = require("leases")
local A = string.rep("a", 32)
local OP = "bee.hive.api:holdings"
local function call(request: {[string]: unknown}): {[string]: unknown}
    local result, err = funcs.call(OP, request)
    if err or type(result) ~= "table" then error(OP .. ": " .. tostring(err)) end
    return result :: {[string]: unknown}
end
local function define_tests()
    test.describe("Hive workspace holdings", function()
        test.it("answers a bounded page from this node's live host manager", function()
            local page = call({limit = 50})
            test.is_true(type(page.node_id) == "string")
            test.is_true(type(page.has_more) == "boolean")
            test.is_true(type(page.workspaces) == "table")
            local rows = page.workspaces :: {{[string]: unknown}}
            test.is_true(#rows <= 50)
            for _, row in ipairs(rows) do
                test.is_true(type(row.workspace_id) == "string" and #(row.workspace_id :: string) == 32)
                test.is_true(row.phase == "starting" or row.phase == "ready" or row.phase == "stopping")
                test.is_true(type(row.lease_count) == "number" and (row.lease_count :: number) >= 0)
            end
            -- A cursor the page returned continues the listing without error.
            if page.next_after then
                local rest = call({after = page.next_after, limit = 50})
                test.is_true(type(rest.workspaces) == "table")
            end
        end)
        test.it("refuses a malformed request", function()
            local bounded = pcall(call, {limit = 0})
            test.is_false(bounded)
            local stray = pcall(call, {holder = "x"})
            test.is_false(stray)
        end)
        test.it("reads one bounded page from the live manager and refuses a malformed answer", function()
            local page, read_error = leases.read_holdings({limit = 50}, "5s")
            test.is_nil(read_error)
            if not page then error("no page") end
            test.is_true(type(page.has_more) == "boolean")
            test.is_true(type(page.workspaces) == "table")
            -- A malformed manager answer is refused, never read as an empty node.
            test.is_nil(leases.holdings_result({version = 1, request_id = "r", has_more = false,
                workspaces = {{workspace_id = A, phase = "gone", lease_count = 0}}}))
            test.is_nil(leases.holdings_result({version = 1, request_id = "r", has_more = false,
                workspaces = {{workspace_id = "short", phase = "ready", lease_count = 0}}}))
            test.is_nil(leases.holdings_result({version = 1, request_id = "r", has_more = "no", workspaces = {}}))
            local decoded = assert(leases.holdings_result({version = 1, request_id = "r", has_more = false,
                workspaces = {{workspace_id = A, phase = "stopping", lease_count = 3}}}))
            test.eq(decoded.workspaces[1].phase, "stopping")
            test.eq(decoded.workspaces[1].lease_count, 3)
        end)
        test.it("decodes a bounded holdings request strictly", function()
            local request = assert(leases.holdings_request({version = 1, request_id = "r1", after = A, limit = 5}))
            test.eq(request.after, A)
            test.eq(request.limit, 5)
            test.is_nil(leases.holdings_request({version = 2, request_id = "r1"}))
            test.is_nil(leases.holdings_request({version = 1, request_id = "r1", after = "short"}))
            test.is_nil(leases.holdings_request({version = 1, request_id = "r1", extra = 1}))
            test.is_nil(leases.holdings_request({version = 1, request_id = "r1", limit = 0}))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
