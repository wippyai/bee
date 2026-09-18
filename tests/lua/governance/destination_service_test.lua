-- MIT. Host configuration is the authority boundary for destination activation.
local test = require("test")
local service = require("destination_service")

local function valid(): {[string]: unknown}
    return {profiles = {{workspace_id = "workspace-a", source_node = "node-source",
        source_workspace = "vendor/app", component = "vendor/app",
        overlay_owner = "bee.apps:workspace-a", approval_policy = "local-install",
        parameters = {}, allow = {packages = {"vendor/app"}, namespaces = {"vendor.app"},
            kinds = {"function.lua"}, databases = {}, grants = {}, modules = {"json"}}}}}
end

local function define_tests()
    test.describe("destination activation host configuration", function()
        test.it("measures explicit local policy and preserves its ceilings", function()
            local config, err = service.configuration(valid(), "node-destination")
            if not config then error(tostring(err)) end
            local profile = config.profiles[1]
            test.eq(profile.workspace_id, "workspace-a")
            test.eq(profile.source_node, "node-source")
            test.eq(profile.component, "vendor/app")
            test.eq(profile.resolver, "hub")
            test.is_true(profile.packages["vendor/app"])
            test.is_true(profile.modules.json)
            test.eq(#profile.policy_digest, 64)
        end)

        test.it("rejects duplicate destination and source mappings", function()
            local config = valid()
            local profiles = config.profiles :: {unknown}
            profiles[2] = profiles[1]
            local decoded, err = service.configuration(config, "node-destination")
            test.is_true(decoded == nil)
            test.is_true(err ~= nil)
        end)

        test.it("rejects malformed allowlists instead of widening policy", function()
            local config = valid()
            local profiles = config.profiles :: {{[string]: unknown}}
            local profile = profiles[1]
            local allow = profile.allow :: {[string]: unknown}
            allow.packages = {"vendor/app", "vendor/app"}
            local decoded, err = service.configuration(config, "node-destination")
            test.is_true(decoded == nil)
            test.is_true(err ~= nil)
        end)

        test.it("accepts only explicit resolver modes and binds the mode into policy", function()
            local config = valid()
            local profiles = config.profiles :: {{[string]: unknown}}
            profiles[1].resolver = "overlay"
            local overlay, overlay_error = service.configuration(config, "node-destination")
            if not overlay then error(tostring(overlay_error)) end
            local default_config, default_error = service.configuration(valid(), "node-destination")
            if not default_config then error(tostring(default_error)) end
            test.eq(overlay.profiles[1].resolver, "overlay")
            test.is_true(overlay.profiles[1].policy_digest ~= default_config.profiles[1].policy_digest)
            profiles[1].resolver = "remote-registry"
            local invalid, invalid_error = service.configuration(config, "node-destination")
            test.is_nil(invalid)
            test.is_true(invalid_error ~= nil)
        end)
        test.it("names one delivery action per operation and refuses unknown ones", function()
            test.eq(service.required_action("list"), "bee.governance.delivery.read")
            test.eq(service.required_action("get"), "bee.governance.delivery.read")
            test.eq(service.required_action("changes"), "bee.governance.delivery.read")
            test.eq(service.required_action("status"), "bee.governance.delivery.read")
            test.eq(service.required_action("stage"), "bee.governance.delivery.manage")
            test.eq(service.required_action("review"), "bee.governance.delivery.manage")
            test.eq(service.required_action("select"), "bee.governance.delivery.manage")
            test.eq(service.required_action("prepare"), "bee.governance.delivery.activate")
            test.eq(service.required_action("step"), "bee.governance.delivery.activate")
            test.eq(service.required_action("recover"), "bee.governance.delivery.activate")
            test.is_nil(service.required_action("apply"))
            test.is_nil(service.required_action(7))
        end)
    end)
end

return test.run_cases(define_tests)
