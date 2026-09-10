-- MIT. The Hive Manager model, pure: nodes as membership and their owners
-- report them, desktops as each owner lists them, an explicit control or
-- observe choice built only from an opened, reachable desktop, outcomes
-- shown as the owner answered. A node that leaves membership stays listed
-- as unavailable; nothing here deletes a target or infers ownership.
local json = require("json")
local text = require("text")
local directory = require("directory")
local M = {}
M.TEXT_LIMIT = 160
M.LABEL_LIMIT = 48
M.MAX_NAMES = 256
M.MAX_NODES = directory.MAX_NODES
type Reply = directory.Reply
type Catalog = directory.Catalog
type Attach = directory.Attach
type Outcome = directory.Outcome
type Mode = directory.Mode
type Status = "unknown" | "reachable" | "unavailable"
type Node = {node_id: string, label: string, client_only: boolean, is_local: boolean, addr: string, member: boolean, departed_at: integer, status: Status, detail: string,
    role: string, cluster_size: integer, sampled_at: string, heap: integer?, goroutines: integer?}
type Session = {session_id: string, mode: string}
type Pane = "nodes" | "desktops"
type Hive = "unknown" | "running" | "unavailable"
type State = {
    source: string, source_label: string, hive: Hive, hive_detail: string, membership_detail: string, generation: integer,
    nodes: {Node}, index: {[string]: Node}, names: {[string]: string}, catalogs: {[string]: Catalog},
    selected_node: string?, selected_desktop: string?, wanted_node: string?, wanted_desktop: string?,
    pane: Pane, pending: Attach?, outcome: string, sessions: {[string]: Session}, technical: boolean,
}
type Object = {[string]: unknown}
function M.text(value: unknown, limit: integer?): string
    return text.bound(value, limit or M.TEXT_LIMIT)
end
-- Friendly names are display aliases the host wrote down; they select
-- nothing and identify nothing.
function M.names(value: unknown): {[string]: string}
    local names: {[string]: string} = {}
    if type(value) ~= "table" then return names end
    local count = 0
    for node_id, label in pairs(value :: Object) do
        if type(node_id) == "string" and node_id ~= "" and #node_id <= 160 and type(label) == "string" and label ~= "" and #label <= M.LABEL_LIMIT
            and not node_id:find("%c") and not label:find("%c") and count < M.MAX_NAMES then
            names[node_id] = label
            count = count + 1
        end
    end
    return names
end
function M.new(source: string, source_label: string, names: {[string]: string}): State
    return {source = source, source_label = source_label, hive = "unknown", hive_detail = "", membership_detail = "", generation = 0,
        nodes = {}, index = {}, names = names, catalogs = {}, selected_node = nil, selected_desktop = nil, wanted_node = nil, wanted_desktop = nil, pane = "nodes",
        pending = nil, outcome = "", sessions = {}, technical = false}
end
function M.desktop_key(workspace_id: string, desktop_id: string): string
    return workspace_id .. "\0" .. desktop_id
end
local function label_of(state: State, node_id: string): string
    return M.text(state.names[node_id] or node_id, M.LABEL_LIMIT)
end
local function order(state: State)
    table.sort(state.nodes, function(a: Node, b: Node): boolean
        if a.is_local ~= b.is_local then return a.is_local end
        if a.member ~= b.member then return a.member end
        if a.label ~= b.label then return a.label < b.label end
        return a.node_id < b.node_id
    end)
end
function M.set_supervisor(state: State, running: boolean, detail: string)
    state.hive = running and "running" or "unavailable"
    state.hive_detail = M.text(detail)
end
-- Membership replaces what is a member now; a node seen before and gone
-- from the list is kept and marked unavailable. The list stays within the
-- display bound: when members and retained nodes exceed it, the departed
-- node that left earliest is dropped first, the selected one last.
local function evict(state: State)
    while #state.nodes > M.MAX_NODES do
        local victim: integer = 0
        for index, node in ipairs(state.nodes) do
            if not node.member and node.node_id ~= state.selected_node then
                if victim == 0 or node.departed_at < state.nodes[victim].departed_at then victim = index end
            end
        end
        if victim == 0 then
            for index, node in ipairs(state.nodes) do
                if not node.member then victim = index; break end
            end
        end
        if victim == 0 then return end
        local removed = table.remove(state.nodes, victim)
        state.index[removed.node_id] = nil
        state.catalogs[removed.node_id] = nil
        if state.selected_node == removed.node_id then state.selected_node = nil; state.selected_desktop = nil end
    end
