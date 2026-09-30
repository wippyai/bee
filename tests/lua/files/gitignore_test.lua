local test = require("test")
local gitignore = require("gitignore")

local function run()
    test.describe("Gitignore parser and matcher", function()
        test.it("always ignores private .wippy and .git", function()
            local matcher = gitignore.new("")
            test.is_true(matcher:ignored(".wippy", true))
            test.is_true(matcher:ignored(".wippy/credentials.db", false))
            test.is_true(matcher:ignored(".git", true))
            test.is_true(matcher:ignored(".git/config", false))
            test.is_false(matcher:ignored("src/main.lua", false))
        end)

        test.it("ignores filename wildcard patterns", function()
            local content = [[
# comments should be ignored

*.log
temp_*.txt
*.o
]]
            local matcher = gitignore.new(content)
            test.is_true(matcher:ignored("app.log", false))
            test.is_true(matcher:ignored("logs/app.log", false))
            test.is_true(matcher:ignored("temp_test.txt", false))
            test.is_true(matcher:ignored("build/debug/foo.o", false))
            test.is_false(matcher:ignored("app.lua", false))
            test.is_false(matcher:ignored("temp.txt", false))
        end)

        test.it("handles directory-only patterns ending with slash", function()
            local content = [[
node_modules/
dist/
target/
]]
            local matcher = gitignore.new(content)
            test.is_true(matcher:ignored("node_modules", true))
            test.is_true(matcher:ignored("dist", true))
            test.is_true(matcher:ignored("foo/node_modules", true))
            -- File with same name should not be ignored if rule ends with /
            test.is_false(matcher:ignored("dist", false))
        end)

        test.it("handles anchored patterns starting with slash", function()
            local content = [[
/build
/config.json
]]
            local matcher = gitignore.new(content)
            test.is_true(matcher:ignored("build", true))
            test.is_true(matcher:ignored("config.json", false))
            test.is_false(matcher:ignored("sub/build", true))
            test.is_false(matcher:ignored("sub/config.json", false))
        end)

        test.it("handles negation patterns starting with exclamation mark", function()
            local content = [[
*.log
!important.log
docs/
!docs/README.md
]]
            local matcher = gitignore.new(content)
            test.is_true(matcher:ignored("debug.log", false))
            test.is_false(matcher:ignored("important.log", false))
        end)

        test.it("handles double-star recursive wildcard", function()
            local content = [[
foo/**/bar
]]
            local matcher = gitignore.new(content)
            test.is_true(matcher:ignored("foo/bar", false))
            test.is_true(matcher:ignored("foo/a/b/bar", false))
            test.is_false(matcher:ignored("other/foo/bar", false))
        end)
    end)
end

return {run = run}
