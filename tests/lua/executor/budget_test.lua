-- MIT. Budgets count normalized driver turns and usage and remain absent by default.
local test = require("test")
local budget = require("budget")

local function define_tests()
    test.describe("Session work budgets", function()
        test.it("stops counting at each optional budget kind", function()
            local turn_limit = assert(budget.decode({provider_steps = 2}))
            local turns = budget.new()
            budget.observe(turns, {data = {type = "turn.signal", phase = "started"}})
            budget.observe(turns, {data = {type = "turn.signal", phase = "started"}})
            test.eq(budget.exceeded(turn_limit, turns, 0), nil)
            budget.observe(turns, {data = {type = "turn.signal", phase = "started"}})
            test.eq(budget.exceeded(turn_limit, turns, 0), "provider_steps")

            local token_limit = assert(budget.decode({tokens = 12}))
            local tokens = budget.new()
            budget.observe(tokens, {data = {type = "turn.signal", phase = "ended", usage = {input_tokens = 5, output_tokens = 7}}})
            test.eq(budget.exceeded(token_limit, tokens, 0), nil)
            budget.observe(tokens, {data = {type = "turn.signal", phase = "ended", usage = {input_tokens = 1}}})
            test.eq(budget.exceeded(token_limit, tokens, 0), "tokens")

            local wall_limit = assert(budget.decode({wall_time_ms = 20}))
            test.eq(budget.exceeded(wall_limit, budget.new(), 19), nil)
            test.eq(budget.exceeded(wall_limit, budget.new(), 20), "wall_time_ms")
        end)

        test.it("leaves a long turn unbounded when no budget was requested", function()
            local selected, decode_error = budget.decode(nil)
            test.is_nil(decode_error)
            local counters = budget.new()
            for _ = 1, 300 do
                budget.observe(counters, {data = {type = "turn.signal", phase = "started"}})
                budget.observe(counters, {data = {type = "turn.signal", phase = "ended", usage = {input_tokens = 1000, output_tokens = 1000}}})
            end
            test.eq(budget.exceeded(selected, counters, 86400000), nil)
        end)
    end)
end

return test.run_cases(define_tests)
