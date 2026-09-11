-- SPDX-License-Identifier: MIT
-- Read-only shell identity. Values come from the trusted desktop bootstrap;
-- this presentation neither discovers peers nor grants attachment authority.
local tty = require("tty")
local appearance = require("appearance")
local names = require("names")
type Info = {node: string, workspace: string, display: string, hive: string, supervisor: string?}
local M = {}
local function line(value: unknown, limit: integer): string?
    if type(value) ~= "string" or value == "" or #value > limit or value:find("%c") then return nil end
    return value
end
function M.new(owner: string, workspace: string, display: unknown, supervisor: unknown): Info
    local node = owner:match("^{([^@|}]+)@[^|}]+|[^}]+}$") or "Local node"
    local selected = line(supervisor, 160)
    return {node = node, workspace = workspace, display = line(display, 64) or "Current session",
        hive = selected and "Service running" or "Not reported", supervisor = selected}
end
function M.draw(canvas: tty.Canvas, width: integer, height: integer, preferences: appearance.Preferences, info: Info, ready: boolean)
    if width < 12 or height < 4 then return end
    local theme = appearance.theme(preferences.theme)
    local size = math.floor(math.min(48, width - 2))
    local rows = math.floor(math.min(16, height - 2))
    local left, top = width - size, 2
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
        if row < rows - 1 then canvas:put(left + 2, top + row, style .. tty.text.truncate(text, size - 4, "…") .. reset, size - 4) end
    end
    if rows < 16 then
        put(1, "CONNECTION", accent)
        put(2, "Hive  " .. info.hive, normal)
        put(3, "Node  " .. info.node, normal)
        put(4, "Workspace  " .. names.label(info.workspace), normal)
        put(5, "Display  " .. names.label(info.display), normal)
        put(6, tostring(width) .. " × " .. tostring(height) .. "  ·  F9 / Esc close", muted)
        return
    end
    put(1, "CONNECTION", accent)
    put(3, "HIVE       " .. info.hive, normal)
    put(5, "NODE       Running", muted)
    put(6, info.node, normal)
    put(8, "WORKSPACE  " .. (ready and "Ready" or "Loading"), muted)
    put(9, names.label(info.workspace), normal)
    put(10, info.workspace, muted)
    put(11, "DISPLAY    " .. tostring(width) .. " × " .. tostring(height), muted)
    put(12, names.label(info.display), normal)
    put(13, info.display, muted)
    put(14, "F9 / Esc close", muted)
end
return M
