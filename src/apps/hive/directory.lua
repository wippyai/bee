-- MIT. The Hive Manager's one source of nodes and desktops: a typed
-- directory that asks this node's runtime membership and Hive supervisor.
-- It grants no authority. Every answer is what an owner said or a refusal
-- naming why the operation is not available to this application.
local types = require("types")
local bounds = require("bounds")
local M = {}
M.TELEMETRY = "bee.hive.telemetry"
M.PRESENCE = "bee.hive.telemetry:presence"
M.STATS = "bee.hive.telemetry:stats"
M.MAX_NODES = 64
M.MAX_DESKTOPS = 64
M.MAX_ADDRESS_BYTES = 200
M.MAX_LABEL_BYTES = 120
M.ATTACH_UNAVAILABLE = "Connecting from Hive Manager is not available yet"
type Reply = types.Reply
type Member = {node_id: string, is_local: boolean, addr: string, client_only: boolean?}
type Desktop = {workspace_id: string, desktop_id: string, label: string, controller: string?, observers: integer?}
-- A catalog carries the owner generation it was read under; an attach names
-- that generation and its own idempotency identity, so a stale catalog
-- never attaches to a replacement desktop and an ambiguous outcome is
-- recovered by replaying the same request, never by a second one.
type Catalog = {available: boolean, reason: string, owner_generation: string, desktops: {Desktop}}
type Mode = "control" | "observe"
type Attach = {node_id: string, workspace_id: string, desktop_id: string, owner_generation: string, mode: Mode, idempotency_key: string}
type Outcome = {ok: boolean, code: string, message: string, session_id: string?, mode: string?}
type Supervisor = {running: boolean, detail: string}
type Directory = {
    supervisor: (Directory) -> Supervisor,
    members: (Directory) -> ({Member}, string?),
    presence: (Directory, string) -> Reply,
    stats: (Directory, string) -> Reply,
    desktops: (Directory, string) -> Catalog,
    attach: (Directory, Attach) -> Outcome,
}
type Call = (types.OwnerRef, types.Target, {[string]: unknown}, {timeout: string?}) -> Reply
type Lookup = () -> (string?, string?)
type Membership = () -> (unknown, unknown)
type Live = {local_node: string, lookup: Lookup, membership: Membership, call: Call, timeout: string?}
local function refused(code: string, message: string): Outcome
    return {ok = false, code = code, message = message}
end
local function unavailable(reason: string): Catalog
    return {available = false, reason = reason, owner_generation = "", desktops = {}}
end
local function decode_member(value: unknown): Member?
    local object = bounds.object(value)
    if not object then return nil end
    local id = bounds.id(object.id)
    if not id then return nil end
    local addr = ""
    if object.addr ~= nil then addr = bounds.line(object.addr, M.MAX_ADDRESS_BYTES) or "" end
    local meta = bounds.object(object.meta)
    return {node_id = id, is_local = object.is_local == true, addr = addr, client_only = meta ~= nil and meta["bee.role"] == "client"}
end
-- Membership as the runtime reports it, bounded, with this node always
-- present: a runtime without a cluster still has itself.
local function live_members(self: Directory, live: Live): ({Member}, string?)
    local raw, err = live.membership()
    local result: {Member} = {}
    local seen: {[string]: boolean} = {}
    local problem: string? = nil
    if err ~= nil or type(raw) ~= "table" then
        problem = err ~= nil and tostring(err) or "cluster membership unavailable"
    else
        local overflow = false
        for _, item in ipairs(raw :: {unknown}) do
            local member = decode_member(item)
            if member and not seen[member.node_id] then
                if #result < M.MAX_NODES then
                    seen[member.node_id] = true
                    result[#result + 1] = member
                else overflow = true end
            end
        end
        if overflow then problem = "membership lists more than " .. tostring(M.MAX_NODES) .. " nodes; showing the first " .. tostring(M.MAX_NODES) end
    end
    local has_local = false
    for _, member in ipairs(result) do if member.is_local then has_local = true end end
    if not has_local and not seen[live.local_node] then
        table.insert(result, 1, {node_id = live.local_node, is_local = true, addr = "", client_only = false})
        if #result > M.MAX_NODES then result[#result] = nil end
    end
    return result, problem
end
-- The retained catalog reports identities only. Absence of occupancy data
-- must remain unknown, and malformed replies must never look like an empty node.
local function dense(value: unknown, limit: integer): {unknown}?
    if type(value) ~= "table" then return nil end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then return nil end
        count = count + 1
        if count > limit then return nil end
    end
    for index = 1, count do if value[index] == nil then return nil end end
    return value :: {unknown}
end
local function identity(value: unknown): string?
    if type(value) ~= "string" or #value ~= 32 or value:find("[^0-9a-f]") then return nil end
    return value
end
function M.decode_desktops(value: unknown): Catalog
    local invalid = "Display catalog reply is malformed"
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"owner_execution", "workspaces"}) then return unavailable(invalid) end
    local execution = identity(object.owner_execution)
    local workspaces = dense(object.workspaces, M.MAX_DESKTOPS)
    if not execution or not workspaces then return unavailable(invalid) end
    local desktops: {Desktop} = {}
    local seen: {[string]: boolean} = {}
    for _, value in ipairs(workspaces) do
        local workspace = bounds.object(value)
        if not workspace or bounds.fields(workspace, {"workspace_id", "desktops"}) then return unavailable(invalid) end
        local id = identity(workspace.workspace_id)
        local items = dense(workspace.desktops, 33)
        if not id or seen[id] or not items or #items == 0 then return unavailable(invalid) end
        seen[id] = true
        local selected: {[string]: boolean} = {}
        for index, raw in ipairs(items) do
            local item = bounds.object(raw)
            if not item or bounds.fields(item, {"desktop_id", "is_default"}) then return unavailable(invalid) end
            local display = identity(item.desktop_id)
            if not display or selected[display] or item.is_default ~= (index == 1) or #desktops >= M.MAX_DESKTOPS then return unavailable(invalid) end
            selected[display] = true
            desktops[#desktops + 1] = {workspace_id = id, desktop_id = display, label = ""}
        end
    end
    return {available = true, reason = "", owner_generation = execution, desktops = desktops}
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
    local function desktops(_: Directory, node: string): Catalog
        local reply = live.call({node_id = node, service_id = "bee.desktop"}, {operation_ref = "bee.desktop:catalog"}, {}, {timeout = live.timeout})
        if not reply.ok then
            local fault = reply.error
            return unavailable(fault and (fault.code .. ": " .. fault.message) or "Display catalog unavailable")
        end
        return M.decode_desktops(reply.value)
    end
    local function attach(_: Directory, _request: Attach): Outcome return refused("UNSUPPORTED_CAPABILITY", M.ATTACH_UNAVAILABLE) end
    return {supervisor = supervisor, members = members, presence = presence, stats = stats, desktops = desktops, attach = attach}
end
return M
