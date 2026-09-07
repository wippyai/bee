-- MIT. Bounded rendering values; no journal or process authority.
local tty = require("tty")
local appearance = require("appearance")
local M = {}
function M.render(width: integer, height: integer, preferences: appearance.Preferences,
    thread: string, cursor: integer, status: string, lines: {string}, offset: integer,
    follow: boolean): {rows: {string}, offset: integer}
    local theme = appearance.theme(preferences.theme)
    local canvas = tty.canvas(width, height)
    canvas:clear(appearance.style(theme.text, theme.surface) .. " \27[0m")
    local function put(y: integer, text: string, fg: string)
        if width > 2 and y <= height then
            canvas:put(2, y, appearance.style(fg, theme.surface) .. tty.text.truncate(text, width - 2, "…") .. "\27[0m", width - 2)
        end
    end
    put(1, "SHARED UI CHECKS", theme.accent)
    put(2, thread .. "  ·  sequence " .. tostring(cursor), theme.muted)
    put(3, "[ Run checks ]  [ Replay ]", theme.accent)
    put(5, status, theme.text)
    local capacity = math.max(0, height - 7)
    if follow then offset = math.floor(math.max(0, #lines - capacity)) end
    offset = math.floor(math.max(0, math.min(offset, math.max(0, #lines - capacity))))
    for i = 1, capacity do
        local line = lines[offset + i]
        if line then put(6 + i, line, theme.text) end
    end
    return {rows = canvas:rows(), offset = offset}
end
return M
