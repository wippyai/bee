local test = require("test")
local model = require("model")
local view = require("view")
local tty = require("tty")
local appearance = require("appearance")

local function plain(row: string): string
    return row:gsub("\27%[[0-9;]*m", "")
end

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
    local mock_fs = make_mock_fs({
        ["src"] = {is_dir = true},
        ["src/main.lua"] = {is_dir = false, content = "local x = 1\nlocal y = 2\nlocal z = 3\n"},
        ["README.md"] = {is_dir = false, content = "# Readme\nThis is a test\n"},
    })

    test.describe("Files application frame rendering", function()
        test.it("renders correctly at 120x36 geometry with split panes", function()
            local args = {"src/main.lua", "2"}
            local state = model.new(mock_fs, "", args)
            local prefs = appearance.defaults()

            local rendered = view.render(state, 120, 36, prefs)
            test.not_nil(rendered)
            test.eq(#rendered.rows, 36)

            for _, row in ipairs(rendered.rows) do
                test.eq(tty.text.width(plain(row)), 120)
            end

            -- Header row 1 should contain FILES and src/main.lua
            local r1 = plain(rendered.rows[1])
            test.is_true(r1:find("FILES", 1, true) ~= nil)
            test.is_true(r1:find("src/main.lua", 1, true) ~= nil)

            -- Row 2 contains tree on the left and preview line 1 on the right
            local r2 = plain(rendered.rows[2])
            test.is_true(r2:find("src", 1, true) ~= nil or r2:find("1 │", 1, true) ~= nil)

            -- Action bar row (row 35) should contain actions: Open, Search, Jump, More, ? Help
            local r35 = plain(rendered.rows[35])
            test.is_true(r35:find("Open", 1, true) ~= nil)
            test.is_true(r35:find("Search", 1, true) ~= nil)
            test.is_true(r35:find("More", 1, true) ~= nil)
            test.is_true(r35:find("Help", 1, true) ~= nil)

            -- Footer row (row 36) should contain key hints
            local r36 = plain(rendered.rows[36])
            test.is_true(r36:find("move", 1, true) ~= nil)
            test.is_true(r36:find("open", 1, true) ~= nil)
            test.is_true(r36:find("help", 1, true) ~= nil)
        end)

        test.it("renders correctly at 80x24 geometry", function()
            local args = {"src/main.lua", "1-2"}
            local state = model.new(mock_fs, "", args)
            local prefs = appearance.defaults()

            local rendered = view.render(state, 80, 24, prefs)
            test.not_nil(rendered)
            test.eq(#rendered.rows, 24)

            for _, row in ipairs(rendered.rows) do
                test.eq(tty.text.width(plain(row)), 80)
            end

            -- Header row 1
            local r1 = plain(rendered.rows[1])
            test.is_true(r1:find("FILES", 1, true) ~= nil)

            -- Action bar row 23
            local r23 = plain(rendered.rows[23])
            test.is_true(r23:find("More", 1, true) ~= nil)
            test.is_true(r23:find("Help", 1, true) ~= nil)

            -- Footer row 24
            local r24 = plain(rendered.rows[24])
            test.is_true(r24:find("move", 1, true) ~= nil)
        end)

        test.it("renders Help modal when modal state is help", function()
            local state = model.new(mock_fs, "", nil)
            model.open_modal(state, "help")
            local prefs = appearance.defaults()

            local rendered = view.render(state, 80, 24, prefs)
            test.eq(#rendered.rows, 24)

            -- Should find modal title "Help" in rows
            local found_help = false
            for _, row in ipairs(rendered.rows) do
                if plain(row):find("Help", 1, true) then found_help = true end
            end
            test.is_true(found_help)
        end)

        test.it("renders More menu when modal state is more", function()
            local state = model.new(mock_fs, "", nil)
            model.open_modal(state, "more")
            local prefs = appearance.defaults()

            local rendered = view.render(state, 80, 24, prefs)
            test.eq(#rendered.rows, 24)

            local found_more = false
            for _, row in ipairs(rendered.rows) do
                if plain(row):find("More Options", 1, true) then found_more = true end
            end
            test.is_true(found_more)
        end)

        test.it("renders compact and narrow layout without crashing", function()
            local state = model.new(mock_fs, "", nil)
            local prefs = appearance.defaults()

            for _, w in ipairs({40, 60, 80, 120}) do
                for _, h in ipairs({10, 16, 24, 36}) do
                    local rendered = view.render(state, w, h, prefs)
                    test.eq(#rendered.rows, h)
                    for _, row in ipairs(rendered.rows) do
                        test.eq(tty.text.width(plain(row)), w)
                    end
                end
            end
        end)
    end)
end

return {run = run}
