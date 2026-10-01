local test = require("test")
local memory_source = require("memory_source")
local source = require("source")
local tree = require("tree")
local fs = require("fs")
local funcs = require("funcs")
local security = require("security")
local gitignore = require("gitignore")


local function define_tests()
    test.describe("File tree lazy loader and scanner", function()
        test.it("grants only the stock read volume and grants nothing by importing fs", function()
            local call_policy = assert(security.policy("bee.files.test:probe_call_policy"))
            local read_policy = assert(security.policy("bee.security.files:read_policy"))
            local function acquire(resource: string, read: boolean): boolean
                local policies: {security.Policy} = {call_policy}
                if read then policies[#policies + 1] = read_policy end
                local executor = funcs.new():with_actor(security.new_actor("bee.files.test"))
                    :with_scope(security.new_scope(policies))
                local acquired, err = executor:call("bee.files.test:access_probe", resource)
                test.is_nil(err)
                return acquired == true
            end
            test.is_false(acquire("bee.env:files_root", false))
            test.is_true(acquire("bee.env:files_root", true))
            test.is_false(acquire("bee.env:workspace_root", true))
            test.is_false(acquire("bee.env:machine_login_source", true))
        end)

        test.it("renders the host-selected read-only workspace with the runtime filesystem", function()
            local volume = assert(fs.get("bee.env:files_root"))
            local t = tree.new(source.volume(volume))
            local rows = tree.flatten(t)
            local found = false
            for _, row in ipairs(rows) do
                if row.label == "wippy.yaml" then found = true end
                test.is_false(row.label == ".wippy" or row.label == ".git")
            end
            test.is_true(found)
            local written = volume:writefile("bee-files-readonly-probe", "must be refused")
            test.is_false(written == true)
            test.is_false((volume:exists("bee-files-readonly-probe")))
        end)

        test.it("initializes root and lazily expands directories", function()
            local fs = memory_source.new({
                ["src"] = {is_dir = true},
                ["src/main.lua"] = {is_dir = false, content = "print('hello')"},
                ["src/utils.lua"] = {is_dir = false, content = "return {}"},
                ["README.md"] = {is_dir = false, content = "# Hello"},
            })
            local t = tree.new(fs)
            test.not_nil(t)
            test.eq(t.root.loaded, false)

            -- Expand root
            tree.expand(t, t.root)
            test.eq(t.root.loaded, true)
            test.eq(t.root.expanded, true)

            -- Children: src (dir) and README.md (file). Dirs sorted before files!
            test.eq(#t.root.children, 2)
            test.eq(t.root.children[1].name, "src")
            test.eq(t.root.children[1].is_dir, true)
            test.eq(t.root.children[1].loaded, false)
            test.eq(t.root.children[2].name, "README.md")
            test.eq(t.root.children[2].is_dir, false)

            -- Flatten should show root children
            local rows = tree.flatten(t)
            test.eq(#rows, 2)
            test.eq(rows[1].label, "src")
            test.eq(rows[2].label, "README.md")

            -- Expand src folder
            tree.expand(t, t.root.children[1])
            test.eq(t.root.children[1].loaded, true)
            test.eq(#t.root.children[1].children, 2)

            -- Now flatten should show src and its 2 children indented, then README.md
            local rows2 = tree.flatten(t)
            test.eq(#rows2, 4)
            test.eq(rows2[1].label, "src")
            test.eq(rows2[2].label, "main.lua")
            test.eq(rows2[2].depth, 1)
            test.eq(rows2[3].label, "utils.lua")
            test.eq(rows2[3].depth, 1)
            test.eq(rows2[4].label, "README.md")
            test.eq(rows2[4].depth, 0)
        end)

        test.it("respects gitignore and drops .wippy and .git", function()
            local fs = memory_source.new({
                [".wippy"] = {is_dir = true},
                [".wippy/private.db"] = {is_dir = false, content = "secret"},
                [".git"] = {is_dir = true},
                ["node_modules"] = {is_dir = true},
                ["node_modules/pkg"] = {is_dir = true},
                ["build.log"] = {is_dir = false, content = "log"},
                [".gitignore"] = {is_dir = false, content = "node_modules/\n*.log\n"},
                ["src"] = {is_dir = true},
                ["src/app.lua"] = {is_dir = false, content = "app"},
            })

            local t = tree.new(fs)
            tree.expand(t, t.root)

            -- Should have filtered out .wippy, .git, node_modules, build.log
            local names = {}
            for _, c in ipairs(t.root.children) do
                names[#names + 1] = c.name
            end
            test.eq(#names, 2)
            test.eq(names[1], "src")
            test.eq(names[2], ".gitignore")
        end)

        test.it("finds and loads path directly for navigation", function()
            local fs = memory_source.new({
                ["src"] = {is_dir = true},
                ["src/app"] = {is_dir = true},
                ["src/app/view.lua"] = {is_dir = false, content = "-- view"},
                ["README.md"] = {is_dir = false, content = "# Readme"},
            })
            local t = tree.new(fs)
            local node = tree.find_or_load(t, "src/app/view.lua")
            test.not_nil(node)
            test.eq(node.name, "view.lua")
            test.eq(node.path, "src/app/view.lua")

            -- Parent folders should now be expanded
            test.eq(t.root.expanded, true)
            test.eq(t.root.children[1].name, "src")
            test.eq(t.root.children[1].expanded, true)
            test.eq(t.root.children[1].children[1].name, "app")
            test.eq(t.root.children[1].children[1].expanded, true)
        end)

        test.it("searches by name across tree", function()
            local fs = memory_source.new({
                ["src"] = {is_dir = true},
                ["src/app.lua"] = {is_dir = false, content = ""},
                ["src/view.lua"] = {is_dir = false, content = ""},
                ["tests"] = {is_dir = true},
                ["tests/view_test.lua"] = {is_dir = false, content = ""},
                ["README.md"] = {is_dir = false, content = ""},
            })
            local t = tree.new(fs)
            -- Load root and src
            tree.expand(t, t.root)
            tree.expand(t, t.root.children[1]) -- src

            local matches = tree.search(t, "view")
            test.is_true(#matches >= 1)
            test.eq(matches[1].name, "view.lua")
        end)
    end)
end

return test.run_cases(define_tests)
