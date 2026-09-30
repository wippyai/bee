-- MIT. Syntax highlighter using tree-sitter with line numbers and range highlighting.
-- Reads file content, parses AST with runtime treesitter, and formats lines with
-- a gutter (line number, marker) and ANSI semantic colors.
local treesitter = require("treesitter")
local appearance = require("appearance")

local M = {}

local RESET = "\27[0m"

type Range = {
    start_line: integer,
    end_line: integer,
}

type Document = {
    lines: {string},
    raw_lines: {string},
    gutter_width: integer,
    total_lines: integer,
    language: string?,
}

-- Mapping from file extension or name to tree-sitter language identifier.
local EXTENSIONS: {[string]: string} = {
    ["lua"] = "lua",
    ["go"] = "go",
    ["py"] = "python",
    ["js"] = "javascript",
    ["mjs"] = "javascript",
    ["cjs"] = "javascript",
    ["ts"] = "typescript",
    ["mts"] = "typescript",
    ["cts"] = "typescript",
    ["tsx"] = "tsx",
    ["jsx"] = "tsx",
    ["html"] = "html",
    ["htm"] = "html",
    ["sql"] = "sql",
    ["md"] = "markdown",
    ["markdown"] = "markdown",
    ["cs"] = "c_sharp",
    ["php"] = "php",
}

-- Tree-sitter query strings for common languages.
local QUERIES: {[string]: string} = {
    ["lua"] = [[
        (comment) @comment
        (string) @string
        (number) @number
        [
          "local" "function" "end" "if" "then" "elseif" "else"
          "for" "while" "do" "repeat" "until" "return" "break"
          "in" "not" "and" "or"
        ] @keyword
        ["true" "false" "nil"] @constant
        (function_call name: (identifier) @function)
    ]],
    ["python"] = [[
        (comment) @comment
        (string) @string
        (integer) @number
        (float) @number
        [
          "def" "class" "return" "if" "elif" "else" "for" "while"
          "import" "from" "as" "try" "except" "finally" "with"
          "yield" "raise" "pass" "break" "continue" "lambda"
          "is" "in" "not" "and" "or"
        ] @keyword
        ["True" "False" "None"] @constant
        (call function: (identifier) @function)
    ]],
    ["go"] = [[
        (comment) @comment
        (interpreted_string_literal) @string
        (raw_string_literal) @string
        (int_literal) @number
        (float_literal) @number
        [
          "package" "import" "func" "return" "var" "const" "type"
          "struct" "interface" "if" "else" "for" "range" "switch"
          "case" "default" "select" "go" "defer" "chan" "map"
        ] @keyword
        ["true" "false" "nil" "iota"] @constant
        (call_expression function: (identifier) @function)
    ]],
    ["javascript"] = [[
        (comment) @comment
        (string) @string
        (template_string) @string
        (number) @number
        [
          "function" "const" "let" "var" "return" "if" "else"
          "for" "while" "import" "from" "export" "class" "extends"
          "new" "this" "try" "catch" "finally" "throw" "async"
          "await" "yield" "switch" "case" "default" "break" "continue"
        ] @keyword
        ["true" "false" "null" "undefined"] @constant
        (call_expression function: (identifier) @function)
    ]],
    ["typescript"] = [[
        (comment) @comment
        (string) @string
        (template_string) @string
        (number) @number
        [
          "function" "const" "let" "var" "return" "if" "else"
          "for" "while" "import" "from" "export" "class" "extends"
          "new" "this" "try" "catch" "finally" "throw" "async"
          "await" "yield" "switch" "case" "default" "break" "continue"
          "type" "interface" "namespace" "enum"
        ] @keyword
        ["true" "false" "null" "undefined"] @constant
        (call_expression function: (identifier) @function)
    ]],
    ["tsx"] = [[
        (comment) @comment
        (string) @string
        (template_string) @string
        (number) @number
        [
          "function" "const" "let" "var" "return" "if" "else"
          "for" "while" "import" "from" "export" "class" "extends"
          "new" "this" "try" "catch" "finally" "throw" "async"
          "await" "yield" "switch" "case" "default" "break" "continue"
        ] @keyword
        ["true" "false" "null" "undefined"] @constant
    ]],
    ["markdown"] = [[
        (atx_heading) @keyword
        (fenced_code_block) @string
    ]],
    ["sql"] = [[
        (comment) @comment
        (string_literal) @string
        (numeric_literal) @number
        [
          "SELECT" "select" "FROM" "from" "WHERE" "where" "INSERT" "insert"
          "UPDATE" "update" "DELETE" "delete" "JOIN" "join" "LEFT" "left"
          "RIGHT" "right" "INNER" "inner" "GROUP" "group" "BY" "by"
          "ORDER" "order" "LIMIT" "limit" "CREATE" "create" "TABLE" "table"
          "AND" "and" "OR" "or" "NOT" "not" "NULL" "null" "AS" "as"
        ] @keyword
    ]],
}

-- Strips ANSI escape codes from text.
function M.strip_ansi(text: string): string
    return text:gsub("\27%[[0-9;]*m", "")
end

-- Detects tree-sitter language string from filename / path.
function M.detect_language(path: string): string?
    local ext = path:match("%.([A-Za-z0-9_]+)$")
    if not ext then
        return nil
    end
    return EXTENSIONS[ext:lower()]
end

