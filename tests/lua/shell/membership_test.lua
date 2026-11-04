-- MIT. A display follows the hive in the order its membership events arrive:
-- a node shows once its owner is found serving after its latest join, and a
-- departure or a later join outdates every check made before it.
local test = require("test")
local membership = require("membership")

local function joined(node: string): {[string]: unknown} return {kind = "node.joined", path = node} end
local function left(node: string): {[string]: unknown} return {kind = "node.left", path = node} end

-- join applies node's join and returns the check it starts.
local function join(state: membership.Membership, node: string): membership.Check
    local check = membership.observe(state, joined(node))
    return assert(check)
end

local function define_tests()
    test.describe("membership", function()
        test.it("shows a node that joined before the menu opened once its owner serves", function()
            local state = membership.new()
            local check = join(state, "beta")
            test.eq(#membership.nodes(state), 0)
            local change = assert(membership.served(state, check, true))
            test.eq(change.node, "beta")
            test.is_true(change.serving)
            test.eq(membership.nodes(state)[1], "beta")
        end)

        test.it("lists the serving nodes by identity", function()
            local state = membership.new()
            for _, node in ipairs({"gamma", "alpha", "beta"}) do
                membership.served(state, membership.member(state, node), node ~= "beta")
            end
            local nodes = membership.nodes(state)
            test.eq(#nodes, 2)
            test.eq(nodes[1], "alpha")
            test.eq(nodes[2], "gamma")
        end)

        test.it("drops a serving node that leaves", function()
            local state = membership.new()
            membership.served(state, membership.member(state, "beta"), true)
            local _, change = membership.observe(state, left("beta"))
            test.eq(assert(change).node, "beta")
            test.is_false(assert(change).serving)
            test.eq(#membership.nodes(state), 0)
        end)

        test.it("keeps a departed node off when a check made before it left finds its owner", function()
            local state = membership.new()
            local check = join(state, "beta")
            local _, change = membership.observe(state, left("beta"))
            test.is_nil(change)
            test.is_nil(membership.served(state, check, true))
            test.eq(#membership.nodes(state), 0)
        end)

        test.it("shows a node restarted under the same identity through the check after its rejoin", function()
            local state = membership.new()
            membership.served(state, membership.member(state, "beta"), true)
            local before = membership.member(state, "beta")
            local _, departed = membership.observe(state, left("beta"))
            test.is_false(assert(departed).serving)
            local after = join(state, "beta")
            test.is_nil(membership.served(state, before, true))
            test.eq(#membership.nodes(state), 0)
            local change = assert(membership.served(state, after, true))
            test.is_true(change.serving)
            test.eq(membership.nodes(state)[1], "beta")
        end)

        test.it("applies a join the snapshot already holds once, deciding by the latest check", function()
            local state = membership.new()
            local seen = membership.member(state, "beta")
            local queued = join(state, "beta")
            test.is_nil(membership.served(state, seen, false))
            test.is_true(assert(membership.served(state, queued, true)).serving)
            test.is_nil(membership.served(state, queued, true))
            test.eq(#membership.nodes(state), 1)
        end)

        test.it("drops a node whose latest check finds no owner", function()
            local state = membership.new()
            membership.served(state, membership.member(state, "beta"), true)
            local check = join(state, "beta")
            test.eq(#membership.nodes(state), 1)
            test.is_false(assert(membership.served(state, check, false)).serving)
            test.eq(#membership.nodes(state), 0)
        end)

        test.it("ignores events of other kinds and events without a node", function()
            local state = membership.new()
            local check, change = membership.observe(state, {kind = "node.updated", path = "beta"})
            test.is_nil(check)
            test.is_nil(change)
            check, change = membership.observe(state, {kind = "node.joined"})
            test.is_nil(check)
            test.is_nil(change)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options)
    return run_cases(options)
end

return { run = run }
