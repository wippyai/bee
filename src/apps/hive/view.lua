-- MIT. The Hive Manager frame: the Hive state, the nodes as membership and
-- their owners report them, the selected node's desktops, explicit control
-- and observe actions and the status line. Every text comes through the
-- model's bounding.
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
local names = require("names")
type Frame = {rows: {string}, hits: {frame.Hit}, capacity: integer, offset: integer}
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
local HINTS = frame.hints({{key = "↑↓", verb = "select"}, {key = "Enter", verb = "open"}, {key = "Tab", verb = "desktops"},
    {key = "C", verb = "control"}, {key = "O", verb = "observe"}, {key = "R", verb = "refresh"}, {key = "T", verb = "details"}})
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, offset: integer, status: string): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    local online, clients = 0, 0
    for _, node in ipairs(state.nodes) do
        if node.status == "reachable" then online = online + 1 end
        if node.client_only then clients = clients + 1 end
    end
    local summary = tostring(#state.nodes) .. (#state.nodes == 1 and " node · " or " nodes · ") .. tostring(online) .. " ready"
    if clients > 0 then summary = tostring(online) .. " ready · " .. tostring(clients) .. (clients == 1 and " display" or " displays") end
    frame.header(painter, "HIVE MANAGER", summary)
    local hive_line = "Hive: unknown"
    if state.hive == "running" then hive_line = "Hive: supervisor running on this node"
    elseif state.hive == "unavailable" then hive_line = "Hive supervisor unavailable: " .. state.hive_detail end
    frame.line(painter, 2, hive_line, theme.muted)
    local selected = model.selected(state)
    local catalog = model.catalog(state)
    local nodes = state.nodes
    -- The node list takes the rows it needs; the selected node's desktops use the rest.
    local reserved = 0
    if selected and height >= 12 then reserved = math.floor(math.max(5, math.min(height - 8, state.technical and 12 or 8))) end
    local list_last = height - 2 - reserved
    if reserved > 0 then list_last = math.floor(math.min(list_last, 3 + math.max(1, #nodes))) end
    local desktop_rows = reserved > 0 and (height - 2 - list_last) or 0
    local selected_index = 0
    local cells: {{string}} = {}
    local keys: {string} = {}
    local show_address = state.technical and width >= 100
    for index, node in ipairs(nodes) do
        local name = node.label
        if state.technical and node.label ~= node.node_id then name = node.label .. " (" .. node.node_id .. ")" end
        if node.is_local then name = name .. " · this node" end
        local row = {name, node.member and "present" or "left", status_word(node)}
        if show_address then row[#row + 1] = node.addr end
        cells[index] = row
        keys[index] = node.node_id
        if selected and node.node_id == selected.node_id then selected_index = index end
    end
    local window: frame.Window = {offset = 0, capacity = 0}
    if #nodes == 0 then
        frame.empty(painter, 4, "No nodes reported", "Nodes appear here when they join this hive · R refresh")
    else
        local columns: {frame.Column} = {{title = "Node", width = 0}, {title = "Membership", width = 10}, {title = "Bee service", width = 11}}
        if show_address then columns[#columns + 1] = {title = "Address", width = 21} end
        window = frame.table(painter, 3, list_last, {columns = columns, cells = cells, keys = keys, kind = "node",
            selected = selected_index, offset = offset, focused = state.pane == "nodes"})
    end
    if selected and desktop_rows > 0 then
        local y = list_last + 1
        frame.rule(painter, y)
        local lines: {string} = {}
        local line_keys: {string} = {}
        local head = "Node " .. selected.label
        if selected.client_only then head = selected.label .. "  ·  Display client"
        elseif selected.status == "reachable" then
            head = head .. "  ·  Ready"
            if state.technical then head = head .. "  cluster " .. tostring(selected.cluster_size) .. "  sampled " .. selected.sampled_at end
        elseif selected.status == "unavailable" then head = head .. "  ·  Service unavailable: " .. selected.detail end
        if state.technical and not selected.client_only then
            head = head .. "  Raft role " .. (selected.role ~= "" and selected.role or "unknown")
            head = head .. "  heap " .. bytes(selected.heap) .. "  goroutines " .. (selected.goroutines and tostring(selected.goroutines) or "-")
            if catalog and catalog.owner_generation ~= "" then head = head .. "  owner generation " .. catalog.owner_generation end
        end
        lines[#lines + 1] = head
        line_keys[#line_keys + 1] = ""
        if selected.client_only then
            lines[#lines + 1] = "Display client · no Bee service on this node"
            line_keys[#line_keys + 1] = ""
        elseif not catalog then
            lines[#lines + 1] = "Open the node to list its desktops"
            line_keys[#line_keys + 1] = ""
        elseif not catalog.available then
            lines[#lines + 1] = "Desktops unavailable: " .. catalog.reason
            line_keys[#line_keys + 1] = ""
        elseif #catalog.desktops == 0 then
            lines[#lines + 1] = "No desktops on this node"
            line_keys[#line_keys + 1] = ""
        else
            local workspace_ids: {string} = {}
            local display_ids: {string} = {}
            for _, desktop in ipairs(catalog.desktops) do
                workspace_ids[#workspace_ids + 1] = desktop.workspace_id
                display_ids[#display_ids + 1] = desktop.desktop_id
            end
            local workspace_labels = names.labels(workspace_ids)
            local display_labels = names.labels(display_ids)
            local visible = math.floor(math.max(1, desktop_rows - 2))
            local selected_desktop = 0
            for index, desktop in ipairs(catalog.desktops) do
                if model.desktop_key(desktop.workspace_id, desktop.desktop_id) == state.selected_desktop then selected_desktop = index end
            end
            local shown = frame.window(#catalog.desktops, visible, math.floor(math.max(1, selected_desktop)), 0)
            for slot = 1, shown.capacity do
                local desktop = catalog.desktops[shown.offset + slot]
                if not desktop then break end
                local key = model.desktop_key(desktop.workspace_id, desktop.desktop_id)
                local session = model.session(state, selected.node_id, desktop.workspace_id, desktop.desktop_id)
                local workspace_label = workspace_labels[desktop.workspace_id] or names.label(desktop.workspace_id)
                local display_label = desktop.label ~= "" and desktop.label or (display_labels[desktop.desktop_id] or names.label(desktop.desktop_id))
                local item = display_label .. "  workspace " .. workspace_label
                if desktop.controller == nil then item = item .. "  controller unknown"
                elseif desktop.controller ~= "" then item = item .. "  controlled by " .. desktop.controller
                else item = item .. "  available to control" end
                if desktop.observers ~= nil and desktop.observers > 0 then item = item .. "  observers " .. tostring(desktop.observers) end
                if session then
                    item = item .. "  your " .. session.mode .. " session"
                    if state.technical then item = item .. " " .. session.session_id end
                end
                if state.technical then item = item .. "  workspace " .. desktop.workspace_id .. "  display " .. desktop.desktop_id end
                lines[#lines + 1] = item
                line_keys[#line_keys + 1] = key
            end
        end
        for index, value in ipairs(lines) do
            if index > desktop_rows - 1 then break end
            local key = line_keys[index]
            if key == "" then frame.line(painter, y + index, value, index == 1 and theme.muted or theme.text)
            else
                frame.row(painter, y + index, value, state.selected_desktop == key, "desktop", index, key, nil, state.pane == "desktops")
            end
        end
    end
    local idle = state.pending == nil
    local desktop = model.selected_desktop(state)
    if height >= 4 then
        frame.actions(painter, height - 1, {
            {kind = "open", label = "Open", enabled = selected ~= nil and not selected.client_only and catalog == nil, primary = true},
            {kind = "control", label = "Control", enabled = desktop ~= nil and idle and model.can_control(state)},
            {kind = "observe", label = "Observe", enabled = desktop ~= nil and idle, primary = catalog ~= nil},
            {kind = "refresh", label = "Refresh", enabled = idle},
            {kind = "technical", label = state.technical and "Hide details" or "Details", enabled = true},
        })
    end
    local message = status
    if message == "" then message = state.outcome end
    if message == "" and state.pending then message = "Waiting for the desktop owner…" end
    if message == "" and state.membership_detail ~= "" then message = "Membership: " .. state.membership_detail end
    frame.footer(painter, message, HINTS)
    return {rows = frame.rows(painter), hits = painter.hits, capacity = window.capacity, offset = window.offset}
end
return M
