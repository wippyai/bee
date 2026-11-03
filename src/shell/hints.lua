-- MIT. Quick copy: the copyable tokens in a window's text, each with a hint
-- of one or two letters the person types to copy it. PATTERNS declares what
-- counts as a token; earlier patterns win where tokens overlap.
local tty = require("tty")
local text = tty.text

-- A token covers cells first to last (one-based, inclusive) of row y, or
-- rows y to finish for a code block; label shows over its first cells.
type Token = {kind: string, y: integer, finish: integer, first: integer, last: integer, text: string, label: string}

-- A pattern finds tokens in one row: find is a Lua pattern whose captures
-- are the token's start position and its text; the row
-- is searched with one space around it, so a pattern may ask for a
-- separator on either side. trim
-- removes trailing punctuation that ends a sentence rather than the token;
-- min and max bound its length in bytes; any lists patterns of which the
-- token must match at least one, all those it must match each. bounded
-- says the match ends with the separator after the token, which may begin
-- the next one.
type Pattern = {kind: string, find: string, trim: string?, min: integer?, max: integer?, any: {string}?, all: {string}?,
    bounded: boolean?}

local M = {}

M.PATTERNS = {
    {kind = "url", find = "()(%a[%w+.-]*://[^%s\"'`<>]+)", trim = "[%.,;:!%?%)%]}>]+$"},
    {kind = "uuid", find = "[^%x]()(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)[^%x]", bounded = true},
    {kind = "path", find = "()([~%.%w_@+%-]*/[%w_@+%-%./:]*[%w_@+%-/])", trim = ":$",
        any = {"^[~%./]", "%.%w+$", "%.%w+:%d+"}},
    {kind = "registry", find = "[^%w_]()(%a[%w_]*%.[%w_%.]*:[%a_][%w_%.]*)"},
    {kind = "sha", find = "[^%w]()([0-9a-f]+)[^%w]", bounded = true, min = 7, max = 40, all = {"%d", "%a"}},
    {kind = "id", find = "[^%w_%-]()([%w][%w_%-]*[%w])[^%w_%-]", bounded = true, min = 8, max = 64, all = {"%d", "%a"}},
    {kind = "quoted", find = "\"()([^\"]+)\""},
    {kind = "quoted", find = "`()([^`]+)`"},
    {kind = "quoted", find = "%W'()([^']+)'%W", bounded = true},
} :: {Pattern}

-- ERRORS mark a whole line as an error line to copy.
M.ERRORS = {"[Ee]rror", "ERROR", "[Ff]ailed", "FAIL", "[Pp]anic", "Traceback", "[Ee]xception"}

-- ALPHABET orders hint letters, home row first.
M.ALPHABET = "asdfghjklqwertyuiopzxcvbnm"
local LETTERS = #M.ALPHABET

