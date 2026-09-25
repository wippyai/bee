-- MIT. Publication identity and overlay ownership come only from host config.
local test = require("test")
local profiles = require("publication_profiles")

local WORKSPACE = string.rep("a", 32)

local function define_tests()
    test.describe("application publication host configuration", function()
        test.it("keeps workspace, component and overlay ownership explicit", function()
            local config, err = profiles.decode({profiles = {{workspace_id = "workspace-a",
                source_workspace = "apps/demo", component = "demo/app", overlay_owner = "bee.apps:demo"}}})
            if not config then error(tostring(err)) end
            test.eq(config.profiles[1].workspace_id, "workspace-a")
            test.eq(config.profiles[1].source_workspace, "apps/demo")
            test.eq(config.profiles[1].component, "demo/app")
            test.eq(config.profiles[1].overlay_owner, "bee.apps:demo")
            test.is_false(config.workspace_applications)
        end)
        test.it("rejects duplicate and malformed publication slots", function()
            local profile = {workspace_id = "workspace-a", source_workspace = "apps/demo",
                component = "demo/app", overlay_owner = "bee.apps:demo"}
            local duplicate, duplicate_error = profiles.decode({profiles = {profile, profile}})
            test.is_nil(duplicate)
            test.not_nil(duplicate_error)
            local malformed, malformed_error = profiles.decode({profiles = {{workspace_id = "workspace-a",
                source_workspace = "apps/demo", component = "", overlay_owner = "bee.apps:demo"}}})
            test.is_nil(malformed)
            test.not_nil(malformed_error)
            local flag, flag_error = profiles.decode({profiles = {}, workspace_applications = "yes"})
            test.is_nil(flag)
            test.not_nil(flag_error)
        end)
        test.it("publishes a workspace's own overlay under the workspace-application naming rule", function()
            local config = assert(profiles.decode({profiles = {}, workspace_applications = true}))
            local by_source, source_refusal = profiles.for_source(config, WORKSPACE, "tally")
            if not by_source then error(tostring(source_refusal and source_refusal.message)) end
            test.eq(by_source.component, "app.tally")
            test.eq(by_source.source_workspace, "tally")
            test.eq(by_source.overlay_owner, "bee.governance.workspace_applications:" .. WORKSPACE .. ".tally")
            local by_component = assert(profiles.for_component(config, WORKSPACE, "app.tally"))
            test.eq(by_component.overlay_owner, by_source.overlay_owner)
            test.eq(by_component.source_workspace, "tally")
        end)
        test.it("names the rule and the host configuration when an overlay has no profile", function()
            local enabled = assert(profiles.decode({profiles = {}, workspace_applications = true}))
            local refused_profile, refused = profiles.for_source(enabled, WORKSPACE, "Tally App")
            test.is_nil(refused_profile)
            if not refused then error("expected a refusal") end
            test.not_nil(string.find(refused.message, "Tally App", 1, true))
            test.not_nil(string.find(refused.remedy, "app.<overlay_id>", 1, true))
            test.not_nil(string.find(refused.remedy, "bee:governance_publication_profiles", 1, true))
            local disabled = assert(profiles.decode({profiles = {}}))
            local none, host_only = profiles.for_source(disabled, WORKSPACE, "tally")
            test.is_nil(none)
            if not host_only then error("expected a refusal") end
            test.not_nil(string.find(host_only.message, "no publication profile for overlay tally", 1, true))
            test.not_nil(string.find(host_only.remedy, "bee:governance_activation_profiles", 1, true))
            test.is_nil(string.find(host_only.remedy, "app.<overlay_id>", 1, true))
            test.is_nil(profiles.for_component(enabled, WORKSPACE, "vendor/tally"))
        end)
        test.it("keeps an explicit host row ahead of the naming rule", function()
            local config = assert(profiles.decode({workspace_applications = true, profiles = {{workspace_id = WORKSPACE,
                source_workspace = "tally", component = "vendor/tally", overlay_owner = "bee.vendor:tally"}}}))
            local chosen = assert(profiles.for_source(config, WORKSPACE, "tally"))
            test.eq(chosen.component, "vendor/tally")
            test.eq(chosen.overlay_owner, "bee.vendor:tally")
        end)
    end)
end

return test.run_cases(define_tests)
