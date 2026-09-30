local test = require("test")
local model = require("model")

-- Mock filesystem for model tests
local function make_mock_fs(files: {[string]: {is_dir: boolean, content: string?}})
    local mock = {}
    function mock:readdir(path: string)
        local prefix = path == "" and "" or path .. "/"
        local entries = {}
        for p, info in pairs(files) do
            if p:sub(1, #prefix) == prefix then
                local rest = p:sub(#prefix + 1)
                local name = rest:match("^([^/]+)")
                if name and not entries[name] then
                    local is_dir = rest:find("/", 1, true) ~= nil or info.is_dir
                    entries[name] = {name = name, type = is_dir and "directory" or "file"}
                end
            end
        end
        local list = {}
        for _, entry in pairs(entries) do list[#list + 1] = entry end
        local idx = 0
        return function()
            idx = idx + 1
            return list[idx]
        end, nil
    end

    function mock:readfile(path: string)
        local f = files[path]
        if f and not f.is_dir then return f.content or "", nil end
        return nil, "not found"
    end

    function mock:exists(path: string)
        return files[path] ~= nil, nil
    end

    function mock:isdir(path: string)
        local f = files[path]
        return f and f.is_dir or false, nil
    end

    return mock
end

local function run()
    test.describe("Files application model", function()
        local mock_fs = make_mock_fs({
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

        test.it("handles modals: help, more, search, jump", function()
            local state = model.new(mock_fs, "", nil)
            test.eq(state.modal, "none")

            model.open_modal(state, "help")
            test.eq(state.modal, "help")
            model.close_modal(state)
            test.eq(state.modal, "none")

            model.open_modal(state, "more")
            test.eq(state.modal, "more")
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

return {run = run}
