-- SPDX-License-Identifier: MIT
-- Read-only shell identity. Values come from the trusted desktop bootstrap;
-- this presentation neither discovers peers nor grants attachment authority.
local tty = require("tty")
local appearance = require("appearance")
local names = require("names")
type Info = {node: string, workspace: string, display: string, hive: string, attachments: string, details: boolean?}
local M = {}
local function line(value: unknown, limit: integer): string?
    if type(value) ~= "string" or value == "" or #value > limit or value:find("%c") then return nil end
    return value
end
function M.new(owner: string, workspace: string, display: unknown, supervisor: unknown): Info
    local node = owner:match("^{([^@|}]+)@[^|}]+|[^}]+}$") or "Local node"
    local selected = line(supervisor, 160)
    return {node = node, workspace = workspace, display = line(display, 64) or "Current session",
        hive = selected and "Supervisor ready" or "Not reported", attachments = "Not reported"}
end
function M.observe(info: Info, value: unknown): boolean
    if type(value) ~= "table" or value.version ~= 1 or value.display_id ~= info.display then return false end
    for key in pairs(value) do
        if key ~= "version" and key ~= "display_id" and key ~= "controller" and key ~= "observers" then return false end
    end
    if type(value.controller) ~= "boolean" or type(value.observers) ~= "number"
        or value.observers ~= math.floor(value.observers) or value.observers < 0 or value.observers > 16 then return false end
    local status = value.controller and "Controlled" or "Uncontrolled"
    if value.observers > 0 then
        status = status .. " · " .. tostring(value.observers) .. (value.observers == 1 and " observer" or " observers")
    end
    if status == info.attachments then return false end
    info.attachments = status
    return true
end
function M.toggle_details(info: Info)
    info.details = not info.details
end
type Geometry = {left: integer, size: integer, rows: integer}
local function geometry(width: integer, height: integer, details: boolean?): Geometry
    local size = math.floor(math.min(44, width - 2))
    local rows = math.floor(math.min(details and 16 or 14, height - 2))
    return {left = width - size, size = size, rows = rows}
end
function M.contains(width: integer, height: integer, info: Info, x: integer, y: integer): boolean
    local rect = geometry(width, height, info.details)
    local left, size, rows = rect.left, rect.size, rect.rows
    return width >= 12 and height >= 4 and x >= left and x < left + size and y >= 2 and y < 2 + rows
end
function M.details_hit(width: integer, height: integer, info: Info, x: integer, y: integer): boolean
    local rect = geometry(width, height, info.details)
    local left, rows = rect.left, rect.rows
    return rows >= 3 and M.contains(width, height, info, x, y)
        and y == rows and x >= left + 2 and x < left + 15
end
function M.draw(canvas: tty.Canvas, width: integer, height: integer, preferences: appearance.Preferences, info: Info, ready: boolean)
    if width < 12 or height < 4 then return end
    local theme = appearance.theme(preferences.theme)
    local rect = geometry(width, height, info.details)
    local left, size, rows = rect.left, rect.size, rect.rows
    local top = 2
    local normal = appearance.style(theme.text, theme.surface)
    local muted = appearance.style(theme.muted, theme.surface)
    local accent = appearance.style(theme.accent, theme.surface)
    local border = appearance.style(theme.border, theme.surface)
    local reset = "\27[0m"
    for y = top, top + rows - 1 do canvas:put(left, y, normal .. string.rep(" ", size) .. reset, size) end
    canvas:put(left, top, border .. "╭" .. string.rep("─", size - 2) .. "╮" .. reset, size)
    canvas:put(left, top + rows - 1, border .. "╰" .. string.rep("─", size - 2) .. "╯" .. reset, size)
    for y = top + 1, top + rows - 2 do
        canvas:put(left, y, border .. "│" .. reset, 1)
        canvas:put(left + size - 1, y, border .. "│" .. reset, 1)
    end
    local function put(row: integer, text: string, style: string)
        if row > 0 and row < rows - 1 then canvas:put(left + 2, top + row, style .. tty.text.truncate(text, size - 4, "…") .. reset, size - 4) end
    end
    local function pair(row: integer, label: string, value: string)
        local space = math.floor(math.max(0, size - 5 - tty.text.width(label)))
        local right = tty.text.truncate(value, space, "…")
        put(row, label, muted)
        if row > 0 and row < rows - 1 and space > 0 then
            canvas:put(left + size - 2 - tty.text.width(right), top + row, normal .. right .. reset, tty.text.width(right))
        end
    end
    local function rule(row: integer)
        put(row, string.rep("─", size - 4), border)
    end
    put(1, "CONNECTION", accent)
    if rows < 13 then
        pair(2, "HIVE", info.hive)
        pair(3, "NODE", info.node)
        pair(4, "ATTACH", info.attachments)
        put(5, "WORKSPACE  " .. names.label(info.workspace), normal)
        put(6, "DISPLAY    " .. names.label(info.display), normal)
        put(7, tostring(width) .. " × " .. tostring(height) .. "  ·  " .. (ready and "Ready" or "Loading"), muted)
    else
        pair(2, "HIVE", info.hive)
        pair(3, "NODE", info.node)
        pair(4, "ATTACH", info.attachments)
        rule(5)
        pair(6, "WORKSPACE", ready and "Ready" or "Loading")
        put(7, names.label(info.workspace), normal)
        local shift = 0
        if info.details and rows >= 16 then
            put(8, info.workspace, muted)
            shift = 1
        end
        rule(8 + shift)
        pair(9 + shift, "DISPLAY", tostring(width) .. " × " .. tostring(height))
        put(10 + shift, names.label(info.display), normal)
        if info.details and rows >= 16 then put(12, info.display, muted) end
    end
    put(rows - 2, (info.details and "‹ Less [D]" or "› Details [D]") .. "     F9 / Esc close", muted)
end
return M
