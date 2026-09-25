-- MIT. A supervised owner controller carries only durable route identity.
local test = require("test")
local handoff = require("owner_handoff")
local workspace = string.rep("a", 32)
local desktop = string.rep("b", 32)
local function define_tests()
    test.describe("Retained owner replacement checkpoint", function()
        test.it("keeps the command and announced workspace identity", function()
            local saved = handoff.pack("owner-pid", workspace, desktop)
            local resumed = assert(handoff.decode(saved, "owner-pid"))
            test.eq(resumed.workspace_id, workspace)
            test.eq(resumed.desktop_id, desktop)
            test.is_nil(handoff.decode(saved, "another-owner"))
        end)
        test.it("rejects an incompatible schema and extra fields", function()
            local saved = handoff.pack("owner-pid", workspace, desktop) :: {[string]: unknown}
            saved.version = 2
            test.is_nil(handoff.decode(saved, "owner-pid"))
            saved.version = 1
            saved.unexpected = true
            test.is_nil(handoff.decode(saved, "owner-pid"))
            saved.unexpected = nil
            saved.desktop_id = "another-desktop"
            test.is_nil(handoff.decode(saved, "owner-pid"))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
