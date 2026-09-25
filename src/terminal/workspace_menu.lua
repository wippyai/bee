-- SPDX-License-Identifier: MIT
-- The display's workspace menu: one page of the node's workspace catalog at a
-- time, a label search, the choice of another workspace to show on this
-- display, and N for a new workspace, which the Workspaces viewer's create
-- flow makes. It holds only what its owner answered; switching is the owner's
-- request to the desktop bridge, and this menu only asks for it.
local tty = require("tty")
local appearance = require("appearance")
local names = require("names")
local contract = require("contract")
type Item = {workspace_id: string, label: string}
type Query = {label: string?, after: string?}
type Menu = {current: string, items: {Item}, selected: integer, after: string?, next_after: string?,
    back: {string}, query: string, editing: boolean, loading: string?, switching: string?, status: string}
-- create: the person asked for a new workspace; the presenter opens the
-- Workspaces viewer on its create flow.
type Response = {close: boolean, page: Query?, switch: string?, create: boolean}
type Panel = {x: integer, y: integer, width: integer, height: integer, capacity: integer}
local M = {}
M.MAX_ITEMS = 50
M.MAX_QUERY = 120
M.SWITCHED = "Switching this display"
-- A new workspace is made by the Workspaces viewer, opened on its create flow.
M.CREATE_APPLICATION = "bee.workspace.manager:app"
M.CREATE_ARGUMENT = "create"
local NONE: Response = {close = false, page = nil, switch = nil, create = false}
function M.new(current: string): Menu
    return {current = current, items = {}, selected = 1, after = nil, next_after = nil, back = {}, query = "",
        editing = false, loading = nil, switching = nil, status = ""}
end
-- The page this menu shows next; the owner's answer names the same request.
function M.request(menu: Menu, request_id: string): Query
    menu.loading = request_id
    return {label = menu.query ~= "" and menu.query or nil, after = menu.after}
