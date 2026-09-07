-- Draw a value snapshot. This library cannot launch, message or resize apps.
local tty = require("tty")
local model = require("model")
local layout = require("layout")
local appearance = require("appearance")
local chrome = require("chrome")
local menu = require("menu")
local bar = require("bar")
local window_chrome = require("window_chrome")
type Cursor = {x: integer, y: integer, visible: boolean}
type Content = {rows: {string}, cursor: Cursor?}
type TabHit = {id: string, x: integer, width: integer, action: string?}
type Frame = {rows: {string}, tabs: {TabHit}, cursor: Cursor}
local M = {}
local function styled(style: string, text: string): string return style .. text .. "\27[0m" end

function M.draw(scene: model.Scene, order: {string}, contents: {[string]: Content},
    capture: layout.Capture?, preview: model.Rect?, status: string, label: string,
    preferences: appearance.Preferences?, start: menu.State?, initial: boolean?, catalog: {menu.Descriptor}?): Frame
    local prefs = preferences or appearance.defaults()
    local theme = appearance.theme(prefs.theme)
    local FRAME = appearance.style(theme.border, theme.surface)
    local width, height = scene.width, scene.height
    local canvas = tty.canvas(width, height)
    local cursor: Cursor = {x = 1, y = 1, visible = false}
    chrome.background(canvas, width, height, prefs)
    if #model.visible(scene) == 0 then chrome.welcome(canvas, width, height, prefs, false) end
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
            if content then
                for y = 1, body.height do canvas:put(body.x, body.y + y - 1, content.rows[y] or "", body.width) end
                local caret = content.cursor
                if win.id == scene.focus and not capture and caret and caret.visible
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
        local strip = bar.draw(scene, order, status, label, prefs, start ~= nil)
        hits = strip.hits
        canvas:put(1, 1, strip.text, width)
    end
    if start then
        local items = menu.entries(start, scene, initial == true, catalog)
        local panel = menu.panel(width, height, #items, start)
        menu.draw(canvas, panel, menu.fit(start, panel, #items), items, prefs)
        cursor.visible = false
    end
    return {rows = canvas:rows(), tabs = hits, cursor = cursor}
end
return M
