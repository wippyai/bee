-- MIT. Agent profile choices use the display's appearance and bounded text.
local tty = require("tty")
local appearance = require("appearance")
local text = require("text")
local selection = require("selection")
local M = {}
type Hit = {action: string, x: integer, y: integer, width: integer}
type Frame = {rows: {string}, first: integer, capacity: integer, hits: {Hit}}
function M.draw(width: integer, height: integer, preferences: appearance.Preferences,
    choices: selection.Choices, selected: integer, status: string): Frame
    local theme = appearance.theme(preferences.theme)
    local canvas = tty.canvas(width, height)
    local hits: {Hit} = {}
    local reset = "\27[0m"
    canvas:clear(appearance.style(theme.text, theme.surface) .. " " .. reset)
    local function line(y: integer, value: string, active: boolean, muted: boolean)
        if y < 1 or y > height then return end
        local fg = active and appearance.selection_text(theme) or (muted and theme.muted or theme.text)
        local bg = active and theme.accent or theme.surface
        local style = appearance.style(fg, bg)
        canvas:put(1, y, style .. string.rep(" ", width) .. reset, width)
        if width > 2 then canvas:put(2, y, style .. tty.text.truncate(text.bound(value, 512), width - 2, "…") .. reset, width - 2) end
    end
    line(1, "AGENT", false, false)
    if height >= 5 then line(2, "Choose a profile", false, true) end
    local show_summary = height >= 10
    local capacity = math.floor(math.max(0, height - (show_summary and 6 or 5)))
    if width <= 2 then capacity = 0 end
    local first = math.floor(math.max(1, selected - capacity + 1))
    for row = 1, capacity do
        local index = first + row - 1
        local choice = choices.items[index]
        if choice then
            local label = choice.title .. (choice.unavailable and " · Unavailable" or "")
            line(row + 2, label, index == selected, choice.unavailable ~= nil)
        end
    end
    if #choices.items == 0 and status == "" and height >= 5 then
        line(3, "No agent profiles are configured on this node", false, true)
    end
    local choice = choices.items[selected]
    if show_summary and choice and choice.summary then line(height - 3, choice.summary, false, true) end
    if height >= 3 then
        local x = 2
        for _, action in ipairs({{name = "open", label = " Open "}, {name = "new", label = " New "}, {name = "edit", label = " Edit "}, {name = "refresh", label = " Refresh "}, {name = "close", label = " Close "}}) do
            local size = #action.label
            if x + size - 1 <= width then
                local selection_action = action.name == "open" or action.name == "new" or action.name == "edit"
                local enabled = not selection_action or (choice ~= nil and capacity > 0
                    and (action.name ~= "open" or not choice.unavailable))
                canvas:put(x, height - 1, appearance.style(enabled and appearance.selection_text(theme) or theme.muted,
                    enabled and theme.accent or theme.surface) .. action.label .. reset, size)
                if enabled then hits[#hits + 1] = {action = action.name, x = x, y = height - 1, width = size} end
            end
            x = x + size + 1
        end
    end
    local message = status
    if message == "" and choice and choice.unavailable then message = choice.unavailable end
    if message == "" and choices.unavailable > 0 then message = tostring(choices.unavailable) .. " profiles unavailable" end
    if height >= 2 then line(height, message, false, true) end
    return {rows = canvas:rows(), first = first, capacity = capacity, hits = hits}
end
return M
