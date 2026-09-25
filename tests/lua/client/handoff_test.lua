-- MIT. A client handoff carries only identity and grant correlation, never a terminal handle.
local test = require("test")
local handoff = require("handoff")
local WORKSPACE = "0123456789abcdef0123456789abcdef"
local DISPLAY = "ffffffffffffffffffffffffffffffff"
local function define_tests()
    test.describe("client process handoff", function()
        test.it("accepts a versioned checkpoint for its exact owner and workspace", function()
            local saved = handoff.pack("owner", "host", WORKSPACE, DISPLAY, "connection", "generation", true)
            local resumed = assert(handoff.decode(saved, "owner", "host", WORKSPACE))
            test.eq(resumed.display_id, DISPLAY)
            test.eq(resumed.connection_id, "connection")
            test.eq(resumed.renderer_generation, "generation")
            test.eq(resumed.controls_apps, true)
            test.is_nil(handoff.decode(saved, "other", "host", WORKSPACE))
            test.is_nil(handoff.decode(saved, "owner", "other", WORKSPACE))
            test.is_nil(handoff.decode(saved, "owner", "host", DISPLAY))
        end)
        test.it("rejects incompatible and malformed state", function()
            local saved = handoff.pack("owner", "host", WORKSPACE, DISPLAY, "connection", "generation", false)
            saved.version = 2
            test.is_nil(handoff.decode(saved, "owner", "host", WORKSPACE))
            saved.version = 1
            saved.connection_id = ""
            test.is_nil(handoff.decode(saved, "owner", "host", WORKSPACE))
            saved.connection_id = "connection"
            saved.extra = true
            test.is_nil(handoff.decode(saved, "owner", "host", WORKSPACE))
        end)
    end)
end
return {run = define_tests}
