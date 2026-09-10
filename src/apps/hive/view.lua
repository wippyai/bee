-- MIT. The Hive Manager frame: the Hive state, the nodes as membership and
-- their owners report them, the selected node's desktops, explicit control
-- and observe actions and the status line. A fixture source is named on
-- every frame. Every text comes through the model's bounding.
local tty = require("tty")
local appearance = require("appearance")
local model = require("model")
type Hit = {kind: string, index: integer, key: string, x: integer, y: integer, width: integer, height: integer}
type Frame = {rows: {string}, hits: {Hit}, capacity: integer, offset: integer}
local M = {}
local RESET = "\27[0m"
local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
function M.hit(hits: {Hit}, x: integer, y: integer): Hit?
    for _, hit in ipairs(hits) do
        if x >= hit.x and x < hit.x + hit.width and y >= hit.y and y < hit.y + hit.height then return hit end
    end
    return nil
end
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
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, offset: integer, status: string): Frame
    local theme = appearance.theme(preferences.theme)
    local canvas = tty.canvas(width, height)
    local hits: {Hit} = {}
    local function put(x: integer, y: integer, value: string, size: integer, fg: string?, bg: string?)
        if y >= 1 and y <= height and x >= 1 and size > 0 then
            canvas:put(x, y, appearance.style(fg or theme.text, bg or theme.surface) .. value .. RESET, size)
        end
    end
    local function line(y: integer, value: string, fg: string?, bg: string?)
        put(1, y, string.rep(" ", width), width, fg, bg)
        put(2, y, tty.text.truncate(value, maximum(0, width - 2), "…"), maximum(0, width - 2), fg, bg)
    end
    canvas:clear(appearance.style(theme.text, theme.surface) .. " " .. RESET)
    local title = "HIVE MANAGER"
    if state.source == "fixture" then title = title .. "   FIXTURE DATA, not a live Hive: " .. state.source_label end
    line(1, title, state.source == "fixture" and appearance.selection_text(theme) or theme.text, state.source == "fixture" and theme.accent or theme.surface)
    local hive_line = "Hive: unknown"
    if state.hive == "running" then hive_line = "Hive: supervisor running on this node"
    elseif state.hive == "unavailable" then hive_line = "Hive supervisor unavailable: " .. state.hive_detail end
    line(2, hive_line, theme.muted)
    if state.source ~= "fixture" and width >= 52 then
        local online, clients = 0, 0
        for _, node in ipairs(state.nodes) do
            if node.status == "reachable" then online = online + 1 end
            if node.client_only then clients = clients + 1 end
        end
        local summary = tostring(#state.nodes) .. (#state.nodes == 1 and " node · " or " nodes · ") .. tostring(online) .. " ready"
        if clients > 0 then summary = tostring(online) .. " ready · " .. tostring(clients) .. (clients == 1 and " display" or " displays") end
        local span = tty.text.width(summary)
        put(width - span, 1, summary, span, theme.accent)
    end
    local selected = model.selected(state)
    local catalog = model.catalog(state)
    local desktop_rows = 0
    if selected and height >= 12 then desktop_rows = math.floor(math.max(5, math.min(height - 8, state.technical and 12 or 8))) end
    local list_first = 4
    local list_last = height - 2 - desktop_rows
    local capacity = maximum(0, list_last - list_first + 1)
    local nodes = state.nodes
    local last = maximum(0, #nodes - capacity)
    local next_offset = math.floor(math.max(0, math.min(last, offset)))
    if selected then
        for index, node in ipairs(nodes) do
            if node.node_id == selected.node_id then
                if index <= next_offset then next_offset = index - 1 end
                if index > next_offset + capacity then next_offset = index - capacity end
            end
        end
    end
    local compact = width < 64
    local membership_width = compact and 7 or 12
    local show_address = state.technical and width >= 100
    local name_width = math.floor(math.max(8, math.min(40, width - (show_address and 46 or (membership_width + 22)))))
    local pattern = "%-4s %-" .. tostring(membership_width) .. "s %-" .. tostring(name_width) .. "s %-12s %s"
    line(3, string.format(pattern, "", compact and "LINK" or "MEMBERSHIP", "NODE", "BEE SERVICE", show_address and "ADDRESS" or ""), theme.muted)
    if #nodes == 0 then line(list_first, "No nodes reported", theme.muted) end
    for slot = 1, capacity do
        local node = nodes[next_offset + slot]
        if not node then break end
        local y = list_first + slot - 1
        local active = selected ~= nil and node.node_id == selected.node_id
        local focus = active and state.pane == "nodes"
        local fg = focus and appearance.selection_text(theme) or (active and theme.accent or theme.text)
        local bg = focus and theme.accent or theme.surface
        local name = node.label
        if state.technical and node.label ~= node.node_id then name = node.label .. " (" .. node.node_id .. ")" end
        local tail = show_address and node.addr or ""
        local label = string.format(pattern, node.is_local and "this" or "", node.member and "present" or "left",
            tty.text.truncate(name, name_width, "…"), status_word(node), tail)
        line(y, label, fg, bg)
        hits[#hits + 1] = {kind = "node", index = next_offset + slot, key = node.node_id, x = 1, y = y, width = width, height = 1}
    end
    if selected and desktop_rows > 0 then
        local y = list_last + 1
        put(1, y, string.rep("─", width), width, theme.border)
        local lines: {string} = {}
        local keys: {string} = {}
        local head = "Node " .. selected.label
        if selected.client_only then head = selected.label .. "  ·  Display client"
        elseif selected.status == "reachable" then
            head = head .. "  ·  Ready"
            if state.technical then head = head .. "  cluster " .. tostring(selected.cluster_size) .. "  sampled " .. selected.sampled_at end
        elseif selected.status == "unavailable" then head = head .. "  Bee service unavailable: " .. selected.detail end
        if state.technical and not selected.client_only then
            head = head .. "  Raft role " .. (selected.role ~= "" and selected.role or "unknown")
            head = head .. "  heap " .. bytes(selected.heap) .. "  goroutines " .. (selected.goroutines and tostring(selected.goroutines) or "-")
            if catalog and catalog.owner_generation ~= "" then head = head .. "  owner generation " .. catalog.owner_generation end
        end
        lines[#lines + 1] = head
        keys[#keys + 1] = ""
        if selected.client_only then
            lines[#lines + 1] = "Presents a desktop; does not host a Bee service"
            keys[#keys + 1] = ""
        elseif not catalog then
            lines[#lines + 1] = "Open the node to list its desktops"
            keys[#keys + 1] = ""
        elseif not catalog.available then
            lines[#lines + 1] = "Desktops unavailable: " .. catalog.reason
            keys[#keys + 1] = ""
        elseif #catalog.desktops == 0 then
            lines[#lines + 1] = "The owner lists no desktops"
            keys[#keys + 1] = ""
        else
            for _, desktop in ipairs(catalog.desktops) do
                local key = model.desktop_key(desktop.workspace_id, desktop.desktop_id)
                local session = state.sessions[key]
                local item = (desktop.label ~= "" and desktop.label or desktop.desktop_id) .. "  workspace " .. desktop.workspace_id
                if desktop.controller ~= "" then item = item .. "  controlled by " .. desktop.controller else item = item .. "  no controller" end
                if desktop.observers > 0 then item = item .. "  observers " .. tostring(desktop.observers) end
                if session then item = item .. "  your " .. session.mode .. " session " .. session.session_id end
                if state.technical then item = item .. "  desktop " .. desktop.desktop_id end
                lines[#lines + 1] = item
                keys[#keys + 1] = key
            end
        end
        for index, value in ipairs(lines) do
            if index > desktop_rows - 1 then break end
            local key = keys[index]
            local focus = key ~= "" and state.selected_desktop == key
            local fg = focus and state.pane == "desktops" and appearance.selection_text(theme) or (focus and theme.accent or theme.text)
            local bg = focus and state.pane == "desktops" and theme.accent or theme.surface
            line(y + index, value, index == 1 and theme.muted or fg, bg)
            if key ~= "" then hits[#hits + 1] = {kind = "desktop", index = index, key = key, x = 1, y = y + index, width = width, height = 1} end
        end
    end
    local actions_y = height - 1
    local x = 2
    local function button(kind: string, label: string, enabled: boolean)
        local size = tty.text.width(label)
        if x + size > width then return end
        put(x, actions_y, label, size, enabled and appearance.selection_text(theme) or theme.muted, enabled and theme.accent or theme.surface)
        if enabled then hits[#hits + 1] = {kind = kind, index = 0, key = "", x = x, y = actions_y, width = size, height = 1} end
        x = x + size + 1
    end
    local idle = state.pending == nil
    local desktop = model.selected_desktop(state)
    if height >= 4 then
        button("open", " Open ", selected ~= nil and not selected.client_only and catalog == nil)
        button("control", " Control ", desktop ~= nil and idle and model.can_control(state))
        button("observe", " Observe ", desktop ~= nil and idle)
        button("refresh", " Refresh ", idle)
        button("technical", state.technical and " Less " or " Details ", true)
    end
    local message = status
    if message == "" then message = state.outcome end
    if message == "" and state.pending then message = "Waiting for the desktop owner…" end
    if message == "" and state.membership_detail ~= "" then message = "Membership: " .. state.membership_detail end
    if message == "" then message = "↑↓ Choose node   Enter Open   Tab Displays   R Refresh" end
    line(height, message, theme.muted)
    return {rows = canvas:rows(), hits = hits, capacity = capacity, offset = next_offset}
end
return M
