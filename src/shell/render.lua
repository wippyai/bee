-- Draw a value snapshot. This library cannot launch, message or resize apps.
local tty = require("tty")
local frame = require("frame")
local title_editor = require("title_editor")
local dialog = require("dialog")
local model = require("model")
local layout = require("layout")
local appearance = require("appearance")
local chrome = require("chrome")
local menu = require("menu")
local selection = require("selection")
local bar = require("bar")
local window_chrome = require("window_chrome")
local workspace_menu = require("workspace_menu")
type Text = {cut: (string, integer, integer) -> string, plain: (string) -> string, width: (string) -> integer}
local text = tty.text
type Cursor = {x: integer, y: integer, visible: boolean}
type Content = {rows: {string}, cursor: Cursor?}
type Alert = bar.Alert
type TabHit = {id: string, x: integer, width: integer, action: string?, y: integer?, height: integer?}
type Frame = {rows: {string}, tabs: {TabHit}, cursor: Cursor}
local M = {}
local function styled(style: string, text: string): string return style .. text .. "\27[0m" end

-- Overlays drawn above the desktop, at most one of each.
type Overlays = {alert: Alert?, alert_popup: boolean?, start: menu.State?, catalog: {menu.Descriptor}?, destinations: {menu.Destination}?, editor: title_editor.State?,
    modal: dialog.State?, selection: selection.State?, workspaces: workspace_menu.Menu?}

function M.draw(scene: model.Scene, order: {string}, contents: {[string]: Content},
    capture: layout.Capture?, preview: model.Rect?, status: string, label: string,
    preferences: appearance.Preferences, overlays: Overlays): Frame
    local prefs = preferences
    local theme = prefs.theme
    local start, catalog = overlays.start, overlays.catalog
    local editor, modal, active_selection, workspaces = overlays.editor, overlays.modal, overlays.selection, overlays.workspaces
    local FRAME = appearance.style(theme.border, theme.surface)
    local width, height = scene.width, scene.height
    local painter = frame.new(width, height, prefs)
    local canvas = painter.canvas
    local cursor: Cursor = {x = 1, y = 1, visible = false}
    local selected_snapshot: selection.Snapshot? = active_selection and selection.snapshot(active_selection) or nil
    local selected_span = active_selection and selection.range(active_selection) or nil
    local selected_style = appearance.style(appearance.selection_text(theme), appearance.selection_background(theme))
    chrome.background(canvas, width, height, prefs)
    if #model.visible(scene) == 0 then
        chrome.welcome(canvas, width, height, prefs, false)
    end
    for _, win in ipairs(model.visible(scene)) do
        local rect = layout.rectangle(scene, win, capture, preview)
        local body = layout.interior(win, rect)
        for y = rect.y, rect.y + rect.height - 1 do
            canvas:put(rect.x, y, styled(FRAME, string.rep(" ", rect.width)), rect.width)
        end
        if win.mode == "collapsed" then
            window_chrome.draw(canvas, win, rect, win.id == scene.focus, theme)
        else
            local content = contents[win.id]
            local frozen = selected_snapshot and selected_snapshot.binding.view_id == win.id
                and selected_snapshot.binding.width == body.width and selected_snapshot.binding.height == body.height
            if content or frozen then
                local rows: {string} = {}
                if frozen and selected_snapshot then rows = selected_snapshot.rows
                elseif content then rows = content.rows end
                for y = 1, body.height do
                    local row = rows[y] or ""
                    canvas:put(body.x, body.y + y - 1, row, body.width)
                    if frozen and selected_span and y >= selected_span.start.y and y <= selected_span.finish.y then
                        local first = y == selected_span.start.y and selected_span.start.x - 1 or 0
                        local last = y == selected_span.finish.y and selected_span.finish.x or body.width
                        -- A selected ANSI slice must not reset its highlight.
                        -- Native cut retains cell boundaries; plain drops controls.
                        local slice = text.plain(text.cut(rows[y] or "", first, last))
                        local mark = selected_style
                        canvas:put(body.x + first, body.y + y - 1, mark .. slice .. "\27[0m", last - first)
                    end
                end
                local caret = content and content.cursor
                if win.id == scene.focus and not capture and not frozen and caret and caret.visible
                    and caret.x >= 1 and caret.x <= body.width and caret.y >= 1 and caret.y <= body.height then
                    cursor = {x = body.x + caret.x - 1, y = body.y + caret.y - 1, visible = true}
                end
            else
                canvas:put(body.x, body.y, styled(FRAME, "View unavailable"), body.width)
            end
            if body.x ~= rect.x then window_chrome.draw(canvas, win, rect, win.id == scene.focus, theme) end
        end
    end
    local hits: {TabHit} = {}
    if height >= 3 then
        local strip = bar.draw(scene, order, status, label, prefs, start ~= nil and start.kind == nil, overlays.alert)
        hits = strip.hits
        canvas:put(1, 1, strip.text, width)
    end
    local alert = overlays.alert
    if alert and alert.count > 0 and overlays.alert_popup ~= false and width >= 24 and height >= 8 then
        local card_width = math.floor(math.min(54, width - 2))
        local rect: frame.Rect = {x = width - card_width, y = 3, width = card_width, height = 5}
        for y = rect.y, rect.y + rect.height - 1 do
            canvas:put(rect.x, y, styled(FRAME, string.rep(" ", rect.width)), rect.width)
        end
        local inner = frame.panel(painter, rect, "Needs you", tostring(alert.count) .. " pending")
        frame.put(painter, inner.x, inner.y, alert.title, inner.width, theme.text)
        frame.put(painter, inner.x, inner.y + 2, "F4 Open request", inner.width, theme.accent)
        hits[#hits + 1] = {id = alert.id, x = rect.x, y = rect.y, width = rect.width, height = rect.height, action = "attention"}
    end
    if start then
        local items = menu.entries(start, scene, catalog, overlays.destinations)
        local panel = menu.panel(width, height, items, start)
        menu.draw(canvas, panel, menu.fit(start, panel, items), items, prefs)
        cursor.visible = false
    end
    if workspaces then
        workspace_menu.draw(canvas, width, height, prefs, workspaces)
        cursor.visible = false
    end
    if editor then cursor = title_editor.draw(canvas, editor, width, height, prefs) end
    if modal then cursor = dialog.draw(canvas, modal, width, height, prefs) end
    if selected_snapshot then cursor.visible = false end
    return {rows = frame.rows(painter, theme.ground), tabs = hits, cursor = cursor}
end
return M
