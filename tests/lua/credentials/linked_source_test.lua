-- MIT.
local test = require("test")
local sources = require("sources")
local bounds = require("bounds")
local function define_tests()
    test.describe("Host-selected login links", function()
        test.it("measures the native source declaration without reading login bytes", function()
            local configured, configuration_error = sources.directory("bee.env:machine_login_source")
            if not configured then error(tostring(configuration_error)) end
            test.eq(configured.kind, "bee.fs.selected_links")
            test.not_nil(bounds.text(configured.root, 4096))
            local links = assert(bounds.array(configured.links, 64))
            local codex, claude = false, false
            for _, raw in ipairs(links) do
                local link = assert(bounds.object(raw))
                if link.path == ".codex/auth.json" and link.write == true then codex = true end
                if link.path == ".claude/.credentials.json" and link.write == true then claude = true end
            end
            test.is_true(codex)
            test.is_true(claude)
        end)
    end)
end
return test.run_cases(define_tests)
