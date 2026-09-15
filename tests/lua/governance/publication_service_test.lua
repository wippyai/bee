-- MIT. Publication identity and overlay ownership come only from host config.
local test = require("test")
local service = require("publication_service")
local artifact = require("artifact")
local base64 = require("base64")

local function define_tests()
    test.describe("application publication host configuration", function()
        test.it("keeps workspace, component and overlay ownership explicit", function()
            local config, err = service.configuration({profiles = {{workspace_id = "workspace-a",
                source_workspace = "apps/demo", component = "demo/app", overlay_owner = "bee.apps:demo"}}})
            if not config then error(tostring(err)) end
            test.eq(config.profiles[1].workspace_id, "workspace-a")
            test.eq(config.profiles[1].source_workspace, "apps/demo")
            test.eq(config.profiles[1].component, "demo/app")
            test.eq(config.profiles[1].overlay_owner, "bee.apps:demo")
        end)
        test.it("rejects duplicate and malformed publication slots", function()
            local profile = {workspace_id = "workspace-a", source_workspace = "apps/demo",
                component = "demo/app", overlay_owner = "bee.apps:demo"}
            local duplicate, duplicate_error = service.configuration({profiles = {profile, profile}})
            test.is_nil(duplicate)
            test.not_nil(duplicate_error)
            local malformed, malformed_error = service.configuration({profiles = {{workspace_id = "workspace-a",
                source_workspace = "apps/demo", component = "", overlay_owner = "bee.apps:demo"}}})
            test.is_nil(malformed)
            test.not_nil(malformed_error)
        end)
        test.it("builds an exact artifact from declarative frozen entries", function()
            local entries = "[{\"source\":\"return 'private'\",\"kind\":\"function.lua\",\"id\":\"demo:main\"}]"
            local exact = assert(artifact.create({{id = "demo:main", kind = "function.lua", source = "return 'private'"}}))
            local encoded = assert(base64.encode(entries))
            local prepared, err = service.snapshot_artifact({ok = true, value = {
                path = "entries.json", content_base64 = encoded}})
            test.is_nil(err)
            test.eq((prepared :: {[string]: unknown}).digest, exact.digest)
            test.is_nil(service.snapshot_artifact({ok = true, value = {
                path = "other.json", content_base64 = encoded}}))
            test.is_nil(service.snapshot_artifact({ok = true, value = {
                path = "entries.json", content_base64 = assert(base64.encode("{}"))}}))
        end)
    end)
end

return test.run_cases(define_tests)
