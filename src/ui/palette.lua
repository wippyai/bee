-- MIT. A command palette: a fuzzy subsequence score, the ranked choices for
-- a query and the palette overlay that shows them.
local frame = require("frame")
local M = {}

-- One command palette choice.
type Choice = {label: string, key: string?, note: string?}
type Palette = {query: string, choices: {Choice}, selected: integer, offset: integer}

-- A subsequence match score for a command palette: nil when query's
-- characters (case-folded) do not all appear in order within text, else a
-- score where a lower number ranks a tighter, earlier match higher.
function M.fuzzy(query: string, text: string): integer?
    if query == "" then return 0 end
    local needle = query:lower()
    local haystack = text:lower()
    local at = 1
    local first: integer? = nil
    local last = 0
    for position = 1, #needle do
        local found = haystack:find(needle:sub(position, position), at, true)
        if not found then return nil end
        first = first or found
        last = found
        at = found + 1
    end
    return (last - (first or 1)) + (first or 1)
end

-- The palette choices for query over labels: every label that fuzzy matches,
-- best match first and in list order among equal scores, each keyed by its label.
function M.ranked(query: string, labels: {string}): {Choice}
    local scored: {{score: integer, order: integer, label: string}} = {}
    for order, label in ipairs(labels) do
        local score = M.fuzzy(query, label)
        if score then scored[#scored + 1] = {score = score, order = order, label = label} end
    end
    table.sort(scored, function(a, b)
        if a.score ~= b.score then return a.score < b.score end
        return a.order < b.order
    end)
    local choices: {Choice} = {}
    for _, item in ipairs(scored) do choices[#choices + 1] = {label = item.label, key = item.label} end
    return choices
end

-- A command palette overlay: a modal titled "Command Palette" sized to
-- width by height, the query on its first content row with a block caret,
-- and the choices below as selectable rows carrying hit kind "choice" and
-- each choice's key. An empty choices list draws the empty state instead of
-- a list. Returns the visible window of choices.
function M.palette(painter: frame.Painter, width: integer, height: integer, value: Palette): frame.Window
    local content = frame.modal(painter, width, height, "Command Palette")
    if content.width <= 0 or content.height <= 0 then return {offset = 0, capacity = 0} end
    frame.put(painter, content.x, content.y, "› " .. value.query .. "█", content.width, painter.theme.text)
    if content.height < 3 then return {offset = 0, capacity = 0} end
    if #value.choices == 0 then
        frame.empty(painter, content.y + 2, "No matches", nil, {x = content.x, y = content.y, width = content.width, height = content.height})
        return {offset = 0, capacity = 0}
    end
    local first = content.y + 2
    local last = content.y + content.height - 1
    local window = frame.window(#value.choices, last - first + 1, value.selected, value.offset)
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local choice = value.choices[index]
        if not choice then break end
        local text = choice.label .. ((choice.note and choice.note ~= "") and ("  " .. choice.note) or "")
        frame.row(painter, first + slot - 1, text, index == value.selected, "choice", index, choice.key or "", nil, true, nil, content)
    end
    return window
end

return M
