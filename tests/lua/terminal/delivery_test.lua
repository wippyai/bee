-- MIT. Failed attachments remain bounded and release their slots on retirement.
local test = require("test")
local delivery = require("delivery")
local time = require("time")

local function define_tests()
    test.describe("Presenter delivery lifecycle", function()
        test.it("reclaims failed attachments and suppresses retired failure notifications", function()
            for round = 1, 3 do
                for index = 1, 128 do
                    assert(delivery.attach("view-" .. index, "invalid-mount-" .. round .. "-" .. index))
                end
                local admitted = delivery.attach("overflow", "invalid-overflow")
                test.is_false(admitted)
                -- Native attachment errors return asynchronously. Await an actual
                -- result, not an assumed number of coroutine scheduling turns.
                local failed = false
                for _ = 1, 100 do
                    failed = true
                    for index = 1, 128 do
                        if not delivery.is_failed("view-" .. index) then failed = false; break end
                    end
                    if failed then break end
                    time.sleep("1ms")
                end
                test.is_true(failed)
                for index = 1, 128 do delivery.close("view-" .. index) end
                test.is_nil(delivery.poll_failure())
                test.is_false(delivery.has("view-1"))
            end
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