-- Splits text into lines.
local function split_lines(text: string): {string}
    local lines: {string} = {}
    local pos = 1
    local len = #text
    while pos <= len do
        local nl = text:find("\n", pos, true)
        if nl then
            local line = text:sub(pos, nl - 1):gsub("\r$", "")
            lines[#lines + 1] = line
            pos = nl + 1
        else
            local line = text:sub(pos):gsub("\r$", "")
            lines[#lines + 1] = line
            break
        end
    end
    if #lines == 0 then
        lines[1] = ""
    end
    return lines
end

type Span = {
    col_start: integer,
    col_end: integer,
    role: string,
}

-- Parses and highlights source with tree-sitter, returning styled lines.
function M.highlight(content: string, lang_name: string?, theme_name: string?, range: Range?): Document
    local theme = appearance.theme(theme_name or "dark")
    local lines = split_lines(content)
    local total_lines = #lines

    -- Determine digit width for line numbers
    local digits = #tostring(total_lines)
    if digits < 2 then digits = 2 end
    local gutter_width = digits + 4 -- marker(2) + digits + " │ "

    local lang_id = lang_name or nil
    local captures_by_line: {[integer]: {Span}} = {}

    if lang_id then
        local ts_lang = treesitter.language(lang_id)
        if ts_lang then
            local parser = treesitter.newParser()
            if parser and parser:setLanguage(ts_lang) then
                local tree = parser:parse(content)
                if tree then
                    local root = tree:rootNode()
                    local query_str = QUERIES[lang_id]
                    if root and query_str then
                        local q, err = treesitter.newQuery(ts_lang, query_str)
                        if q and not err then
                            local captures = q:captures(root)
                            for _, cap in ipairs(captures) do
                                local node = cap.node
                                local sp = node:startPoint()
                                local ep = node:endPoint()
                                local start_row = sp.row + 1
                                local end_row = ep.row + 1

                                for r = start_row, end_row do
                                    if not captures_by_line[r] then
                                        captures_by_line[r] = {}
                                    end
                                    local col_s = (r == start_row) and sp.column or 0
                                    local col_e = (r == end_row) and ep.column or 9999
                                    local list = captures_by_line[r]
                                    list[#list + 1] = {
                                        col_start = col_s,
                                        col_end = col_e,
                                        role = cap.name,
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local role_color: {[string]: string} = {
        ["keyword"] = theme.accent,
        ["constant"] = theme.accent,
        ["string"] = theme.success,
        ["number"] = theme.warning,
        ["comment"] = theme.muted,
        ["function"] = appearance.selection_text(theme) ~= "" and theme.accent or theme.text,
    }

    local rendered: {string} = {}

    for line_idx, line in ipairs(lines) do
        local in_range = range and line_idx >= range.start_line and line_idx <= range.end_line
        local marker = in_range and "› " or "  "
        local num_str = string.format("%" .. tostring(digits) .. "d", line_idx)
        local num_styled = appearance.style(in_range and theme.accent or theme.muted, theme.surface) .. marker .. num_str .. " │ " .. RESET

        local line_spans = captures_by_line[line_idx]
        local styled_code = ""

        if not line_spans or #line_spans == 0 then
            -- Plain line
            styled_code = appearance.style(theme.text, in_range and theme.border or theme.surface) .. line .. RESET
        else
            -- Sort spans by start column
            table.sort(line_spans, function(a, b) return a.col_start < b.col_start end)

            local current_col = 0
            local parts: {string} = {}

            for _, span in ipairs(line_spans) do
                if span.col_start > current_col then
                    local plain_seg = line:sub(current_col + 1, span.col_start)
                    parts[#parts + 1] = appearance.style(theme.text, in_range and theme.border or theme.surface) .. plain_seg .. RESET
                    current_col = span.col_start
                end

                if span.col_end > current_col then
                    local color = role_color[span.role] or theme.text
                    local styled_seg = line:sub(current_col + 1, span.col_end)
                    parts[#parts + 1] = appearance.style(color, in_range and theme.border or theme.surface) .. styled_seg .. RESET
                    current_col = span.col_end
                end
            end

            if current_col < #line then
                local tail = line:sub(current_col + 1)
                parts[#parts + 1] = appearance.style(theme.text, in_range and theme.border or theme.surface) .. tail .. RESET
            end

            styled_code = table.concat(parts)
        end

        rendered[line_idx] = num_styled .. styled_code
    end

    return {
        lines = rendered,
        raw_lines = lines,
        gutter_width = gutter_width,
        total_lines = total_lines,
        language = lang_id,
    }
end

-- Calculates scroll window keeping selected line in view.
function M.window(total_lines: integer, capacity: integer, selected: integer, offset: integer): (integer, integer)
    local slots = math.max(0, capacity)
    local last = math.max(0, total_lines - slots)
    local val = math.max(0, math.min(last, offset))
    if selected > 0 and slots > 0 then
        if selected <= val then val = selected - 1 end
        if selected > val + slots then val = selected - slots end
    end
    return math.max(0, math.min(last, val)), slots
end

-- Calculates jump offset centering target_line in the viewport.
function M.jump(total_lines: integer, capacity: integer, target_line: integer): (integer, integer)
    local clamped = math.max(1, math.min(total_lines, target_line))
    local half = capacity // 2
    local offset = math.max(0, clamped - half)
    local max_offset = math.max(0, total_lines - capacity)
    if offset > max_offset then
        offset = max_offset
    end
    return offset, clamped
end

return M
