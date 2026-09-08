local test = require("test")
local commands = require("commands")

local function define_tests()
    test.describe("Desktop command boundary", function()
        test.it("requires versioned commands", function()
            test.is_nil(commands.decode({op = "screen", width = 80, height = 24}))
            local versioned = commands.decode({version = 1, op = "place", id = "one",
                x = 4.0, y = 2, width = 20, height = 10, request_id = "move"})
            test.not_nil(versioned)
            if versioned then
                test.eq(versioned.x, 4)
                test.eq(versioned.request_id, "move")
            end
        end)

        test.it("rejects unknown versions, fractional geometry and unbounded text", function()
            test.is_nil(commands.decode({version = 2, op = "snapshot"}))
            test.is_nil(commands.decode({version = 1, op = "screen", width = 80.5, height = 24}))
            test.not_nil(commands.decode({version = 1, op = "focus", id = ""}))
            test.is_nil(commands.decode({version = 1, op = "focus", id = string.rep("x", 161)}))
            test.is_nil(commands.decode({version = 1, op = "snap", id = "one", side = "middle"}))
        end)

        test.it("validates appearance values and expected revisions", function()
            local decoded = commands.decode({version = 1, op = "appearance", request_id = "theme",
                theme = "ocean", background = "grid", expected_revision = 4})
            test.not_nil(decoded)
            if decoded then
                test.eq(decoded.theme, "ocean")
                test.eq(decoded.expected_revision, 4)
            end
            test.is_nil(commands.decode({version = 1, op = "appearance", theme = "unknown", background = "solid"}))
            test.is_nil(commands.decode({version = 1, op = "appearance", theme = "ocean", background = "grid",
                expected_revision = 1.5}))
        end)

        test.it("bounds personalization labels, IDs, controls, and named accents", function()
            local decoded = commands.decode({version = 1, op = "personalize", id = "one",
                user_title = string.rep("x", 80), accent = "violet"})
            test.not_nil(decoded)
            if decoded then
                test.eq(decoded.user_title, string.rep("x", 80))
                test.eq(decoded.accent, "violet")
            end

            local clear = commands.decode({version = 1, op = "personalize", id = "one",
                user_title = "", accent = ""})
            test.not_nil(clear)
            test.is_nil(commands.decode({version = 1, op = "personalize", id = "", user_title = "x", accent = "cyan"}))
            test.is_nil(commands.decode({version = 1, op = "personalize", id = string.rep("x", 161), user_title = "x", accent = "cyan"}))
            test.is_nil(commands.decode({version = 1, op = "personalize", id = "one\n", user_title = "x", accent = "cyan"}))
            test.is_nil(commands.decode({version = 1, op = "personalize", id = "one", user_title = string.rep("x", 81), accent = "cyan"}))
            test.is_nil(commands.decode({version = 1, op = "personalize", id = "one", user_title = "line\nbreak", accent = "cyan"}))
            test.is_nil(commands.decode({version = 1, op = "personalize", id = "one", user_title = "x", accent = "yellow"}))
            test.is_nil(commands.decode({version = 1, op = "personalize", id = "one", user_title = "x", accent = 1}))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
