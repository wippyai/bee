local test = require("test")
local memory_source = require("memory_source")
local model = require("model")


local function define_tests()
    test.describe("Files application model", function()
        local mock_fs = memory_source.new({
            ["src"] = {is_dir = true},
            ["src/main.lua"] = {is_dir = false, content = "local x = 1\nlocal y = 2\nlocal z = 3\n"},
            ["README.md"] = {is_dir = false, content = "# Readme\nThis is a test\n"},
        })

        test.it("initializes default state without arguments", function()
            local state = model.new(mock_fs, "", nil)
            test.not_nil(state)
            test.eq(state.active_pane, "tree")
            test.is_nil(state.current_path)
            test.is_nil(state.doc)
            test.eq(state.modal, "none")
            test.is_true(#state.tree_rows > 0)
        end)

        test.it("opens target file and line range from launch arguments", function()
            local args = {"src/main.lua", "2-3"}
            local state = model.new(mock_fs, "", args)
            test.not_nil(state)
            test.eq(state.active_pane, "preview")
            test.eq(state.current_path, "src/main.lua")
            test.not_nil(state.doc)
            test.eq(state.doc.total_lines, 3)
            test.not_nil(state.highlight_range)
            test.eq(state.highlight_range.start_line, 2)
            test.eq(state.highlight_range.end_line, 3)
            test.eq(state.preview_selected, 2)
        end)

        test.it("switches panes and navigates items", function()
            local state = model.new(mock_fs, "", nil)
            test.eq(state.active_pane, "tree")
            model.switch_pane(state)
            test.eq(state.active_pane, "preview")
            model.switch_pane(state)
            test.eq(state.active_pane, "tree")

            -- Move down in tree
            test.eq(state.tree_selected, 1)
            model.move(state, 1)
            test.eq(state.tree_selected, 2)
            model.move(state, -1)
            test.eq(state.tree_selected, 1)
        end)

        test.it("opens file from tree selection", function()
            local state = model.new(mock_fs, "", nil)
            -- Select README.md which is row 2
            model.move(state, 1)
            local row = state.tree_rows[state.tree_selected]
            test.eq(row.label, "README.md")

            -- Trigger open/toggle
            model.activate(state)
            test.eq(state.current_path, "README.md")
            test.not_nil(state.doc)
            test.eq(state.doc.total_lines, 2)
        end)

        test.it("jumps to line in preview", function()
            local args = {"src/main.lua"}
            local state = model.new(mock_fs, "", args)
            test.eq(state.preview_selected, 1)

            model.jump_to_line(state, 3, 20)
            test.eq(state.preview_selected, 3)
        end)

        test.it("opens the selected search result after clearing the filter", function()
            local state = model.new(mock_fs, "", {"src/main.lua"})
            model.open_modal(state, "search")
            model.set_search_query(state, "README")
            model.open_search_result(state)
            test.eq(state.current_path, "README.md")
            test.eq(state.modal, "none")
            test.eq(#state.tree_rows, 3)
        end)

        test.it("marks the jumped line in the rendered document", function()
            local state = model.new(mock_fs, "", {"src/main.lua", "1-2"})
            model.jump_to_line(state, 3, 20)
            test.is_nil((state.doc.lines[1]:find("›", 1, true)))
            test.is_true(state.doc.lines[3]:find("›", 1, true) ~= nil)
        end)

        test.it("handles the search and jump modals", function()
            local state = model.new(mock_fs, "", nil)
            test.eq(state.modal, "none")

            model.open_modal(state, "jump")
            test.eq(state.modal, "jump")
            model.close_modal(state)
            test.eq(state.modal, "none")

            model.open_modal(state, "search")
            test.eq(state.modal, "search")
            model.set_search_query(state, "main")
            test.eq(state.search_query, "main")
            model.close_modal(state)
            test.eq(state.modal, "none")
        end)
    end)
end

return test.run_cases(define_tests)