end
function M.apply_members(state: State, members: {directory.Member}, problem: string?)
    state.generation = state.generation + 1
    for _, node in ipairs(state.nodes) do node.member = false end
    for _, member in ipairs(members) do
        local node = state.index[member.node_id]
        if not node then
            node = {node_id = member.node_id, label = label_of(state, member.node_id), is_local = member.is_local, addr = M.text(member.addr),
                member = true, client_only = member.client_only == true, departed_at = 0, status = "unknown", detail = "", role = "", cluster_size = 0, sampled_at = "", heap = nil, goroutines = nil}
            state.index[member.node_id] = node
            state.nodes[#state.nodes + 1] = node
        else
            node.member = true
            node.is_local = member.is_local
            node.addr = M.text(member.addr)
        end
        node.client_only = member.client_only == true
        if node.client_only then
            node.label = state.names[node.node_id] or ("Display " .. node.node_id:sub(-6))
            node.status, node.detail = "unknown", ""
            state.catalogs[node.node_id] = nil
        else node.label = label_of(state, node.node_id) end
    end
    for _, node in ipairs(state.nodes) do
        if not node.member then
            if node.status ~= "unavailable" or node.departed_at == 0 then node.departed_at = state.generation end
            node.status = "unavailable"
            node.detail = "left membership; retained until it returns"
        else node.departed_at = 0 end
    end
    state.membership_detail = problem and M.text(problem) or ""
    evict(state)
    order(state)
    if state.wanted_node and state.index[state.wanted_node :: string] then
        state.selected_node = state.wanted_node
        state.wanted_node = nil
    end
    if not state.selected_node and state.nodes[1] then state.selected_node = state.nodes[1].node_id end
end
local function fault_text(reply: Reply): string
    local fault = reply.error
    if not fault then return "no answer" end
    return M.text(fault.code .. ": " .. fault.message)
end
function M.apply_presence(state: State, node_id: string, reply: Reply)
    local node = state.index[node_id]
    if not node or node.client_only then return end
    if not reply.ok or type(reply.value) ~= "table" then
        node.status = "unavailable"
        node.detail = fault_text(reply)
        return
    end
    local value = reply.value :: Object
    node.status = "reachable"
    node.detail = ""
    node.role = M.text(value.role, 32)
    node.cluster_size = math.floor(tonumber(value.cluster_size) or 0)
    node.sampled_at = M.text(value.sampled_at, 40)
end
function M.apply_stats(state: State, node_id: string, reply: Reply)
    local node = state.index[node_id]
    if not node then return end
    if not reply.ok or type(reply.value) ~= "table" then node.heap = nil; node.goroutines = nil; return end
    local value = reply.value :: Object
    local memory = type(value.memory) == "table" and (value.memory :: Object) or {}
    local heap = tonumber(memory.heap_alloc)
    node.heap = heap and math.floor(heap) or nil
    local goroutines = tonumber(value.goroutines)
    node.goroutines = goroutines and math.floor(goroutines) or nil
end
function M.apply_catalog(state: State, node_id: string, catalog: Catalog)
    local node = state.index[node_id]
    if not node or node.client_only then return end
    state.catalogs[node_id] = catalog
    if state.selected_node == node_id and state.wanted_desktop then
        for _, desktop in ipairs(catalog.desktops) do
            if M.desktop_key(desktop.workspace_id, desktop.desktop_id) == state.wanted_desktop then
                state.selected_desktop = state.wanted_desktop
                state.wanted_desktop = nil
            end
        end
    end
    if state.selected_node == node_id and state.selected_desktop then
        local found = false
        for _, desktop in ipairs(catalog.desktops) do
            if M.desktop_key(desktop.workspace_id, desktop.desktop_id) == state.selected_desktop then found = true end
        end
        if not found then state.selected_desktop = nil end
    end
end
function M.selected(state: State): Node?
    if not state.selected_node then return nil end
    return state.index[state.selected_node :: string]
end
function M.catalog(state: State): Catalog?
    if not state.selected_node then return nil end
    return state.catalogs[state.selected_node :: string]
end
function M.selected_desktop(state: State): directory.Desktop?
    local catalog = M.catalog(state)
    if not catalog or not state.selected_desktop then return nil end
    for _, desktop in ipairs(catalog.desktops) do
        if M.desktop_key(desktop.workspace_id, desktop.desktop_id) == state.selected_desktop then return desktop end
    end
    return nil
end
function M.select_node(state: State, node_id: string?)
    if node_id ~= nil and not state.index[node_id :: string] then return end
    if state.selected_node ~= node_id then state.selected_desktop = nil end
    state.selected_node = node_id
end
function M.select_desktop(state: State, key: string?)
    state.selected_desktop = key
end
function M.set_pane(state: State, pane: Pane)
    state.pane = pane
end
function M.toggle_pane(state: State)
    state.pane = state.pane == "nodes" and "desktops" or "nodes"
end
function M.toggle_technical(state: State)
    state.technical = not state.technical
end
local function position(keys: {string}, current: string?): integer
    for index, key in ipairs(keys) do if key == current then return index end end
    return 0
end
function M.move(state: State, step: integer)
    if state.pane == "nodes" then
        local keys: {string} = {}
        for _, node in ipairs(state.nodes) do keys[#keys + 1] = node.node_id end
        if #keys == 0 then return end
        local index = position(keys, state.selected_node)
        if index == 0 then index = step > 0 and 0 or #keys + 1 end
        index = math.floor(math.max(1, math.min(#keys, index + step)))
        M.select_node(state, keys[index])
    else
        local catalog = M.catalog(state)
        if not catalog or #catalog.desktops == 0 then return end
        local keys: {string} = {}
        for _, desktop in ipairs(catalog.desktops) do keys[#keys + 1] = M.desktop_key(desktop.workspace_id, desktop.desktop_id) end
        local index = position(keys, state.selected_desktop)
        if index == 0 then index = step > 0 and 0 or #keys + 1 end
        index = math.floor(math.max(1, math.min(#keys, index + step)))
        state.selected_desktop = keys[index]
    end
end
-- Control is offered only where no controller is known; a controlled
-- desktop offers observation. The owner still decides either request.
function M.can_control(state: State): boolean
    local node = M.selected(state)
    if not node or node.client_only then return false end
    local desktop = M.selected_desktop(state)
    if not desktop then return false end
    if desktop.controller == "" then return true end
    local session = state.sessions[state.selected_desktop :: string]
    return session ~= nil and session.mode == "control"
end
-- A pending request whose outcome is unknown is replayed with the same
-- identity; a fresh intent is refused while it stands.
function M.pending_intent(state: State): Attach?
    return state.pending
end
function M.attach_intent(state: State, mode: Mode, idempotency_key: string): (Attach?, string?)
    if state.pending then return nil, "a desktop request is already pending" end
    local node = M.selected(state)
    if not node then return nil, "select a node first" end
    if node.status ~= "reachable" then return nil, "node " .. node.label .. " is " .. node.status .. "; nothing is requested of an unreachable owner" end
    local catalog = state.catalogs[node.node_id]
    if not catalog then return nil, "open the node's desktops first" end
    if not catalog.available then return nil, catalog.reason end
    local desktop = M.selected_desktop(state)
    if not desktop then return nil, "select a desktop first" end
    if mode == "control" and not M.can_control(state) then return nil, "desktop is controlled by " .. desktop.controller .. "; choose observe" end
    local intent: Attach = {node_id = node.node_id, workspace_id = desktop.workspace_id, desktop_id = desktop.desktop_id,
        owner_generation = catalog.owner_generation, mode = mode, idempotency_key = idempotency_key}
    state.pending = intent
    return intent, nil
end
function M.apply_outcome(state: State, intent: Attach, outcome: Outcome)
    local key = M.desktop_key(intent.workspace_id, intent.desktop_id)
    if not outcome.ok and outcome.code == "UNCERTAIN" then
        state.outcome = M.text("UNCERTAIN: " .. outcome.message .. "; the same request is replayed on retry")
        return
    end
    if state.pending and state.pending.idempotency_key == intent.idempotency_key then state.pending = nil end
    if outcome.ok then
        state.sessions[key] = {session_id = M.text(outcome.session_id, 80), mode = M.text(outcome.mode or intent.mode, 16)}
        state.outcome = "Attached " .. state.sessions[key].mode .. " session " .. state.sessions[key].session_id .. " on " .. intent.desktop_id
    else
        state.outcome = M.text(outcome.code .. ": " .. outcome.message)
    end
end
function M.checkpoint(state: State): string
    return json.encode({selected_node = state.selected_node, selected_desktop = state.selected_desktop, technical = state.technical}) or "{}"
end
local function bounded_string(value: unknown): boolean
    return value == nil or (type(value) == "string" and #(value :: string) <= 400)
end
function M.restore(state: State, encoded: string): boolean
    local decoded: unknown = json.decode(encoded)
    if type(decoded) ~= "table" then return false end
    local saved = decoded :: Object
    if not bounded_string(saved.selected_node) or not bounded_string(saved.selected_desktop) then return false end
    if saved.technical ~= nil and type(saved.technical) ~= "boolean" then return false end
    -- Selection is remembered by identity and resolved against what the
    -- owners report after the next refresh; it never restores a session.
    state.wanted_node = saved.selected_node ~= nil and (saved.selected_node :: string) or nil
    state.wanted_desktop = saved.selected_desktop ~= nil and (saved.selected_desktop :: string) or nil
    state.technical = saved.technical == true
    return true
end
return M
