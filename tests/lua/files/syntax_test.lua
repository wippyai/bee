local test = require("test")
local syntax = require("syntax")
local appearance = require("appearance")

local function run()
    local theme = appearance.defaults().theme

    test.describe("Syntax highlighting and line numbers", function()
        test.it("detects language from file path", function()
            test.eq(syntax.detect_language("src/main.lua"), "lua")
            test.eq(syntax.detect_language("pkg/server.go"), "go")
            test.eq(syntax.detect_language("scripts/run.py"), "python")
            test.eq(syntax.detect_language("web/app.js"), "javascript")
            test.eq(syntax.detect_language("web/index.ts"), "typescript")
            test.eq(syntax.detect_language("docs/README.md"), "markdown")
            test.eq(syntax.detect_language("schema.sql"), "sql")
            test.is_nil(syntax.detect_language("data.unknown"))
        end)

        test.it("formats line numbers and gutter width", function()
            local code = "line one\nline two\nline three\n"
            local doc = syntax.highlight(code, "lua", theme)
            test.eq(#doc.lines, 3)
            test.eq(doc.gutter_width, 4) -- e.g. "   1 │ " (2 digits min + margin + separator)
        end)

        test.it("highlights lua code tokens using tree-sitter", function()
            local code = "local answer = 42 -- comment\nprint(answer)\n"
            local doc = syntax.highlight(code, "lua", theme)
            test.eq(#doc.lines, 2)
            -- First line should contain styled output
            local line1 = doc.lines[1]
            test.is_true(#line1 > #code) -- Contains ANSI escape sequences for coloring
            -- Plain text version without escapes should contain line number and text
            local plain1 = syntax.strip_ansi(line1)
            test.is_true(plain1:find("local answer = 42 -- comment", 1, true) ~= nil)
            test.is_true(plain1:find("1 │", 1, true) ~= nil)
        end)

        test.it("marks highlighted line range with pointer", function()
            local code = "line 1\nline 2\nline 3\nline 4\nline 5\n"
            local range = {start_line = 2, end_line = 4}
            local doc = syntax.highlight(code, nil, theme, range)
            test.eq(#doc.lines, 5)

            local p1 = syntax.strip_ansi(doc.lines[1])
            local p2 = syntax.strip_ansi(doc.lines[2])
            local p3 = syntax.strip_ansi(doc.lines[3])
            local p4 = syntax.strip_ansi(doc.lines[4])
            local p5 = syntax.strip_ansi(doc.lines[5])

            -- Line 2, 3, 4 should have marker '›'
            test.is_true(p2:find("›", 1, true) ~= nil)
            test.is_true(p3:find("›", 1, true) ~= nil)
            test.is_true(p4:find("›", 1, true) ~= nil)
            test.is_nil(p1:find("›", 1, true))
            test.is_nil(p5:find("›", 1, true))
        end)

        test.it("jumps to line and centers in window", function()
            local total_lines = 100
            local capacity = 20
            local offset, sel = syntax.jump(total_lines, capacity, 50)
            test.eq(sel, 50)
            test.is_true(offset <= 50)
            test.is_true(50 <= offset + capacity)
            test.eq(offset, 40) -- 50 - 20/2 = 40
        end)
    end)
end

return {run = run}
