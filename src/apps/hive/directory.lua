-- MIT. The Hive Manager's one source of nodes and desktops: a typed
-- directory whose live form asks this node's runtime membership and its
-- Hive supervisor, and whose fixture form replays a host-admitted, labeled
-- table. Neither grants authority. Every answer is what an owner said or a
-- refusal naming why the operation is not available to this application.
local types = require("types")
local bounds = require("bounds")
local M = {}
M.LIVE = "live"
M.FIXTURE = "fixture"
M.TELEMETRY = "bee.hive.telemetry"
M.PRESENCE = "bee.hive.telemetry:presence"
M.STATS = "bee.hive.telemetry:stats"
M.MAX_NODES = 64
M.MAX_DESKTOPS = 64
M.MAX_ADDRESS_BYTES = 200
M.MAX_LABEL_BYTES = 120
M.DESKTOPS_UNAVAILABLE = "Desktop browsing is not available from this app yet"
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
    source: string,
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
type FixtureNode = {node_id: string, is_local: boolean, addr: string, reachable: boolean, role: string, cluster_size: integer, detail: string}
type Fixture = {label: string, nodes: {FixtureNode}, catalogs: {[string]: Catalog}}
type Object = {[string]: unknown}
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
    local function desktops(_: Directory, _node: string): Catalog return unavailable(M.DESKTOPS_UNAVAILABLE) end
    local function attach(_: Directory, _request: Attach): Outcome return refused("UNSUPPORTED_CAPABILITY", M.ATTACH_UNAVAILABLE) end
    return {source = M.LIVE, supervisor = supervisor, members = members, presence = presence, stats = stats, desktops = desktops, attach = attach}
end
local function decode_desktop(value: unknown): (Desktop?, string?)
    local object = bounds.object(value)
    if not object then return nil, "desktop must be an object" end
    local fields_error = bounds.fields(object, {"workspace_id", "desktop_id", "label", "controller", "observers"})
    if fields_error then return nil, fields_error end
    local workspace = bounds.id(object.workspace_id)
    local desktop = bounds.id(object.desktop_id)
    if not workspace or not desktop then return nil, "desktop needs workspace_id and desktop_id" end
    local label = ""
    if object.label ~= nil then
        label = bounds.line(object.label, M.MAX_LABEL_BYTES) or ""
        if label == "" then return nil, "desktop label must be one bounded line" end
    end
    local controller: string? = nil
    if object.controller ~= nil then
        controller = bounds.id(object.controller) or ""
        if controller == "" then return nil, "desktop controller must be a bounded identity" end
    end
    local observers: integer? = nil
    if object.observers ~= nil then
        local count = bounds.integer(object.observers)
        if not count or count < 0 or count > 16 then return nil, "desktop observers must be 0 to 16" end
        observers = count
    end
    return {workspace_id = workspace, desktop_id = desktop, label = label, controller = controller, observers = observers}, nil
