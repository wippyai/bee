local test = require("test")
local setup = require("setup")
local function cases()
    test.describe("Driver configuration preview", function()
        test.it("lists Muse configuration consent before a native attempt exists", function()
            local requirements, err = setup.requirements({binding_ref = "bee.driver.muse.binding:binding",
                policy_ref = "bee.driver.muse.security:launch_policy_muse_window", profile_id = "window",
                mode = "window", effective_profile = nil})
            test.is_nil(err)
            test.not_nil(requirements)
            test.eq(assert(requirements)[1].provider, "muse")
        end)
    end)
end
return test.run_cases(cases)
