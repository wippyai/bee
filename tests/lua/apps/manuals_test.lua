-- SPDX-License-Identifier: MIT
local test = require("test")
local tty = require("tty")
local manuals = require("manuals")
local markdown = require("markdown")
local corpus = require("corpus")
local resources = require("resources")
local view = require("view")
local appearance = require("appearance")
local function define_tests()
    test.describe("Agent manuals", function()
        test.it("keeps browsing and long document pages inside the resized canvas", function()
            local document: manuals.Document = {id = "test", title = "Large manual", topic = "docs", content = ""}
            for index = 1, 200 do document.content = document.content .. "Line " .. tostring(index) .. "\n\n" end
            local state: view.Manuals = {documents = {document}, selected = 1, query = "", searching = false, status = ""}
            for _, width in ipairs({1, 20, 40, 80, 120}) do
                for _, height in ipairs({1, 6, 12, 24, 40}) do
                    for _, reading in ipairs({false, true}) do
                        state.opened = reading and document or nil
                        local shown = view.draw(width, height, appearance.defaults(), "manuals", 150, state)
                        test.eq(#shown.rows, height)
                        for _, row in ipairs(shown.rows) do test.eq(tty.text.width(row), width) end
                        for _, hit in ipairs(shown.hits) do
                            test.is_true(hit.x >= 1 and hit.y >= 1)
                            test.is_true(hit.x + hit.width - 1 <= width)
                            test.is_true(hit.y + hit.height - 1 <= height)
                        end
                    end
                end
            end
            state.opened = document
            local scrolled = table.concat(view.draw(80, 24, appearance.defaults(), "manuals", 150, state).rows, "\n")
            test.contains(scrolled, "Line 76")
            test.is_nil((scrolled:find("Line 1 ", 1, true)))
        end)
        test.it("lists exactly the docs backend documents in its served order", function()
            local volume = assert(corpus.open(assert(resources.corpus())))
            local manifest = assert(corpus.manifest(volume))
            local expected = corpus.list(manifest, nil, 0, corpus.MAX_DOCUMENTS)
            local actual = assert(manuals.load())
            test.eq(#actual, #manifest.documents)
            for index, document in ipairs(expected) do
                test.eq(actual[index].id, document.id)
                test.eq(actual[index].title, document.title)
                test.is_true(#actual[index].content > 0)
            end
        end)
        test.it("finds a known phrase in text and a document title", function()
            local documents = assert(manuals.load())
            local found = manuals.search(documents, "bearer_token_env_var")
            test.is_true(#found > 0)
            local external = false
            for _, document in ipairs(found) do if document.id == "docs/external_mcp" then external = true end end
            test.is_true(external)
            local titles = manuals.search(documents, "External MCP clients")
            test.is_true(#titles > 0)
        end)
        test.it("renders headings lists links tables and code without losing wrapped content", function()
            local source = "# A heading\n\n- A [link](https://example.test)\n\n| Name | Value |\n|---|---|\n| long cell | " .. string.rep("abcdefghij", 6) .. " |\n\n```lua\n" .. string.rep("1234567890", 8) .. "\n```\n"
            for _, width in ipairs({8, 20, 40, 80, 118}) do
                local lines = markdown.lines(source, width)
                local joined = ""
                for _, line in ipairs(lines) do
                    local value = line.value or line.heading or ""
                    test.is_true(tty.text.width(value) <= width - 2)
                    joined = joined .. value
                end
                test.contains(joined, "12345678901234567890")
                test.contains(joined, "abcdefghijabcdefghij")
                test.contains(joined, "A heading")
                test.contains(joined, "https://example.test")
                test.is_nil((joined:find("```", 1, true)))
                test.is_nil((joined:find("|---", 1, true)))
            end
        end)
    end)
end
return test.run_cases(define_tests)