end
local function decode_catalog(value: unknown): (Catalog?, string?)
    local object = bounds.object(value)
    if not object then return nil, "catalog must be an object" end
    local fields_error = bounds.fields(object, {"available", "reason", "owner_generation", "desktops"})
    if fields_error then return nil, fields_error end
    if type(object.available) ~= "boolean" then return nil, "catalog available must be a boolean" end
    local reason = ""
    if object.reason ~= nil then
        reason = bounds.line(object.reason, 400) or ""
        if reason == "" then return nil, "catalog reason must be one bounded line" end
    end
    local desktops: {Desktop} = {}
    if object.desktops ~= nil then
        if type(object.desktops) ~= "table" then return nil, "catalog desktops must be a list" end
        local seen: {[string]: boolean} = {}
        for _, item in ipairs(object.desktops :: {unknown}) do
            local desktop, desktop_error = decode_desktop(item)
            if not desktop then return nil, desktop_error end
            local key = desktop.workspace_id .. "\0" .. desktop.desktop_id
            if seen[key] then return nil, "catalog repeats a desktop" end
            seen[key] = true
            if #desktops >= M.MAX_DESKTOPS then return nil, "catalog lists more than " .. tostring(M.MAX_DESKTOPS) .. " desktops" end
            desktops[#desktops + 1] = desktop
        end
    end
    if object.available == false and reason == "" then return nil, "an unavailable catalog names its reason" end
    local generation = ""
    if object.owner_generation ~= nil then
        generation = bounds.id(object.owner_generation) or ""
        if generation == "" then return nil, "catalog owner_generation must be a bounded identity" end
    end
    if object.available == true and generation == "" then return nil, "an available catalog names its owner generation" end
    return {available = object.available == true, reason = reason, owner_generation = generation, desktops = desktops}, nil
end
local function decode_node(value: unknown): (FixtureNode?, string?)
    local object = bounds.object(value)
    if not object then return nil, "node must be an object" end
    local fields_error = bounds.fields(object, {"node_id", "is_local", "addr", "reachable", "role", "cluster_size", "detail"})
    if fields_error then return nil, fields_error end
    local id = bounds.id(object.node_id)
    if not id then return nil, "node_id must be a bounded identity" end
    if type(object.reachable) ~= "boolean" then return nil, "node reachable must be a boolean" end
    local addr = ""
    if object.addr ~= nil then
        addr = bounds.line(object.addr, M.MAX_ADDRESS_BYTES) or ""
        if addr == "" then return nil, "node addr must be one bounded line" end
    end
    local role = ""
    if object.role ~= nil then
        role = bounds.line(object.role, 32) or ""
        if role == "" then return nil, "node role must be one bounded line" end
    end
    local detail = ""
    if object.detail ~= nil then
        detail = bounds.line(object.detail, 400) or ""
        if detail == "" then return nil, "node detail must be one bounded line" end
    end
    local size = 1
    if object.cluster_size ~= nil then
        local count = bounds.integer(object.cluster_size)
        if not count or count < 1 or count > M.MAX_NODES then return nil, "node cluster_size must be 1 to " .. tostring(M.MAX_NODES) end
        size = count
    end
    return {node_id = id, is_local = object.is_local == true, addr = addr, reachable = object.reachable, role = role, cluster_size = size, detail = detail}, nil
end
-- A fixture is a strict, host-admitted table. It names itself so no frame
-- built from it can pass for a live Hive.
function M.decode_fixture(value: unknown): (Fixture?, string?)
    local object = bounds.object(value)
    if not object then return nil, "fixture must be an object" end
    local fields_error = bounds.fields(object, {"label", "nodes", "catalogs"})
    if fields_error then return nil, fields_error end
    local label = bounds.line(object.label, M.MAX_LABEL_BYTES)
    if not label then return nil, "fixture label must be one bounded line" end
    if type(object.nodes) ~= "table" then return nil, "fixture nodes must be a list" end
    local nodes: {FixtureNode} = {}
    local seen: {[string]: boolean} = {}
    local locals = 0
    for _, item in ipairs(object.nodes :: {unknown}) do
        local node, node_error = decode_node(item)
        if not node then return nil, node_error end
        if seen[node.node_id] then return nil, "fixture repeats node " .. node.node_id end
        seen[node.node_id] = true
        if node.is_local then locals = locals + 1 end
        if #nodes >= M.MAX_NODES then return nil, "fixture lists more than " .. tostring(M.MAX_NODES) .. " nodes" end
        nodes[#nodes + 1] = node
    end
    if locals ~= 1 then return nil, "fixture names exactly one local node" end
    local catalogs: {[string]: Catalog} = {}
    if object.catalogs ~= nil then
        local table_value = bounds.object(object.catalogs)
        if not table_value then return nil, "fixture catalogs must map node ids to catalogs" end
        for node_id, item in pairs(table_value) do
            if not seen[node_id] then return nil, "fixture catalog for unknown node " .. tostring(node_id) end
            local catalog, catalog_error = decode_catalog(item)
            if not catalog then return nil, catalog_error end
            catalogs[node_id] = catalog
        end
    end
    return {label = label, nodes = nodes, catalogs = catalogs}, nil
end
function M.fixture(fixture: Fixture): Directory
    local sessions = 0
    local receipts: {[string]: {digest: string, outcome: Outcome}} = {}
    local function supervisor(_: Directory): Supervisor return {running = true, detail = ""} end
    local function members(_: Directory): ({Member}, string?)
        local result: {Member} = {}
        for _, node in ipairs(fixture.nodes) do result[#result + 1] = {node_id = node.node_id, is_local = node.is_local, addr = node.addr, client_only = false} end
        return result, nil
    end
    local function find(node_id: string): FixtureNode?
        for _, node in ipairs(fixture.nodes) do if node.node_id == node_id then return node end end
        return nil
    end
    local function presence(_: Directory, node_id: string): Reply
        local node = find(node_id)
        if not node then return types.reply_error("fixture", types.fault("UNAVAILABLE", "no peer for node " .. node_id)) end
        if not node.reachable then return types.reply_error("fixture", types.fault("UNAVAILABLE", node.detail ~= "" and node.detail or "peer unreachable")) end
        return types.reply_ok("fixture", {protocol_revision = types.REVISION, node_id = node.node_id, role = node.role, cluster_size = node.cluster_size, sampled_at = "2026-09-09T00:00:00.000Z"})
    end
    local function stats(_: Directory, node_id: string): Reply
        local node = find(node_id)
        if not node or not node.reachable then return types.reply_error("fixture", types.fault("UNAVAILABLE", "peer unreachable")) end
        return types.reply_ok("fixture", {memory = {heap_alloc = 0}, goroutines = 0, cpu_count = 0, sampled_at = "2026-09-09T00:00:00.000Z"})
    end
    local function desktops(_: Directory, node_id: string): Catalog
        local catalog = fixture.catalogs[node_id]
        if catalog then return catalog end
        return unavailable("fixture lists no desktops for node " .. node_id)
    end
    -- The fixture owner behaves as the contract asks: a stale generation is
    -- refused, an identical replay returns the recorded outcome, control
    -- never displaces a controller, observation is always a distinct choice.
    local function decide(request: Attach): Outcome
        local catalog = fixture.catalogs[request.node_id]
        if not catalog or not catalog.available then return refused("UNAVAILABLE", "desktop owner unavailable") end
        if request.owner_generation ~= catalog.owner_generation then
            return refused("CONFLICT", "catalog is stale: the owner generation changed; refresh before attaching")
        end
        for _, desktop in ipairs(catalog.desktops) do
            if desktop.workspace_id == request.workspace_id and desktop.desktop_id == request.desktop_id then
                if request.mode == "control" and desktop.controller ~= nil and desktop.controller ~= "" then
                    return refused("CONFLICT", "desktop is controlled by " .. desktop.controller .. "; observe instead")
                end
                sessions = sessions + 1
                if request.mode == "control" then desktop.controller = "bee.hive_manager" else desktop.observers = (desktop.observers or 0) + 1 end
                return {ok = true, code = "", message = "", session_id = "fixture-session-" .. tostring(sessions), mode = request.mode}
            end
        end
        return refused("NOT_FOUND", "selected desktop does not belong to this owner")
    end
    local function attach(_: Directory, request: Attach): Outcome
        local digest = table.concat({request.node_id, request.workspace_id, request.desktop_id, request.owner_generation, request.mode}, "\0")
        local receipt = receipts[request.idempotency_key]
        if receipt then
            if receipt.digest ~= digest then return refused("CONFLICT", "idempotency key is already used by another request") end
            return receipt.outcome
        end
        local outcome = decide(request)
        receipts[request.idempotency_key] = {digest = digest, outcome = outcome}
        return outcome
    end
    return {source = M.FIXTURE, supervisor = supervisor, members = members, presence = presence, stats = stats, desktops = desktops, attach = attach}
end
return M