-- labels returns count prefix-free hints: single letters while they last,
-- then two-letter hints whose first letters are the alphabet's last ones.
function M.labels(count: integer): {string}
    local found: {string} = {}
    local singles = count <= LETTERS and count or math.floor(math.max(0, (LETTERS * LETTERS - count) / (LETTERS - 1)))
    for index = 1, math.min(singles, count) do found[#found + 1] = M.ALPHABET:sub(index, index) end
    for prefix = singles + 1, LETTERS do
        for suffix = 1, LETTERS do
            if #found >= count then return found end
            found[#found + 1] = M.ALPHABET:sub(prefix, prefix) .. M.ALPHABET:sub(suffix, suffix)
        end
    end
    return found
end

local function cells(row: string, index: integer): integer
    return text.width(row:sub(1, index - 1)) + 1
end

local function accepted(pattern: Pattern, value: string): boolean
    if pattern.min and #value < pattern.min then return false end
    if pattern.max and #value > pattern.max then return false end
    for _, required in ipairs(pattern.all or {}) do
        if not value:find(required) then return false end
    end
    local any = pattern.any
    if not any then return true end
    for _, wanted in ipairs(any) do
        if value:find(wanted) then return true end
    end
    return false
end

local function overlaps(taken: {Token}, y: integer, first: integer, last: integer): boolean
    for _, token in ipairs(taken) do
        if token.y == y and token.finish == y and first <= token.last and last >= token.first then return true end
    end
    return false
end

-- spans finds the pattern tokens of plain row y.
local function spans(taken: {Token}, row: string, y: integer)
    local padded = " " .. row .. " "
    for _, pattern in ipairs(M.PATTERNS) do
        local from = 1
        while true do
            local _, stop, first_index, found = padded:find(pattern.find, from)
            if not stop then break end
            from = pattern.bounded and stop or stop + 1
            local value = found :: string
            if pattern.trim then value = (value:gsub(pattern.trim, "")) end
            local start = (first_index :: integer) - 1
            if value ~= "" and accepted(pattern, value) then
                local first = cells(row, start)
                local last = first + text.width(value) - 1
                if not overlaps(taken, y, first, last) then
                    taken[#taken + 1] = {kind = pattern.kind, y = y, finish = y, first = first, last = last, text = value, label = ""}
                end
            end
        end
    end
end

local function trim(value: string): string return (value:gsub("^%s+", ""):gsub("%s+$", "")) end

-- tokens finds the tokens of rows, plain text rows of one window: code
-- blocks between fences, pattern tokens, and error lines no token starts on.
function M.tokens(rows: {string}): {Token}
    local taken: {Token} = {}
    local open: integer? = nil
    local indent = 0
    for y, row in ipairs(rows) do
        local fence = row:find("```", 1, true)
        if fence and open then
            local body: {string} = {}
            for inner = open + 1, y - 1 do body[#body + 1] = (rows[inner]:sub(indent + 1):gsub("%s+$", "")) end
            local start = open
            local opening = rows[start]
            local first = cells(opening, indent + 1)
            taken[#taken + 1] = {kind = "code", y = start, finish = y, first = first, last = first + 2,
                text = table.concat(body, "\n"), label = ""}
            open = nil
        elseif fence then
            open, indent = y, fence - 1
        end
    end
    for y, row in ipairs(rows) do spans(taken, row, y) end
    for y, row in ipairs(rows) do
        local line = trim(row)
        local errored = false
        for _, marker in ipairs(M.ERRORS) do
            if line:find(marker) then errored = true; break end
        end
        local start = row:find("%S")
        if errored and start then
            local first = cells(row, start)
            if not overlaps(taken, y, first, first + 1) then
                taken[#taken + 1] = {kind = "error", y = y, finish = y, first = first, last = first + text.width(line) - 1,
                    text = line, label = ""}
            end
        end
    end
    -- Hints go bottom first, where the latest output is; the same text keeps
    -- one hint.
    table.sort(taken, function(a: Token, b: Token): boolean
        if a.y ~= b.y then return a.y > b.y end
        return a.first < b.first
    end)
    local distinct: {[string]: boolean} = {}
    local count = 0
    for _, token in ipairs(taken) do
        if not distinct[token.text] then distinct[token.text] = true; count = count + 1 end
    end
    local labels = M.labels(count)
    local given: {[string]: string} = {}
    local next_label = 1
    for _, token in ipairs(taken) do
        local label = given[token.text]
        if not label then
            label = labels[next_label] or ""
            next_label = next_label + 1
            given[token.text] = label
        end
        token.label = label
    end
    return taken
end

-- choose answers typed letters: the token whose hint they spell, and
-- whether they still begin a hint.
function M.choose(tokens: {Token}, typed: string): (Token?, boolean)
    local partial = false
    for _, token in ipairs(tokens) do
        if token.label == typed then return token, true end
        if token.label:sub(1, #typed) == typed then partial = true end
    end
    return nil, partial
end

return M
