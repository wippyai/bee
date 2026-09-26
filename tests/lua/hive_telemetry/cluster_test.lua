-- MIT. The cluster holdings aggregate: one bounded page from each named
-- node, shaped for presentation. A refused, malformed or unreachable node is
-- unavailable, never counted as holding nothing; the request itself is
-- decoded strictly.
local test = require("test")
local types = require("types")
local cluster = require("cluster")
local A = string.rep("a", 32)
local B = string.rep("b", 32)
local function stub_listing(rows: {unknown}): () -> (unknown, unknown)
    return function(): (unknown, unknown) return rows, nil end
end
local function stub_links(rows: {unknown})
    local links, invalid = cluster.read_links(stub_listing(rows))
    if not links then error(tostring(invalid)) end
    return links
end
local function holdings(node_id: string, rows: {unknown}, has_more: boolean): {[string]: unknown}
    return {node_id = node_id, workspaces = rows, has_more = has_more}
end
local function row(workspace_id: string, phase: string, lease_count: integer): {[string]: unknown}
    return {workspace_id = workspace_id, phase = phase, lease_count = lease_count}
end
local function scripted(answers: {[string]: types.Reply}): cluster.Call
    return function(owner: types.OwnerRef, target: types.Target, _input: {[string]: unknown}, options: {timeout: string?}): types.Reply
        test.eq(owner.service_id, cluster.SERVICE)
        test.eq(target.operation_ref, cluster.HOLDINGS)
        test.eq(options.timeout, cluster.TIMEOUT)
        local answer = answers[owner.node_id]
        if answer then return answer end
        return types.reply_error("r", types.fault("UNAVAILABLE", "no route to node"))
    end