end
-- The owner's answer to the pending page request; any other is ignored.
function M.apply(menu: Menu, value: unknown): boolean
    if type(value) ~= "table" or value.version ~= 1 or not menu.loading or value.request_id ~= menu.loading then return false end
    menu.loading = nil
    if value.error ~= nil then
        menu.status = "Workspaces unavailable: " .. (contract.text(value.error, 200) or "unknown error")
        return true
    end
    local items: {Item} = {}
    if type(value.items) == "table" then
        for index, raw in ipairs(value.items :: {unknown}) do
            if index > M.MAX_ITEMS or type(raw) ~= "table" then break end
            local id, label = contract.workspace_id(raw.workspace_id), contract.text(raw.label, 240)
            if id and label then items[#items + 1] = {workspace_id = id, label = label} end
        end
    end
    menu.items, menu.selected = items, 1
    menu.next_after = contract.text(value.next_after, 2200)
    menu.status = #items == 0 and "No workspaces match" or ""
    return true
end
-- The bridge's answer to this menu's switch request.
function M.switched(menu: Menu, value: unknown): boolean
    if type(value) ~= "table" or value.version ~= 1 or not menu.switching or value.request_id ~= menu.switching then return false end
    menu.switching = nil
    if value.error_code == "" then menu.status = M.SWITCHED
    else menu.status = "Switch refused: " .. (contract.text(value.error, 200) or tostring(value.error_code)) end
    return true
end
-- The name a person sees: the label, or the identity's name when unnamed.
function M.label(item: Item): string
    if item.label ~= "" then return item.label end
    return names.label(item.workspace_id)
end
local function move(menu: Menu, step: integer)
    if #menu.items == 0 then return end
    menu.selected = math.floor(math.max(1, math.min(#menu.items, menu.selected + step)))
end
function M.respond(menu: Menu, event: unknown, request_id: string): Response
    if type(event) ~= "table" or event.type ~= "key" or event.action == "release" then return NONE end
    local kind = tostring(event.key_type or "")
    local key = tostring(event.key or "")
    if menu.editing then
        if kind == "enter" then
            menu.editing, menu.after, menu.back = false, nil, {}
            return {close = false, page = M.request(menu, request_id), switch = nil, create = false}
        elseif kind == "esc" or kind == "escape" then menu.editing = false
        elseif kind == "backspace" then menu.query = menu.query:sub(1, math.floor(math.max(0, #menu.query - 1)))
        elseif (kind == "" or kind == "runes") and key ~= "" and not key:find("%c") and event.ctrl ~= true and event.alt ~= true
            and #menu.query + #key <= M.MAX_QUERY then
            menu.query = menu.query .. key
        end
        return NONE
    end
    if kind == "esc" or kind == "escape" then return {close = true, page = nil, switch = nil, create = false} end
    if kind == "up" then move(menu, -1)
    elseif kind == "down" then move(menu, 1)
    elseif kind == "pgdown" and menu.next_after and not menu.loading then
        menu.back[#menu.back + 1] = menu.after or ""
        menu.after = menu.next_after
        return {close = false, page = M.request(menu, request_id), switch = nil, create = false}
    elseif kind == "pgup" and #menu.back > 0 and not menu.loading then
        local previous = table.remove(menu.back)
        menu.after = previous ~= "" and previous or nil
        return {close = false, page = M.request(menu, request_id), switch = nil, create = false}
    elseif key == "/" then menu.editing = true
    elseif (key == "n" or key == "N") and event.ctrl ~= true and event.alt ~= true and not menu.switching then
        return {close = false, page = nil, switch = nil, create = true}
    elseif kind == "enter" then
        local item = menu.items[menu.selected]
        if not item or menu.switching then return NONE end
        if item.workspace_id == menu.current then menu.status = "This display shows that workspace"; return NONE end
        menu.switching = request_id
        menu.status = "Switching to " .. M.label(item)
        return {close = false, page = nil, switch = item.workspace_id, create = false}
    end
    return NONE
end
function M.panel(width: integer, height: integer): Panel
    local w = math.floor(math.min(56, width - 2))
    local h = math.floor(math.min(18, height - 2))
    local x = math.floor(math.max(1, width - w))
    return {x = x, y = 2, width = w, height = h, capacity = math.floor(math.max(0, h - 6))}
end
function M.available(width: integer, height: integer): boolean return width >= 24 and height >= 8 end
function M.draw(canvas: tty.Canvas, width: integer, height: integer, preferences: appearance.Preferences, menu: Menu)
    if not M.available(width, height) then return end
    local theme = appearance.theme(preferences.theme)
    local normal = appearance.style(theme.text, theme.surface)
    local muted = appearance.style(theme.muted, theme.surface)
    local accent = appearance.style(theme.accent, theme.surface)
    local border = appearance.style(theme.border, theme.surface)
    local chosen = appearance.style(appearance.selection_text(theme), theme.accent)
    local reset = "\27[0m"
    local panel = M.panel(width, height)
    local inside = panel.width - 2
    for y = panel.y, panel.y + panel.height - 1 do
        local edge = y == panel.y or y == panel.y + panel.height - 1
        local row = "│" .. string.rep(" ", inside) .. "│"
        if edge then row = (y == panel.y and "╭" or "╰") .. string.rep("─", inside) .. (y == panel.y and "╮" or "╯") end
        canvas:put(panel.x, y, border .. row .. reset, panel.width)
    end
    local function put(row: integer, text: string, style: string)
        canvas:put(panel.x + 2, panel.y + row, style .. tty.text.truncate(text, inside - 2, "…") .. reset, inside - 2)
    end
    put(1, "WORKSPACES", accent)
    local search = "Search: " .. menu.query .. (menu.editing and "▏" or "")
    put(2, search, menu.editing and normal or muted)
    -- The selected row stays in view.
    local offset = math.floor(math.max(0, menu.selected - panel.capacity))
    for row = 1, panel.capacity do
        local index = offset + row
        local item = menu.items[index]
        if item then
            local marker = item.workspace_id == menu.current and "● " or "  "
            local text = marker .. M.label(item) .. "  " .. item.workspace_id:sub(1, 8)
            put(2 + row, text, index == menu.selected and chosen or normal)
        end
    end
    put(panel.height - 3, "N  New workspace", muted)
    local footer = menu.loading and "Loading…" or menu.status
    if footer == "" then
        footer = "Enter switch · / search"
        if menu.next_after then footer = footer .. " · PgDn more" end
        if #menu.back > 0 then footer = footer .. " · PgUp back" end
        footer = footer .. " · Esc close"
    end
    put(panel.height - 2, footer, muted)
end
return M
