-- MIT. Generic sync versions remain immutable and have no selection semantics.
local test = require("test")
local version = require("version")
local function define_tests()
    test.describe("Sync version descriptor", function()
        test.it("measures one immutable available version", function()
            local item = assert(version.create("node-a", "apps", "demo-v1", "demo", "v1", string.rep("a", 64), "governance.snapshot", 4, {files = 1}))
            local decoded = assert(version.decode(item))
            test.eq(decoded.digest, item.digest)
            test.eq(decoded.object_id, "demo")
        end)
        test.it("refuses changed manifests and changed identities", function()
            local item = assert(version.create("node-a", "apps", "demo-v1", "demo", "v1", string.rep("a", 64), "governance.snapshot", 4, {files = 1}))
            item.manifest.files = 2
            test.is_nil(version.decode(item))
        end)
    end)
end
return test.run_cases(define_tests)
