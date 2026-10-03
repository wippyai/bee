-- MIT. The Hive Manager model, pure: nodes as membership and their owners
-- report them, workspaces as each owner lists them, an explicit control or
-- observe choice built only from a listed workspace of a reachable node, outcomes
-- shown as the owner answered. A node that leaves membership stays listed
-- briefly as unavailable; retirement removes only presentation records.
local json = require("json")
local text = require("text")
local directory = require("directory")
local names = require("names")
local contract = require("contract")
local hive_types = require("types")
local hive_bounds = require("hive_bounds")
local M = {}
M.TEXT_LIMIT = 160
M.LABEL_LIMIT = 48
M.MAX_NAMES = 256
M.MAX_NODES = directory.MAX_NODES
M.RETIRE_AFTER_MS = 60000
type Reply = directory.Reply
type Catalog = directory.Catalog
type Attach = directory.Attach
type Outcome = directory.Outcome
type Mode = directory.Mode
function M.attach_message(workspace_label: string, workspace_id: string, node_label: string, mode: Mode): string
    local capability = mode == "observe" and "Read-only observation." or "Input and resize control."
    return "Workspace " .. workspace_label .. " (" .. workspace_id .. ") on " .. node_label .. ". "
        .. capability .. " Duration: until you leave, the connection ends or the owner stops."
end
type Status = "unknown" | "reachable" | "unavailable"
type PresenceSample = {role: string, cluster_size: integer, sampled_at: string}
type StatsSample = {heap: integer, goroutines: integer}
type Node = {node_id: string, label: string, client_only: boolean, is_local: boolean, addr: string, member: boolean, departed_at: integer, absent_since: integer?, status: Status, detail: string,
    role: string?, cluster_size: integer?, sampled_at: string?, heap: integer?, goroutines: integer?}
type Session = {session_id: string, mode: Mode, owner_execution: string}
type NodeSessions = {owner_execution: string, sessions: {[string]: Session}}
type Pane = "nodes" | "workspaces"
-- Where a node's workspace listing stands: its label search, the page cursor
-- and the cursors back to earlier pages. One page is held, never the list.
type Listing = {label: string, after: string?, back: {string}}
type Hive = "unknown" | "running" | "unavailable"
type State = {
    hive: Hive, hive_detail: string, membership_detail: string, generation: integer,
    nodes: {Node}, index: {[string]: Node}, names: {[string]: string}, catalogs: {[string]: Catalog},
    catalog_revisions: {[string]: integer},
    selected_node: string?, selected_workspace: string?, wanted_node: string?, wanted_workspace: string?,
    pane: Pane, pending: Attach?, outcome: string, sessions: {[string]: NodeSessions}, technical: boolean,
    listings: {[string]: Listing}, editing: boolean, search: string,
}
type Object = {[string]: unknown}
local function decode_object(value: unknown): Object?
    return hive_bounds.object(value)
end
function M.text(value: unknown, limit: integer?): string
    return text.bound(value, limit or M.TEXT_LIMIT)
end
-- Friendly names are display aliases the host wrote down; they select
-- nothing and identify nothing.
function M.names(value: unknown): {[string]: string}
    local names: {[string]: string} = {}
    if type(value) ~= "table" then return names end
    local count = 0
    for node_id, label in pairs(value) do
        if type(node_id) == "string" and node_id ~= "" and #node_id <= 160 and type(label) == "string" and label ~= "" and #label <= M.LABEL_LIMIT
            and not node_id:find("%c") and not label:find("%c") and count < M.MAX_NAMES then
            names[node_id] = label
            count = count + 1
        end
    end
    return names
end
function M.new(names: {[string]: string}): State
    return {hive = "unknown", hive_detail = "", membership_detail = "", generation = 0,
        nodes = {}, index = {}, names = names, catalogs = {}, catalog_revisions = {}, selected_node = nil, selected_workspace = nil, wanted_node = nil, wanted_workspace = nil, pane = "nodes",
        pending = nil, outcome = "", sessions = {}, technical = false, listings = {}, editing = false, search = ""}
end
local function is_uuid(value: string): boolean
    if #value == 36 and value:find("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil then
        return true
    end
    if #value == 32 and value:find("^%x+$") ~= nil then
        return true
    end
    return false
end
local function label_of(state: State, node_id: string): string
    if state.names[node_id] then
        return M.text(state.names[node_id], M.LABEL_LIMIT)
    end
    if is_uuid(node_id) then
        return M.text(names.label(node_id), M.LABEL_LIMIT)
    end
    return M.text(node_id, M.LABEL_LIMIT)