end
local function define_tests()
    test.describe("Cluster workspace holdings", function()
        test.it("counts one page per reachable node", function()
            local list_calls = 0
            local listing = function(): (unknown, unknown)
                list_calls = list_calls + 1
                return {
                    {id = "local", is_local = true},
                    {id = "node-a", is_local = false, link = {remote = "10.0.0.2:7946", dialed = true}},
                    {id = "node-b", is_local = false, link = {remote = "10.0.0.3:7946", dialed = false}},
                }, nil
            end
            local call = scripted({
                ["node-a"] = types.reply_ok("r", holdings("node-a", {row(A, "ready", 2), row(B, "starting", 0)}, true)),
                ["node-b"] = types.reply_ok("r", holdings("node-b", {}, false)),
            })
            local links, membership_error = cluster.read_links(listing)
            test.is_nil(membership_error)
            local nodes = cluster.aggregate(call, assert(cluster.decode({nodes = {"node-a", "node-b"}, limit = 8})), assert(links))
            test.eq(list_calls, 1)
            test.eq(#nodes, 2)
            test.eq(nodes[1].node_id, "node-a")
            test.eq(nodes[1].status, "ok")
            test.is_true(nodes[1].connected)
            test.eq(nodes[1].direction, "outbound")
            test.eq(nodes[1].remote_address, "10.0.0.2:7946")
            test.eq(nodes[1].workspace_count, 2)
            test.is_true(nodes[1].has_more)
            test.eq(nodes[2].node_id, "node-b")
            test.eq(nodes[2].status, "ok")
            test.is_true(nodes[2].connected)
            test.eq(nodes[2].direction, "inbound")
            test.eq(nodes[2].remote_address, "10.0.0.3:7946")
            test.eq(nodes[2].workspace_count, 0)
            test.is_false(nodes[2].has_more)
        end)
        test.it("reports a refused or unreachable node as unavailable, never as empty", function()
            local call = scripted({
                ["node-a"] = types.reply_error("r", types.fault("DENIED", "not admitted")),
            })
            local nodes = cluster.aggregate(call, assert(cluster.decode({nodes = {"node-a", "node-gone"}})),
                stub_links({{id = "node-a", is_local = false, link = {remote = "peer:7946", dialed = false}}}))
            test.eq(#nodes, 2)
            test.eq(nodes[1].status, "unavailable")
            test.is_true(nodes[1].connected)
            test.eq(nodes[1].direction, "inbound")
            test.eq(nodes[1].remote_address, "peer:7946")
            test.is_nil(nodes[1].workspace_count)
            test.eq(nodes[2].status, "unavailable")
            test.is_false(nodes[2].connected)
            test.is_nil(nodes[2].direction)
            test.is_nil(nodes[2].remote_address)
            test.is_nil(nodes[2].workspace_count)
        end)
        test.it("reports a malformed page as unavailable, never as an empty node", function()
            local call = scripted({
                ["node-a"] = types.reply_ok("r", holdings("node-a", {row(A, "gone", 1)}, false)),
                ["node-b"] = types.reply_ok("r", holdings("node-b", {row("short", "ready", 1)}, false)),
                ["node-c"] = types.reply_ok("r", {node_id = "node-c", workspaces = "nope", has_more = false}),
            })
            local nodes = cluster.aggregate(call, assert(cluster.decode({nodes = {"node-a", "node-b", "node-c"}})),
                stub_links({
                    {id = "node-a", is_local = false},
                    {id = "node-b", is_local = false, link = {remote = "node-b:7946", dialed = true}},
                    {id = "node-c", is_local = false, link = {remote = "node-c:7946", dialed = false}},
                }))
            for _, node in ipairs(nodes) do
                test.eq(node.status, "unavailable")
                test.is_nil(node.workspace_count)
            end
            test.is_false(nodes[1].connected)
            test.is_true(nodes[2].connected)
            test.is_true(nodes[3].connected)
            test.is_nil(nodes[1].direction)
            test.is_nil(nodes[1].remote_address)
            test.eq(nodes[2].direction, "outbound")
            test.eq(nodes[3].direction, "inbound")
        end)
        test.it("decodes runtime membership link records strictly", function()
            local links = assert(cluster.decode_members({
                {id = "local", is_local = true},
                {id = "outgoing", is_local = false, link = {remote = "10.0.0.4:7946", dialed = true}},
                {id = "incoming", is_local = false, link = {remote = "10.0.0.5:7946", dialed = false}},
            }))
            test.is_false(links["local"].connected)
            test.is_true(links.outgoing.connected)
            test.eq(links.outgoing.direction, "outbound")
            test.eq(links.outgoing.remote_address, "10.0.0.4:7946")
            test.is_true(links.incoming.connected)
            test.eq(links.incoming.direction, "inbound")
            test.eq(links.incoming.remote_address, "10.0.0.5:7946")
            test.is_nil(cluster.decode_members({{id = "bad-link", is_local = false,
                link = {remote = "peer:7946", dialed = "yes"}}}))
            test.is_nil(cluster.decode_members({{id = "duplicate", is_local = false}, {id = "duplicate", is_local = false}}))
            test.is_nil(cluster.decode_members({[1] = {id = "sparse-a", is_local = false}, [3] = {id = "sparse-c", is_local = false}}))
        end)
        test.it("decodes a bounded cluster request strictly", function()
            local query = assert(cluster.decode({nodes = {"node-a"}, limit = 5}))
            test.eq(#query.nodes, 1)
            test.eq(query.limit, 5)
            test.eq((assert(cluster.decode({nodes = {"node-a"}}))).limit, 50)
            test.is_nil(cluster.decode({nodes = {}}))
            test.is_nil(cluster.decode({nodes = {"node-a"}, limit = 0}))
            test.is_nil(cluster.decode({nodes = {"node-a"}, limit = 51}))
            test.is_nil(cluster.decode({nodes = {"node-a"}, holder = "x"}))
            test.is_nil(cluster.decode({nodes = "node-a"}))
            test.is_nil(cluster.decode({}))
            local many: {string} = {}
            for index = 1, 9 do many[#many + 1] = "node-" .. tostring(index) end
            test.is_nil(cluster.decode({nodes = many}))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
