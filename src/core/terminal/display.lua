-- MIT. Physical output belongs to the stable owner; presenters receive a viewport.
local tty = require("tty")
local chrome = require("chrome")
type Display = {output: tty.Surface, view: tty.Viewport, width: integer, height: integer, last_rows: {string}}
local M = {}
local function viewport(width: integer, height: integer): tty.Viewport
    local view, err = tty.viewport({width = width, height = height})
    if not view then error(tostring(err)) end
    return view
end
function M.open(): Display
    assert(tty.start())
    local output, err = tty.surface({alternate_screen = true, hide_cursor = true, synchronized_output = true})
    if not output then tty.stop(); error(tostring(err)) end
    local result: Display? = nil
    local function initialize()
        assert(tty.mouse(true))
        local width, height = tty.screen_size()
        -- Show the boot frame before waiting for a database or any child process.
        assert(output:present(chrome.boot(width, height), {cursor = {x = 1, y = 1, visible = false}}))
        result = {output = output, view = viewport(width, height), width = width, height = height, last_rows = {}}
    end
    local ready, failure = pcall(initialize)
    if not ready then output:close(); tty.stop(); error(tostring(failure)) end
    if not result then output:close(); tty.stop(); error("Display initialization returned no resources") end
    return result
end
function M.replace(value: Display)
    value.view:close()
    value.view = viewport(value.width, value.height)
end
-- A supervised handoff retires the returned viewport only after host revocation.
function M.stage(value: Display): tty.Viewport
    local previous = value.view
    value.view = viewport(value.width, value.height)
    return previous
end
function M.resize(value: Display, width: integer, height: integer)
    value.width, value.height = width, height
    value.view:resize(width, height)
end
function M.present(value: Display): boolean
    local snapshot = value.view:snapshot()
    if not snapshot or #snapshot.rows ~= value.height then return false end
    local cursor = snapshot.cursor
    if cursor then
        value.output:present(snapshot.rows, {cursor = {x = cursor.x, y = cursor.y, visible = cursor.visible}})
    else value.output:present(snapshot.rows) end
    value.last_rows = snapshot.rows
    return true
end
function M.paused(value: Display, emergency: boolean?)
    local canvas = tty.canvas(value.width, value.height)
    canvas:clear(" ")
    for y = 1, value.height do canvas:put(1, y, value.last_rows[y] or "", value.width) end
    canvas:put(1, value.height, "\27[38;2;255;201;99;48;2;23;32;44m"
        .. (emergency and " Desktop paused. F12 Retry / Ctrl+Q Emergency exit" or " Desktop paused. F12 Retry / Ctrl+Q Exit")
        .. string.rep(" ", value.width) .. "\27[0m", value.width)
    value.output:present(canvas:rows(), {cursor = {x = 1, y = 1, visible = false}})
end
function M.close(value: Display)
    value.view:close()
    value.output:close()
    tty.stop()
end
return M
