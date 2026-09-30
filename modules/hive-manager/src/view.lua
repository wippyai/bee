-- MIT. The Hive Manager frame: the Hive state, the nodes as membership and
-- their owners report them, the selected node's workspaces, explicit control
-- and observe actions and the status line. Every text comes through the
-- model's bounding.
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
local names = require("names")
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?, capacity: integer, offset: integer}
local M = {}
local function status_word(node: model.Node): string
    if node.client_only then return "client" end
    if node.status == "reachable" then return "ready" end
    if node.status == "unavailable" then return "unavailable" end
    return "unknown"
end
local function bytes(value: integer?): string
    if value == nil then return "-" end
    local kib: number = value / 1024
    local mib: number = value / 1048576
    if value < 1024 then
        return tostring(value) .. " B"
    elseif value < 1048576 then
        return string.format("%.0f KiB", kib)
    else
        return string.format("%.1f MiB", mib)
    end
end
local HINTS = frame.hints({{key = "↑↓", verb = "select"}, {key = "Enter", verb = "open"}, {key = "Tab", verb = "workspaces"},
    {key = "C", verb = "control"}, {key = "O", verb = "observe"}, {key = "R", verb = "refresh"}, {key = "T", verb = "details"}, {key = "Esc", verb = "back or close"}})
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, offset: integer, status: string): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    local online, clients = 0, 0
    for _, node in ipairs(state.nodes) do
        if node.status == "reachable" then online = online + 1 end
        if node.client_only then clients = clients + 1 end
    end
    local computers = #state.nodes - clients
    local summary: string = ""
    if state.technical then
        summary = tostring(#state.nodes) .. (#state.nodes == 1 and " node · " or " nodes · ") .. tostring(online) .. " ready"
        if clients > 0 then summary = tostring(online) .. " ready · " .. tostring(clients) .. (clients == 1 and " display" or " displays") end
    else
        summary = tostring(computers) .. (computers == 1 and " computer · " or " computers · ") .. tostring(online) .. " online"
        if clients > 0 then summary = summary .. " · " .. tostring(clients) .. (clients == 1 and " display" or " displays") end
    end
    frame.header(painter, "HIVE MANAGER", summary)
    local hive_line = "Hive: unknown"
    if state.hive == "running" then
        hive_line = state.technical and "Hive: supervisor running on this node" or "Hive: supervisor running on this computer"
    elseif state.hive == "unavailable" then
        hive_line = "Hive supervisor unavailable: " .. state.hive_detail
    end
    frame.line(painter, 2, hive_line, theme.muted)
    local selected = model.selected(state)
    local catalog = model.catalog(state)
    local nodes = state.nodes
    -- The node list takes the rows it needs; the selected node's workspaces use the rest.
    local reserved = 0
    if selected and height >= 12 then reserved = math.floor(math.max(5, math.min(height - 8, state.technical and 12 or 8))) end
    local list_last = height - 2 - reserved
    if reserved > 0 then list_last = math.floor(math.min(list_last, 3 + math.max(1, #nodes))) end
    local workspace_rows = reserved > 0 and (height - 2 - list_last) or 0
    local selected_index = 0
    local cells: {{string}} = {}
    local keys: {string} = {}
    local show_address = state.technical and width >= 100
    for index, node in ipairs(nodes) do
        local name: string = ""
        local row: {string} = {}
        if state.technical then
            name = node.label
            if node.client_only then name = "◫ " .. name end
            if node.label ~= node.node_id then name = name .. " (" .. node.node_id .. ")" end
            if node.is_local then name = name .. " · this node" end
            row = {name, node.member and "present" or "left", status_word(node)}
            if show_address then row[#row + 1] = node.addr end
        else
            if node.client_only then
                name = "◫ " .. node.label .. (node.is_local and " · this display" or "")
                row = {name, "display"}
            else
                name = node.label .. (node.is_local and " · this computer" or "")
                local st = "unknown"
                if node.status == "reachable" then st = "online"
                elseif node.status == "unavailable" then st = "offline" end
                row = {name, st}
            end
        end
        cells[index] = row
        keys[index] = node.node_id
        if selected and node.node_id == selected.node_id then selected_index = index end
    end
    local window: frame.Window = {offset = 0, capacity = 0}
    if #nodes == 0 then
        frame.empty(painter, 4, state.technical and "No nodes reported" or "No computers connected",
            state.technical and "Nodes appear here when they join this hive · R refresh" or "Computers appear here when they join your hive · R refresh")
    else
        local columns: {frame.Column} = {}
        if state.technical then
            columns = {{title = "Node", width = 0}, {title = "Membership", width = 10}, {title = "Bee service", width = 11}}
            if show_address then columns[#columns + 1] = {title = "Address", width = 21} end
        else
            columns = {{title = "Computer", width = 0}, {title = "State", width = 10}}
        end
        window = frame.table(painter, 3, list_last, {columns = columns, cells = cells, keys = keys, kind = "node",
            selected = selected_index, offset = offset, focused = state.pane == "nodes"})
    end
    if selected and workspace_rows > 0 then
        local y = list_last + 1
        frame.rule(painter, y)
        local lines: {string} = {}
        local line_keys: {string} = {}
        local head = ""
        if state.technical then
            head = "Node " .. selected.label
            if selected.label ~= selected.node_id then head = head .. " (" .. selected.node_id .. ")" end
            if selected.client_only then head = head .. "  ·  Display client"
            elseif selected.status == "reachable" then
                head = head .. "  ·  Ready"
                head = head .. "  cluster " .. (selected.cluster_size and tostring(selected.cluster_size) or "—")
                    .. "  sampled " .. (selected.sampled_at or "—")
            elseif selected.status == "unavailable" then head = head .. "  ·  Service unavailable: " .. selected.detail end
            if catalog and catalog.available and not selected.client_only then
                head = head .. "  ·  Page " .. tostring(model.page_number(state, selected.node_id)) .. (catalog.next_after and " · more" or "")
                if state.pane == "workspaces" and not state.editing then head = head .. "  ·  / search · PgUp/PgDn page" end
            end
            lines[#lines + 1] = head
            line_keys[#line_keys + 1] = ""
            if not selected.client_only and workspace_rows >= 7 then
                local tech_info = "Raft role " .. (selected.role or "unknown")
                    .. "  ·  heap " .. bytes(selected.heap) .. "  ·  goroutines " .. (selected.goroutines and tostring(selected.goroutines) or "-")
                if catalog and catalog.available then
                    local session = selected.node_id ~= "" and state.sessions[selected.node_id] or nil
                    if session then tech_info = tech_info .. "  ·  owner execution " .. session.owner_execution end
                end
                lines[#lines + 1] = tech_info
                line_keys[#line_keys + 1] = ""
            end
        else
            if selected.client_only then
                head = "◫ " .. selected.label .. "  ·  Display"
            else
                head = selected.label
                if selected.status == "reachable" then head = head .. "  ·  Online"
                elseif selected.status == "unavailable" then head = head .. "  ·  Offline" end
                if catalog and catalog.available then
                    head = head .. "  ·  Page " .. tostring(model.page_number(state, selected.node_id)) .. (catalog.next_after and " · more" or "")
                    if state.pane == "workspaces" and not state.editing then head = head .. "  ·  / search · PgUp/PgDn page" end
                end
            end
            lines[#lines + 1] = head
            line_keys[#line_keys + 1] = ""
        end
        if state.editing then
            lines[#lines + 1] = "Search: " .. model.text(state.search, 60) .. "▏"
            line_keys[#line_keys + 1] = ""
        elseif not selected.client_only then
            local query = model.query(state, selected.node_id)
            if query.label then
                lines[#lines + 1] = "Search: " .. model.text(query.label, 60)
                line_keys[#line_keys + 1] = ""
            end
        end
        if selected.client_only then
            lines[#lines + 1] = state.technical and "Display client · no Bee service on this node" or "Display client · no workspaces on this screen"
            line_keys[#line_keys + 1] = ""
        elseif not catalog then
            lines[#lines + 1] = state.technical and "Open the node to list its workspaces" or "Open the computer to list its workspaces"
            line_keys[#line_keys + 1] = ""
        elseif not catalog.available then
            lines[#lines + 1] = "Workspaces unavailable: " .. catalog.reason
            line_keys[#line_keys + 1] = ""
        elseif #catalog.workspaces == 0 then
            lines[#lines + 1] = state.technical and "No workspaces match on this node" or "No workspaces match on this computer"
            line_keys[#line_keys + 1] = ""
        else
            local workspace_ids: {string} = {}
            for _, workspace in ipairs(catalog.workspaces) do workspace_ids[#workspace_ids + 1] = workspace.workspace_id end
            local workspace_labels = names.labels(workspace_ids)
            local visible = math.floor(math.max(1, workspace_rows - 1 - #lines))
            local selected_workspace = 0
            for index, workspace in ipairs(catalog.workspaces) do
                if workspace.workspace_id == state.selected_workspace then selected_workspace = index end
            end
            local shown = frame.window(#catalog.workspaces, visible, math.floor(math.max(1, selected_workspace)), 0)
            for slot = 1, shown.capacity do
                local workspace = catalog.workspaces[shown.offset + slot]
                if not workspace then break end
                local session = model.session(state, selected.node_id, workspace.workspace_id)
                local item = workspace.label ~= "" and workspace.label or (workspace_labels[workspace.workspace_id] or names.label(workspace.workspace_id))
                item = item .. (workspace.served and "  served" or "  not served")
                if session then
                    item = item .. "  your " .. session.mode .. " session"
                    if state.technical then item = item .. " " .. session.session_id end
                end
                if state.technical then item = item .. "  workspace " .. workspace.workspace_id end
                lines[#lines + 1] = item
                line_keys[#line_keys + 1] = workspace.workspace_id
            end
        end
        for index, value in ipairs(lines) do
            if index > workspace_rows - 1 then break end
            local key = line_keys[index]
            if key == "" then frame.line(painter, y + index, value, index == 1 and theme.muted or theme.text)
            else
                frame.row(painter, y + index, value, state.selected_workspace == key, "workspace", index, key, nil, state.pane == "workspaces")
            end
        end
    end
    local idle = state.pending == nil
    local workspace = model.selected_workspace(state)
    if height >= 4 then
        frame.actions(painter, height - 1, {
            {kind = "open", key = "Enter", label = "Open", enabled = selected ~= nil and not selected.client_only and catalog == nil, primary = true},
            {kind = "control", key = "C", label = "Control", enabled = workspace ~= nil and idle and model.can_control(state)},
            {kind = "observe", key = catalog ~= nil and "Enter" or "O", label = "Observe", enabled = workspace ~= nil and idle, primary = catalog ~= nil},
            {kind = "refresh", key = "R", label = "Refresh", enabled = idle},
            {kind = "technical", key = "T", label = state.technical and "Hide details" or "Details", enabled = true},
        })
    end
    local message = status
    if message == "" then message = state.outcome end
    if message == "" and state.pending then message = "Waiting for the desktop owner…" end
    if message == "" and state.membership_detail ~= "" then message = "Membership: " .. state.membership_detail end
    frame.footer(painter, message, HINTS)
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = window.capacity, offset = window.offset}
end
return M
