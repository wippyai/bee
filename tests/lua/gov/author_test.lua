-- MIT. A version's author is the title of the definition its session runs.
local test = require("test")
local author = require("author")

local function source(sessions: {[string]: unknown}, titles: {[string]: string}): author.Source
    return {
        session = function(id: string): unknown return sessions[id] end,
        title = function(ref: string): string? return titles[ref] end,
    }
end

local function define_tests()
    test.describe("version author", function()
        test.it("names the agent by the title of its session's definition", function()
            local world = source({["bs:one"] = {session = "bs:one", definition = "bee.agents:claude_code"}},
                {["bee.agents:claude_code"] = "Claude Code"})
            test.eq(author.name("bs:one", world), "Claude Code")
        end)

        test.it("names no one for a caller that is no session, an unknown session or an untitled definition", function()
            local world = source({["bs:one"] = {session = "bs:one", definition = "bee.agents:plain"}}, {})
            test.is_nil(author.name("bee.application", world))
            test.is_nil(author.name("bs:missing", world))
            test.is_nil(author.name("bs:one", world))
            test.is_nil(author.name(7, world))
        end)

        test.it("keeps only a short line", function()
            local world = source({["bs:one"] = {session = "bs:one", definition = "bee.agents:long"}},
                {["bee.agents:long"] = string.rep("x", 81)})
            test.is_nil(author.name("bs:one", world))
        end)
    end)
end

return test.run_cases(define_tests)
