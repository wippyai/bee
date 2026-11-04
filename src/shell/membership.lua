-- MIT. The hive as a display sees it: the members it learned of, from the
-- cluster's membership events in the order they arrive and from the members
-- read after subscribing, and which of them have an owner serving desktops.
-- Every join and departure outdates the checks made before it, so a late
-- check never brings back a node that left or rejoined since.
local bounds = require("bounds")

-- A Member is a node of the hive: generation is the latest check of it,
-- serving whether that check found its owner.
type Member = {generation: integer, serving: boolean}
type Membership = {members: {[string]: Member}, generation: integer}
-- A Check asks whether node's owner serves desktops; its answer counts only
-- while it is the node's latest.
type Check = {node: string, generation: integer}
-- A Change is a node starting or stopping to serve.
type Change = {node: string, serving: boolean}

local M = {}

function M.new(): Membership
    return {members = {}, generation = 0}
end

-- member records node as a member of the hive and returns the check to run.
function M.member(state: Membership, node: string): Check
    state.generation = state.generation + 1
    local current = state.members[node]
    if current then current.generation = state.generation
    else state.members[node] = {generation = state.generation, serving = false} end
    return {node = node, generation = state.generation}
end

-- observe applies a cluster event: a join returns the check to run, a
-- departure the change when the node served.
function M.observe(state: Membership, event: unknown): (Check?, Change?)
    if type(event) ~= "table" then return nil, nil end
    local node = bounds.id(event.path)
    if not node then return nil, nil end
    if event.kind == "node.joined" then return M.member(state, node), nil end
    if event.kind ~= "node.left" then return nil, nil end
    local current = state.members[node]
    if not current then return nil, nil end
    state.members[node] = nil
    if current.serving then return nil, {node = node, serving = false} end
    return nil, nil
end

-- served applies the answer to check and returns the change it makes.
function M.served(state: Membership, check: Check, serving: boolean): Change?
    local current = state.members[check.node]
    if not current or current.generation ~= check.generation or current.serving == serving then return nil end
    current.serving = serving
    return {node = check.node, serving = serving}
end

-- nodes lists the members whose owner serves desktops, by identity.
function M.nodes(state: Membership): {string}
    local found: {string} = {}
    for node, member in pairs(state.members) do
        if member.serving then found[#found + 1] = node end
    end
    table.sort(found)
    return found
end

return M