end
local function order(state: State)
    table.sort(state.nodes, function(a: Node, b: Node): boolean
        if a.is_local ~= b.is_local then return a.is_local end
        if a.member ~= b.member then return a.member end
        if a.label ~= b.label then return a.label < b.label end
        return a.node_id < b.node_id
    end)
end
local function remove_node(state: State, index: integer)
    local removed = table.remove(state.nodes, index)
    state.index[removed.node_id] = nil
    state.catalogs[removed.node_id] = nil
    state.listings[removed.node_id] = nil
    state.sessions[removed.node_id] = nil
    if state.selected_node == removed.node_id then
        state.selected_node = nil
        state.selected_workspace = nil
        state.wanted_workspace = nil
        if state.wanted_node == removed.node_id then state.wanted_node = nil end
    end
    if state.pending and state.pending.node_id == removed.node_id then
        state.pending = nil
        state.wanted_workspace = nil
        if state.wanted_node == removed.node_id then state.wanted_node = nil end
    end
    if state.wanted_node == removed.node_id then
        state.wanted_node = nil
        state.wanted_workspace = nil
    end
end
function M.set_supervisor(state: State, running: boolean, detail: string)
    state.hive = running and "running" or "unavailable"
    state.hive_detail = M.text(detail)
end
-- Membership replaces what is a member now; a node seen before and gone
-- from a complete list is marked unavailable for a 60-second grace. The list stays within the
-- display bound: when members and retained nodes exceed it, the departed
-- node that left earliest is dropped first, the selected one last.
local function evict(state: State, reported: {[string]: boolean})
    while #state.nodes > M.MAX_NODES do
        local victim: integer = 0
        local victim_class = math.huge
        for index, node in ipairs(state.nodes) do
            local class = 8
            if not node.member and node.node_id ~= state.selected_node and not node.is_local then
                class = 1
            elseif not node.member and node.node_id ~= state.selected_node then
                class = 2
            elseif not node.member then
                class = 3
            elseif not reported[node.node_id] and node.node_id ~= state.selected_node and not node.is_local then
                class = 4
            elseif not reported[node.node_id] and node.node_id ~= state.selected_node then
                class = 5
            elseif reported[node.node_id] and node.node_id ~= state.selected_node and not node.is_local then
                class = 6
            elseif reported[node.node_id] and node.node_id ~= state.selected_node then
                class = 7
            end
            if class < victim_class or (class == victim_class and (victim == 0 or node.departed_at < state.nodes[victim].departed_at)) then
                victim, victim_class = index, class
            end
        end
        if victim == 0 then return end
        remove_node(state, victim)
    end
