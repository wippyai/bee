-- MIT. The short-lived Agent surface shown while a launch or continuation is admitted.
-- It has no process or workspace authority; it only renders bounded status.
local appearance = require("appearance")
local frame = require("frame")
local M = {}

function M.draw(width: integer, height: integer, preferences: appearance.Preferences, status: string,
    heading: string?, footer: string?): frame.View
    local painter = frame.new(width, height, preferences)
    frame.header(painter, "AGENT")
    frame.line(painter, 3, heading or "Restoring Agent", painter.theme.text)
    frame.line(painter, 5, status, painter.theme.text)
    if height >= 6 then frame.footer(painter, "", footer or "Esc or Ctrl+Q cancels recovery") end
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
end

-- A saved window that cannot be resumed ends; the person reads why and closes it.
function M.unresumable(width: integer, height: integer, preferences: appearance.Preferences, reason: string): frame.View
    local painter = frame.new(width, height, preferences)
    frame.header(painter, "AGENT")
    frame.line(painter, 3, "This Agent window cannot be resumed", painter.theme.text)
    frame.line(painter, 5, "Bee restarted, and " .. reason .. ".", painter.theme.text)
    frame.line(painter, 6, "Open a new Agent from the Start menu to continue.", painter.theme.muted)
    if height >= 8 then frame.footer(painter, "", "Enter or Esc closes it") end
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
end
function M.login(width: integer, height: integer, preferences: appearance.Preferences,
    notice: {code: "LOGIN_REQUIRED", provider: string, command: string}): frame.View
    local painter = frame.new(width, height, preferences)
    local provider = notice.provider:sub(1, 1):upper() .. notice.provider:sub(2)
    frame.header(painter, "AGENT")
    frame.line(painter, 3, provider .. " login needed", painter.theme.text)
    frame.line(painter, 5, "No saved login was found in this provider home.", painter.theme.text)
    frame.line(painter, 7, "Sign in: " .. notice.command, painter.theme.accent)
    frame.line(painter, 8, "You can continue to the provider's sign-in screen.", painter.theme.muted)
    if height >= 9 then frame.footer(painter, "", "Enter opens " .. provider .. " · Esc closes") end
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
end

return M
