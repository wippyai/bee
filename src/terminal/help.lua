-- MIT. Desktop keyboard help uses the same guide as application frames.
local frame = require("frame")
local appearance = require("appearance")
local M = {}
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, menu: frame.Menu): frame.View
    local painter = frame.new(width, height, preferences)
    frame.header(painter, "BEE")
    frame.footer(painter, "Each application also has ? help in its footer", frame.hints({
        {key = "F1", verb = "start menu"}, {key = "Alt+Tab", verb = "switch apps"},
        {key = "Ctrl+W", verb = "close window"}, {key = "F11", verb = "maximize or restore"},
        {key = "F12", verb = "rejoin display"}, {key = "Ctrl+Q", verb = "detach Bee"}, {key = "Esc", verb = "back"}}))
    local shown: frame.View = {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
    frame.render(shown, menu, preferences)
    if menu.mode == "" then menu.mode = "help"; frame.render(shown, menu, preferences) end
    return shown
end
return M
