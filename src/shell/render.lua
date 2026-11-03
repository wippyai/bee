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
local popup = require("popup")
local copy = require("copy")
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
type Overlays = {reviews: {[string]: {title: string, approval_id: string}}?, alert: Alert?, alert_popup: boolean?, start: menu.State?, catalog: {menu.Descriptor}?, destinations: {menu.Destination}?, editor: title_editor.State?,
    modal: dialog.State?, copy: copy.Overlay?, workspaces: workspace_menu.Menu?}

function M.draw(scene: model.Scene, order: {string}, contents: {[string]: Content},
    capture: layout.Capture?, preview: model.Rect?, status: string, label: string,
    preferences: appearance.Preferences, overlays: Overlays): Frame
    local prefs = preferences
    local theme = prefs.theme
    local start, catalog = overlays.start, overlays.catalog
    local editor, modal, overlay, workspaces = overlays.editor, overlays.modal, overlays.copy, overlays.workspaces
    local FRAME = appearance.style(theme.border, theme.surface)
    local width, height = scene.width, scene.height
    local painter = frame.new(width, height, prefs)
    local canvas = painter.canvas
    local cursor: Cursor = {x = 1, y = 1, visible = false}
    local selected_style = appearance.style(appearance.selection_text(theme), appearance.selection_background(theme))
    -- A mark's cells show plain text, so a styled slice cannot reset its highlight.
    local MARKS = {selection = selected_style, label = selected_style .. "\27[1m", cursor = "\27[7m", token = "\27[4m"}
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
            local frozen = overlay and overlay.id == win.id and overlay.width == body.width and overlay.height == body.height
            if content or frozen then
                local rows: {string} = {}
                if frozen and overlay then rows = overlay.rows
                elseif content then rows = content.rows end
                for y = 1, body.height do canvas:put(body.x, body.y + y - 1, rows[y] or "", body.width) end
                if frozen and overlay then
                    for _, mark in ipairs(overlay.marks) do
                        local cells = mark.last - mark.first + 1
                        local shown = mark.text or text.plain(text.cut(rows[mark.y] or "", mark.first - 1, mark.last))
                        if shown == "" then shown = " " end
                        canvas:put(body.x + mark.first - 1, body.y + mark.y - 1, MARKS[mark.role] .. shown .. "\27[0m", cells)
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
            local review = overlays.reviews and overlays.reviews[win.id]
            if review and body.height > 0 then
                local suffix = " · F4 review"
                local title = tty.text.truncate(review.title, math.floor(math.max(1, body.width - tty.text.width("Needs you: " .. suffix))), "…")
                local label = "Needs you: " .. title .. suffix
                canvas:put(body.x, body.y, appearance.style(theme.warn, theme.surface) .. tty.text.truncate(label, body.width, "…"), body.width)
                if cursor.y == body.y then cursor.visible = false end
            end
            if body.x ~= rect.x then window_chrome.draw(canvas, win, rect, win.id == scene.focus, theme) end
        end
    end
    local hits: {TabHit} = {}
    if height >= 3 then
        local strip = bar.draw(scene, order, status, label, prefs, start ~= nil and start.kind == nil, overlays.alert, overlays.alert_popup ~= false)
        hits = strip.hits
        canvas:put(1, 1, strip.text, width)
    end
    local alert = overlays.alert
    if alert and (alert.count > 0 or alert.failed or alert.installed) and overlays.alert_popup ~= false and width >= 24 and height >= 8 then
        local card_width = math.floor(math.min(54, width - 2))
        local rect: frame.Rect = {x = width - card_width, y = 3, width = card_width, height = 5}
        for y = rect.y, rect.y + rect.height - 1 do
            canvas:put(rect.x, y, styled(FRAME, string.rep(" ", rect.width)), rect.width)
        end
        local inner = frame.panel(painter, rect, alert.failed and "Installation failed" or (alert.installed and "Installed" or "Needs you"), (alert.failed or alert.installed) and "" or (tostring(alert.count) .. " pending"))
        frame.put(painter, inner.x, inner.y, alert.title, inner.width, theme.text)
        frame.put(painter, inner.x, inner.y + 2, alert.installed and "F4 Open" or "F4 Open request", inner.width, theme.accent)
        hits[#hits + 1] = {id = alert.id, x = rect.x, y = rect.y, width = rect.width, height = rect.height, action = "attention"}
    end
    if start then
        local items = menu.entries(start, scene, catalog, overlays.destinations)
        local panel = menu.panel(width, height, items, start)
        popup.draw(canvas, panel, popup.fit(start, panel, items), items, prefs.theme)
        cursor.visible = false
    end
    if workspaces then
        workspace_menu.draw(canvas, width, height, prefs, workspaces)
        cursor.visible = false
    end
    if editor then cursor = title_editor.draw(canvas, editor, width, height, prefs) end
    if modal then cursor = dialog.draw(canvas, modal, width, height, prefs) end
    if overlay then cursor.visible = false end
    return {rows = frame.rows(painter, theme.ground), tabs = hits, cursor = cursor}
end
return M