end
function M.apply_members(state: State, members: {directory.Member}, problem: string?, now_ms: integer?)
    local now = now_ms or 0
    state.membership_detail = problem and M.text(problem) or ""
    state.generation = state.generation + 1
    local reported: {[string]: boolean} = {}
    local previous_membership: {[string]: boolean} = {}
    for _, node in ipairs(state.nodes) do previous_membership[node.node_id] = node.member end
    local complete = problem == nil
    -- A failed or truncated sample cannot prove absence. Keep each prior
    -- membership value, but reset departure grace so uncertainty cannot age a
    -- row out of the presentation.
    if not complete then
        for _, node in ipairs(state.nodes) do node.absent_since = nil end
    else
        for _, node in ipairs(state.nodes) do node.member = false end
    end
    for _, member in ipairs(members) do
        reported[member.node_id] = true
        local node = state.index[member.node_id]
        local was_member = node ~= nil and previous_membership[node.node_id] == true
        if not node then
            node = {node_id = member.node_id, label = label_of(state, member.node_id), is_local = member.is_local, addr = M.text(member.addr),
                member = true, client_only = member.client_only == true, departed_at = 0, status = "unknown", detail = "", role = nil, cluster_size = nil, sampled_at = nil, heap = nil, goroutines = nil}
            state.index[member.node_id] = node
            state.nodes[#state.nodes + 1] = node
        else
            node.member = true
            node.is_local = member.is_local
            node.addr = M.text(member.addr)
        end
        if not was_member then node.status, node.detail = "unknown", "" end
        node.client_only = member.client_only == true
        if node.client_only then
            node.label = state.names[node.node_id] or ("Display · " .. names.label(node.node_id))
            state.catalogs[node.node_id] = nil
            state.sessions[node.node_id] = nil
        else node.label = label_of(state, node.node_id) end
    end
    if complete then
        for _, node in ipairs(state.nodes) do
            if not node.member then
                if node.status ~= "unavailable" or node.departed_at == 0 then node.departed_at = state.generation end
                node.status = "unavailable"
                node.detail = "left membership; retiring after 60s"
                if node.absent_since == nil then node.absent_since = now end
            else node.departed_at = 0; node.absent_since = nil end
        end
    end
    if complete then
        for index = #state.nodes, 1, -1 do
            local node = state.nodes[index]
            local since = node.absent_since
            if not node.member and not node.is_local and since ~= nil and now - since >= M.RETIRE_AFTER_MS then
                remove_node(state, index)
            end
        end
    end
    evict(state, reported)
    order(state)
    if state.wanted_node and state.index[state.wanted_node] then
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
local function presence(value: unknown, expected_node: string): PresenceSample?
    local value_object = decode_object(value)
    if not value_object or hive_bounds.fields(value_object, {"protocol_revision", "node_id", "role", "cluster_size", "sampled_at"})
        or value_object.protocol_revision ~= hive_types.REVISION or value_object.node_id ~= expected_node then return nil end
    local role = hive_bounds.line(value_object.role, 32)
    local cluster_size = hive_bounds.count(value_object.cluster_size)
    local sampled_at = hive_bounds.timestamp(value_object.sampled_at)
    if not role then return nil end
    if not cluster_size or cluster_size < 1 then return nil end
    if not sampled_at then return nil end
    return {role = role, cluster_size = cluster_size, sampled_at = sampled_at}
end
local function stats(value: unknown): StatsSample?
    local value_object = decode_object(value)
    if not value_object or hive_bounds.fields(value_object, {"memory", "goroutines", "cpu_count", "sampled_at"}) then return nil end
    local memory = decode_object(value_object.memory)
    if not memory or hive_bounds.fields(memory, {"alloc", "total_alloc", "sys", "heap_alloc", "heap_objects", "num_gc"}) then return nil end
    local heap = hive_bounds.count(memory.heap_alloc)
    local goroutines = hive_bounds.count(value_object.goroutines)
    local cpu_count = hive_bounds.count(value_object.cpu_count)
    local sampled_at = hive_bounds.timestamp(value_object.sampled_at)
    if not heap then return nil end
    if not goroutines then return nil end
    if not cpu_count or cpu_count < 1 then return nil end
    if not sampled_at then return nil end
    for _, name in ipairs({"alloc", "total_alloc", "sys", "heap_objects", "num_gc"}) do
        if memory[name] ~= nil and not hive_bounds.count(memory[name]) then return nil end
    end
    return {heap = heap, goroutines = goroutines}
end
function M.apply_presence(state: State, node_id: string, reply: Reply)
    local node = state.index[node_id]
    if not node or node.client_only then return end
    local sample = reply.ok and presence(reply.value, node_id) or nil
    if not reply.ok or not sample then
        node.status = "unavailable"
        node.detail = reply.ok and "telemetry presence reply is malformed" or fault_text(reply)
        node.role, node.cluster_size, node.sampled_at = nil, nil, nil
        return
    end
    node.status = "reachable"
    node.detail = ""
    node.role = sample.role
    node.cluster_size = sample.cluster_size
    node.sampled_at = sample.sampled_at
end
function M.apply_stats(state: State, node_id: string, reply: Reply)
    local node = state.index[node_id]
    if not node then return end
    local sample = reply.ok and stats(reply.value) or nil
    node.heap = sample and sample.heap or nil
    node.goroutines = sample and sample.goroutines or nil
end
function M.apply_catalog(state: State, node_id: string, catalog: Catalog)
    local node = state.index[node_id]
    if not node or node.client_only then return end
    state.catalog_revisions[node_id] = (state.catalog_revisions[node_id] or 0) + 1
    if not catalog.available then state.sessions[node_id] = nil end
    state.catalogs[node_id] = catalog
    if state.selected_node == node_id and state.wanted_workspace then
        for _, workspace in ipairs(catalog.workspaces) do
            if workspace.workspace_id == state.wanted_workspace then
                state.selected_workspace = state.wanted_workspace
                state.wanted_workspace = nil
            end
        end
    end
    if state.selected_node == node_id and state.selected_workspace then
        local found = false
        for _, workspace in ipairs(catalog.workspaces) do
            if workspace.workspace_id == state.selected_workspace then found = true end
        end
        if not found then state.selected_workspace = nil end
    end
end
-- A session belongs to one node execution. Identities copied to another
-- node or reused by a replacement owner cannot carry session state with them.
function M.session(state: State, node_id: string, workspace_id: string): Session?
    local catalog = state.catalogs[node_id]
    local remembered = state.sessions[node_id]
    if not catalog or not catalog.available or not remembered then return nil end
    return remembered.sessions[workspace_id]
end
-- A session ends when the view presenting it ends.
function M.end_session(state: State, node_id: string, workspace_id: string)
    local remembered = state.sessions[node_id]
    if remembered then remembered.sessions[workspace_id] = nil end
end
function M.selected(state: State): Node?
    if not state.selected_node then return nil end
    return state.index[state.selected_node]
end
function M.catalog(state: State): Catalog?
    if not state.selected_node then return nil end
    return state.catalogs[state.selected_node]
end
function M.selected_workspace(state: State): directory.Workspace?
    local catalog = M.catalog(state)
    if not catalog or not state.selected_workspace then return nil end
    for _, workspace in ipairs(catalog.workspaces) do
        if workspace.workspace_id == state.selected_workspace then return workspace end
    end
    return nil
end
function M.select_node(state: State, node_id: string?)
    if node_id ~= nil and not state.index[node_id] then return end
    if state.selected_node ~= node_id then state.selected_workspace = nil end
    state.selected_node = node_id
end
function M.select_workspace(state: State, workspace_id: string?)
    state.selected_workspace = workspace_id
end
function M.set_pane(state: State, pane: Pane)
    state.pane = pane
end
function M.toggle_pane(state: State)
    state.pane = state.pane == "nodes" and "workspaces" or "nodes"
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
        if not catalog or #catalog.workspaces == 0 then return end
        local keys: {string} = {}
        for _, workspace in ipairs(catalog.workspaces) do keys[#keys + 1] = workspace.workspace_id end
        local index = position(keys, state.selected_workspace)
        if index == 0 then index = step > 0 and 0 or #keys + 1 end
        index = math.floor(math.max(1, math.min(#keys, index + step)))
        state.selected_workspace = keys[index]
    end
end
-- Control is offered for a selected workspace of a node that holds
-- workspaces; the owner decides the request.
function M.can_control(state: State): boolean
    local node = M.selected(state)
    if not node or node.client_only then return false end
    return M.selected_workspace(state) ~= nil
end
-- A pending request whose outcome is unknown is replayed with the same
-- identity; a fresh intent is refused while it stands.
function M.pending_intent(state: State): Attach?
    return state.pending
end
function M.preview_intent(state: State, mode: Mode, idempotency_key: string): (Attach?, string?)
    if state.pending then return nil, "a desktop request is already pending" end
    local node = M.selected(state)
    if not node then return nil, "select a node first" end
    if node.status ~= "reachable" then return nil, "node " .. node.label .. " is " .. node.status .. "; nothing is requested of an unreachable owner" end
    local catalog = state.catalogs[node.node_id]
    if not catalog then return nil, "open the node's workspaces first" end
    if not catalog.available then return nil, catalog.reason end
    local workspace = M.selected_workspace(state)
    if not workspace then return nil, "select a workspace first" end
    local intent: Attach = {node_id = node.node_id, workspace_id = workspace.workspace_id,
        catalog_revision = state.catalog_revisions[node.node_id] or 0, mode = mode, idempotency_key = idempotency_key}
    return intent, nil
end
-- Confirmation applies only to the identity shown in the question. A refresh
-- or changed selection requires a new question; it cannot redirect consent.
function M.confirm_intent(state: State, confirmed: Attach): (Attach?, string?)
    local current, err = M.preview_intent(state, confirmed.mode, confirmed.idempotency_key)
    if not current then return nil, err end
    if current.node_id ~= confirmed.node_id or current.workspace_id ~= confirmed.workspace_id
        or current.catalog_revision ~= confirmed.catalog_revision then
        return nil, "Workspace selection changed; confirm the current workspace again"
    end
    state.pending = current
    return current, nil
end
function M.attach_intent(state: State, mode: Mode, idempotency_key: string): (Attach?, string?)
    local intent, err = M.preview_intent(state, mode, idempotency_key)
    if not intent then return nil, err end
    return M.confirm_intent(state, intent)
end
function M.apply_outcome(state: State, intent: Attach, outcome: Outcome)
    local pending = state.pending
    if not pending or pending.idempotency_key ~= intent.idempotency_key then return end
    local key = intent.workspace_id
    if not outcome.ok and outcome.code == "UNCERTAIN" then
        state.outcome = M.text("UNCERTAIN: " .. outcome.message .. "; the same request is replayed on retry")
        return
    end
    if state.pending and state.pending.idempotency_key == intent.idempotency_key then state.pending = nil end
    if outcome.ok then
        local remembered: NodeSessions? = state.sessions[intent.node_id]
        if remembered and remembered.owner_execution ~= outcome.owner_execution then remembered = nil end
        if not remembered then
            local sessions: {[string]: Session} = {}
            remembered = {owner_execution = outcome.owner_execution, sessions = sessions}
        end
        local session: Session = {session_id = M.text(outcome.session_id, 80), mode = outcome.mode, owner_execution = outcome.owner_execution}
        remembered.sessions[key] = session
        state.sessions[intent.node_id] = remembered
        state.outcome = "Attached " .. session.mode .. " session " .. session.session_id .. " on " .. names.label(intent.workspace_id)
    else
        state.outcome = M.text(outcome.code .. ": " .. outcome.message)
    end
end
function M.viewer_lost(state: State, idempotency_key: string)
    local pending = state.pending
    if not pending or pending.idempotency_key ~= idempotency_key then return end
    state.outcome = "Remote view exited before attach could be confirmed; retry will reuse the same request"
end
M.SEARCH_LIMIT = 120
local function listing(state: State, node_id: string): Listing
    local current = state.listings[node_id]
    if not current then
        current = {label = "", after = nil, back = {}}
        state.listings[node_id] = current
    end
    return current
end
-- The page of a node's workspaces to ask for next.
function M.query(state: State, node_id: string): directory.Query
    local current = listing(state, node_id)
    return {label = current.label ~= "" and current.label or nil, after = current.after}
end
function M.page_number(state: State, node_id: string): integer
    local current = state.listings[node_id]
    return current and #current.back + 1 or 1
end
-- Move the selected node's listing one page forward or back; true when the
-- page changed and must be read.
function M.page(state: State, step: integer): boolean
    local node = state.selected_node
    if not node then return false end
    local current = listing(state, node)
    if step > 0 then
        local catalog = state.catalogs[node]
        local next_after = catalog and catalog.available and catalog.next_after
        if not next_after then return false end
        current.back[#current.back + 1] = current.after or ""
        current.after = next_after
    else
        if #current.back == 0 then return false end
        local previous = current.back[#current.back]
        current.back[#current.back] = nil
        current.after = previous ~= "" and previous or nil
    end
    state.selected_workspace = nil
    return true
end
-- Search edits a label prefix for the selected node's workspaces; running it
-- starts from the first page.
function M.edit(state: State, editing: boolean)
    state.editing = editing
    if editing then
        local node = state.selected_node
        state.search = node and listing(state, node).label or ""
    end
end
function M.type_text(state: State, value: string)
    if value:find("%c") or #state.search + #value > M.SEARCH_LIMIT then return end
    state.search = state.search .. value
end
function M.erase(state: State)
    if state.search == "" then return end
    state.search = state.search:sub(1, #state.search - 1)
end
function M.submit(state: State): boolean
    state.editing = false
    local node = state.selected_node
    if not node then return false end
    state.listings[node] = {label = state.search, after = nil, back = {}}
    state.selected_workspace = nil
    return true
end
function M.checkpoint(state: State): string
    return json.encode({selected_node = state.selected_node, selected_workspace = state.selected_workspace, technical = state.technical}) or "{}"
end
local function bounded_string(value: unknown): boolean
    return value == nil or (type(value) == "string" and #(value) <= 400)
end
function M.restore(state: State, encoded: string): boolean
    local decoded: unknown = json.decode(encoded)
    if type(decoded) ~= "table" then return false end
    local saved = decoded
    if not bounded_string(saved.selected_node) or not bounded_string(saved.selected_workspace) then return false end
    if saved.technical ~= nil and type(saved.technical) ~= "boolean" then return false end
    -- Selection is remembered by identity and resolved against what the
    -- owners report after the next refresh; it never restores a session.
    state.wanted_node = saved.selected_node ~= nil and (saved.selected_node) or nil
    state.wanted_workspace = saved.selected_workspace ~= nil and (saved.selected_workspace) or nil
    state.technical = saved.technical == true
    return true
end
return M
