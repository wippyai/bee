-- MIT. Export configuration is generic across application and non-application content.
local test = require("test")
local distributor = require("distributor")

local function define_tests()
    test.describe("Sync exports", function()
        test.it("admits independent feeds and opaque content kinds", function()
            local exports, err = distributor.configuration({exports = {
                {feed = "governance.application_versions",
                    content_kinds = {"bee.governance-application-version@2"}},
                {feed = "workspace.assets", content_kinds = {"bee.workspace-file@1", "bee.wasm-module@1"}},
            }})
            test.is_nil(err)
            if not exports then error("exports did not decode") end
            test.eq(#exports, 2)
            test.is_true(exports[2].content_kinds["bee.workspace-file@1"])
            test.is_true(exports[2].content_kinds["bee.wasm-module@1"])
        end)

        test.it("rejects duplicate feeds, empty kinds and unknown fields", function()
            local duplicate = distributor.configuration({exports = {
                {feed = "same", content_kinds = {"one"}},
                {feed = "same", content_kinds = {"two"}},
            }})
            test.is_nil(duplicate)
            test.is_nil(distributor.configuration({exports = {{feed = "empty", content_kinds = {}}}}))
            test.is_nil(distributor.configuration({exports = {{feed = "x", content_kinds = {"one"}, typo = true}}}))
        end)
    end)
end

return test.run_cases(define_tests)
