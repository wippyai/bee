-- MIT. The Hive Manager's one source of nodes and their workspaces: a typed
-- directory that asks this node's runtime membership and Hive supervisor.
-- It grants no authority. Every answer is what an owner said or a refusal
-- naming why the operation is not available to this application.
local types = require("types")
local bounds = require("bounds")
local contract = require("contract")
local M = {}
M.TELEMETRY = "bee.hive.telemetry.binding"
M.PRESENCE = "bee.hive.telemetry.binding:presence"
M.STATS = "bee.hive.telemetry.binding:stats"
M.MAX_NODES = 64
-- One page of a node's workspaces, and its cursor bound.
M.PAGE = 50
M.MAX_CURSOR_BYTES = 2200
M.WORKSPACES = "bee.hive.api:workspaces"
M.MAX_ADDRESS_BYTES = 200
M.MAX_LABEL_BYTES = 120
type Reply = types.Reply
type Member = {node_id: string, is_local: boolean, addr: string, client_only: boolean?}
type Workspace = {workspace_id: string, label: string, served: boolean}
-- next_after continues a node's workspace listing.
type Catalog =
    {available: true, reason: "", workspaces: {Workspace}, next_after: string?}
    | {available: false, reason: string, workspaces: {}, next_after: nil}
-- A page of a node's workspaces: a label prefix and a cursor.
type Query = {label: string?, after: string?}
type Mode = "control" | "observe"
type Attach = {node_id: string, workspace_id: string, catalog_revision: integer, mode: Mode, idempotency_key: string}
-- viewer: the remote view process presenting an attached session.
type Outcome =
    {ok: true, code: "", message: "", session_id: string, mode: Mode, viewer: string, owner_execution: string}
    | {ok: false, code: string, message: string}
type Supervisor = {running: boolean, detail: string}
type Directory = {
    supervisor: (Directory) -> Supervisor,
    members: (Directory) -> ({Member}, string?),
    presence: (Directory, string) -> Reply,
    stats: (Directory, string) -> Reply,
    workspaces: (Directory, string, Query) -> Catalog,
    attach: (Directory, Attach) -> Outcome,
}
type Call = (types.OwnerRef, types.Target, {[string]: unknown}, {timeout: string?}) -> Reply
type Lookup = () -> (string?, string?)
type Membership = () -> (unknown, unknown)
-- open_view attaches a confirmed request through the owner node's desktop
-- bridge in a remote view and answers once the view is attached or refused.
type OpenView = (Attach) -> Outcome
type Live = {local_node: string, lookup: Lookup, membership: Membership, call: Call, open_view: OpenView, timeout: string?}
local function unavailable(reason: string): Catalog
    return {available = false, reason = reason, workspaces = {}, next_after = nil}
end
local function decode_member(value: unknown): (Member?, string?)
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"id", "is_local", "addr", "meta", "link"}) then return nil, "membership contains a malformed node" end
    local id = bounds.id(object.id)
    if not id or type(object.is_local) ~= "boolean" then return nil, "membership contains a malformed node identity" end
    local addr = ""
    if object.addr ~= nil then
        if type(object.addr) ~= "string" then return nil, "membership contains a malformed address" end
        if #object.addr > M.MAX_ADDRESS_BYTES or object.addr:find("%c") then return nil, "membership contains a malformed address" end
        addr = object.addr
    end
    local meta = bounds.object(object.meta)
    if object.meta ~= nil and not meta then return nil, "membership contains malformed metadata" end
    if meta and meta["bee.role"] ~= nil and type(meta["bee.role"]) ~= "string" then return nil, "membership contains a malformed role" end
    local client_only = false
    if meta and meta["bee.role"] == "client" then client_only = true end
    local member: Member = {node_id = id, is_local = object.is_local, addr = addr, client_only = client_only}
    return member, nil
