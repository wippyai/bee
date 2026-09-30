local test = require("test")
local protocol = require("protocol")

local function define_tests()
    test.describe("Files protocol target decoding", function()
        test.it("decodes single file path", function()
            local target, err = protocol.decode_target({"src/main.lua"})
            test.is_nil(err)
            test.not_nil(target)
            test.eq(target.path, "src/main.lua")
            test.is_nil(target.line)
            test.is_nil(target.end_line)
        end)

        test.it("decodes file path and line number", function()
            local target, err = protocol.decode_target({"src/main.lua", "42"})
            test.is_nil(err)
            test.not_nil(target)
            test.eq(target.path, "src/main.lua")
            test.eq(target.line, 42)
            test.is_nil(target.end_line)
        end)

        test.it("decodes file path and line range with hyphen or colon", function()
            local t1, err1 = protocol.decode_target({"src/main.lua", "42-50"})
            test.is_nil(err1)
            test.eq(t1.path, "src/main.lua")
            test.eq(t1.line, 42)
            test.eq(t1.end_line, 50)

            local t2, err2 = protocol.decode_target({"src/main.lua", "10:25"})
            test.is_nil(err2)
            test.eq(t2.line, 10)
            test.eq(t2.end_line, 25)
        end)

        test.it("decodes embedded path:line and path:line-line", function()
            local t1, err1 = protocol.decode_target({"src/main.lua:42"})
            test.is_nil(err1)
            test.eq(t1.path, "src/main.lua")
            test.eq(t1.line, 42)

            local t2, err2 = protocol.decode_target({"src/main.lua:42-60"})
            test.is_nil(err2)
            test.eq(t2.path, "src/main.lua")
            test.eq(t2.line, 42)
            test.eq(t2.end_line, 60)
        end)

        test.it("decodes flag arguments", function()
            local target, err = protocol.decode_target({"--file", "lib/tree.lua", "--line", "15", "--end-line", "30"})
            test.is_nil(err)
            test.not_nil(target)
            test.eq(target.path, "lib/tree.lua")
            test.eq(target.line, 15)
            test.eq(target.end_line, 30)
        end)

        test.it("decodes bounded navigation arguments and refuses object payloads", function()
            local target = assert(protocol.decode_navigation({"src/main.lua:2-4"}))
            test.eq(target.line, 2)
            test.eq(target.end_line, 4)
            for _, raw in ipairs({{path = "src/main.lua", line = 2, end_line = 4},
                {version = 1, arguments = {"src/main.lua:2-4"}}, {".wippy/private.db"},
                {"src/main.lua:0"}, {"../outside.lua"}}) do
                test.is_nil(protocol.decode_navigation(raw))
            end
        end)

        test.it("decodes bounded singleton reopen arguments from the shared client boundary", function()
            local target = assert(protocol.decode_navigation({"src/main.lua:5-8"}))
            test.eq(target.path, "src/main.lua")
            test.eq(target.line, 5)
            test.eq(target.end_line, 8)
            for _, raw in ipairs({{}, {"../outside.lua:5-8"}, {"/outside.lua:5-8"},
                {".wippy/private.db:5-8"}, {string.rep("x", 1025)}, {"src/main.lua:0"},
                {"src/main.lua", "bad-range"}, {[2] = "src/main.lua"}}) do
                test.is_nil(protocol.decode_navigation(raw))
            end
        end)

        test.it("refuses unsafe or private paths", function()
            local _, err1 = protocol.decode_target({".wippy"})
            test.not_nil(err1)

            local _, err2 = protocol.decode_target({".wippy/credentials.db"})
            test.not_nil(err2)

            local _, err3 = protocol.decode_target({"../outside.lua"})
            test.not_nil(err3)

            local _, err4 = protocol.decode_target({"foo/../../bar.lua"})
            test.not_nil(err4)

            local _, err5 = protocol.decode_target({"/etc/passwd"})
            test.not_nil(err5)
        end)
    end)
end

return test.run_cases(define_tests)
