-- MIT. Settings shows the latest appearance chosen while the node applies the
-- earlier ones, and the node's appearance once the latest request settles.
local test = require("test")
local choice = require("choice")
local appearance = require("appearance")

local function with_background(background: string): appearance.Preferences
    local value = appearance.defaults()
    return {theme = value.theme, background = background, taskbar = value.taskbar}
end

local function define_tests()
    test.describe("Settings choice", function()
        test.it("keeps the latest choice while an earlier one is announced", function()
            local state = choice.new(with_background("dots"))
            local first = choice.request(state, with_background("grid"))
            local second = choice.request(state, with_background("stars"))
            choice.announced(state, with_background("grid"))
            choice.settled(state, first, true)
            test.eq(choice.shown(state).background, "stars")
            choice.announced(state, with_background("stars"))
            choice.settled(state, second, true)
            test.eq(choice.shown(state).background, "stars")
        end)

        test.it("returns to the node's appearance when the latest choice is refused", function()
            local state = choice.new(with_background("dots"))
            local sequence = choice.request(state, with_background("grid"))
            test.eq(choice.shown(state).background, "grid")
            choice.settled(state, sequence, false)
            test.eq(choice.shown(state).background, "dots")
        end)

        test.it("shows an appearance another display chose when nothing is in flight", function()
            local state = choice.new(with_background("dots"))
            choice.announced(state, with_background("waves"))
            test.eq(choice.shown(state).background, "waves")
        end)
    end)
end
return test.run_cases(define_tests)
