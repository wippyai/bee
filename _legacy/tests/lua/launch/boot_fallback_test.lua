local test = require("test")
local bounds = require("bounds")
local fallback = require("boot_fallback")

local function define_tests()
    test.describe("local host super-edit boot fallback", function()
        test.it("disables overlays and retries once after readiness fails", function()
            local starts, disabled = 0, 0
            local ready, err = fallback.run(function()
                starts = starts + 1
                if starts == 1 then return nil, "startup timed out", true end
                return {workspace_id = "workspace"}, nil, false
            end, function()
                disabled = disabled + 1
                return true, nil
            end, function() end)
            test.eq(starts, 2)
            test.eq(disabled, 1)
            test.eq((assert(bounds.object(ready))).workspace_id, "workspace")
            test.is_nil(err)
        end)

        test.it("does not retry when there are no super-edit profiles", function()
            local starts, disabled = 0, 0
            local ready, err = fallback.run(function()
                starts = starts + 1
                return nil, "supervisor exited", true
            end, function()
                disabled = disabled + 1
                return false, nil
            end, function() end)
            test.is_nil(ready)
            test.eq(err, "supervisor exited")
            test.eq(starts, 1)
            test.eq(disabled, 1)
        end)

        test.it("does not retry for cancellation or after the single fallback", function()
            local starts, disabled = 0, 0
            local ready, err = fallback.run(function()
                starts = starts + 1
                return nil, starts == 1 and "startup timed out" or "still unavailable", true
            end, function()
                disabled = disabled + 1
                return true, nil
            end, function() end)
            test.is_nil(ready)
            test.eq(err, "local host startup failed after disabling super-edit overlays: still unavailable")
            test.eq(starts, 2)
            test.eq(disabled, 1)
        end)

        test.it("keeps the readiness cause when edit-mode recovery also fails", function()
            local ready, err = fallback.run(function()
                return nil, "membership bind failed: address already in use", true
            end, function()
                return nil, "recovery actor was denied"
            end, function() end)
            test.is_nil(ready)
            test.eq(err, "local host startup failed: membership bind failed: address already in use; "
                .. "super-edit recovery failed: recovery actor was denied")
        end)

        test.it("does not disable profiles after cancellation", function()
            local starts, disabled = 0, 0
            local ready, err = fallback.run(function()
                starts = starts + 1
                return nil, "cancelled", false
            end, function()
                disabled = disabled + 1
                return true, nil
            end, function() end)
            test.is_nil(ready)
            test.eq(err, "cancelled")
            test.eq(starts, 1)
            test.eq(disabled, 0)
        end)

        test.it("propagates readiness exceptions without disabling super-edit", function()
            local disabled = 0
            local function readiness(): ({workspace_id: string}?, string?, boolean)
                error("startup policy lookup failed")
            end
            local ready, err = fallback.run(readiness, function()
                disabled = disabled + 1
                return true, nil
            end, function() end)
            test.is_nil(ready)
            if type(err) ~= "string" or not err:find("startup policy lookup failed", 1, true) then
                error("readiness exception was not returned")
            end
            test.eq(disabled, 0)
        end)
    end)
end

return test.run_cases(define_tests)