end
-- Membership as the runtime reports it, bounded, with this node always
-- present: a runtime without a cluster still has itself.
local function live_members(self: Directory, live: Live): ({Member}, string?)
    local raw, err = live.membership()
    local local_member: Member = {node_id = live.local_node, is_local = true, addr = "", client_only = false}
    local result: {Member} = {local_member}
    local seen: {[string]: boolean} = {}
    local problem: string? = nil
    local rows = bounds.array(raw, M.MAX_NODES)
    if err ~= nil or not rows then
        problem = err ~= nil and tostring(err) or "cluster membership must be a dense list of at most " .. tostring(M.MAX_NODES) .. " nodes"
    else
        local decoded: {Member} = {}
        local malformed: string? = nil
        local saw_local = false
        for _, item in ipairs(rows) do
            local member, invalid = decode_member(item)
            if not member then malformed = invalid; break end
            if seen[member.node_id] then malformed = "membership repeats node " .. member.node_id; break end
            if member.is_local ~= (member.node_id == live.local_node) then malformed = "membership has inconsistent local-node identity"; break end
            seen[member.node_id] = true
            saw_local = saw_local or member.node_id == live.local_node
            decoded[#decoded + 1] = member
        end
        if not malformed and not saw_local and #decoded >= M.MAX_NODES then malformed = "membership omitted this node from a full listing" end
        if malformed then
            problem = malformed
        else
            result = decoded
            if not saw_local then table.insert(result, 1, local_member) end
        end
    end
    return result, problem
end
-- The retained catalog reports identities only. Absence of occupancy data
-- must remain unknown, and malformed replies must never look like an empty node.
-- One page of a node's workspaces as the node answers its open workspaces
-- operation. A workspace is listed by identity; a display is chosen when a
-- client attaches to it.
function M.decode_workspaces(value: unknown, expected_node_id: string?): Catalog
    local invalid = "Workspace catalog reply is malformed"
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"node_id", "workspaces", "next_after"}) then return unavailable(invalid) end
    local node = bounds.id(object.node_id)
    local rows = bounds.array(object.workspaces, M.PAGE)
    if not node or (expected_node_id and node ~= expected_node_id) or not rows then return unavailable(invalid) end
    local next_after: string? = nil
    if object.next_after ~= nil then
        next_after = bounds.line(object.next_after, M.MAX_CURSOR_BYTES)
        if not next_after or next_after == "" then return unavailable(invalid) end
    end
    local workspaces: {Workspace} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local workspace = bounds.object(raw)
        if not workspace or bounds.fields(workspace, {"workspace_id", "label", "served"}) then return unavailable(invalid) end
        local id = contract.workspace_id(workspace.workspace_id)
        -- The folder workspace's row is unnamed; the view names it by identity.
        local label = workspace.label == "" and "" or bounds.line(workspace.label, M.MAX_LABEL_BYTES)
        if not id or seen[id] or not label or type(workspace.served) ~= "boolean" then return unavailable(invalid) end
        seen[id] = true
        workspaces[#workspaces + 1] = {workspace_id = id, label = label, served = workspace.served == true}
    end
    return {available = true, reason = "", workspaces = workspaces, next_after = next_after}
end
function M.live(live: Live): Directory
    local function supervisor(_: Directory): Supervisor
        local pid, err = live.lookup()
        if pid then return {running = true, detail = ""} end
        return {running = false, detail = err or "supervisor is not running"}
    end
    local function members(self: Directory): ({Member}, string?)
        return live_members(self, live)
    end
    local function ask(node_id: string, operation: string): Reply
        return live.call({node_id = node_id, service_id = M.TELEMETRY}, {operation_ref = operation}, {}, {timeout = live.timeout})
    end
    local function presence(_: Directory, node_id: string): Reply return ask(node_id, M.PRESENCE) end
    local function stats(_: Directory, node_id: string): Reply return ask(node_id, M.STATS) end
    local function workspaces(_: Directory, node: string, query: Query): Catalog
        local input: {[string]: unknown} = {limit = M.PAGE}
        if query.label then input.label = query.label end
        if query.after then input.after = query.after end
        local reply = live.call({node_id = node, service_id = "bee.hive.api"}, {operation_ref = M.WORKSPACES}, input, {timeout = live.timeout})
        if not reply.ok then
            local fault = reply.error
            return unavailable(fault and (fault.code .. ": " .. fault.message) or "Workspace catalog unavailable")
        end
        return M.decode_workspaces(reply.value, node)
    end
    local function attach(_: Directory, request: Attach): Outcome return live.open_view(request) end
    return {supervisor = supervisor, members = members, presence = presence, stats = stats, workspaces = workspaces, attach = attach}
end
return M
