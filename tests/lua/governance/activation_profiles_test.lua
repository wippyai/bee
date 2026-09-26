-- MIT. The shipped host activation configuration carries the narrow
-- workspace-application rule beside the wider package ceiling.
local test = require("test")
local profiles = require("activation_profiles")
local registry = require("registry")

local function contains(values: {string}, wanted: string): boolean
    for _, value in ipairs(values) do if value == wanted then return true end end
    return false
end

local function define_tests()
    test.describe("package activation ceiling", function()
        test.it("decodes the shipped configuration with both rules", function()
            local entry = assert(registry.get("bee.env:gov_activation_profiles"))
            local configuration = assert(profiles.decode(entry.data))
            local narrow = assert(configuration.workspace_applications)
            test.eq(narrow.approval_policy, "workspace-application-delivery")
            test.is_true(contains(narrow.kinds, "process.lua"))
            test.is_false(contains(narrow.kinds, "security.policy"))
            local wide = assert(configuration.packages)
            test.eq(wide.approval_policy, "workspace-application-delivery")
            for _, kind in ipairs({"process.lua", "library.lua", "ns.requirement",
                "security.policy", "registry.entry", "contract.binding", "env.variable"}) do
                test.is_true(contains(wide.kinds, kind))
            end
            for _, module in ipairs({"tty", "process", "channel", "json", "time", "uuid", "registry", "system"}) do
                test.is_true(contains(wide.modules, module))
            end
            test.eq(#wide.policies, 1)
            test.eq(wide.policies[1], "bee.security:ordinary_app_subsystem_boundary")
            test.eq(wide.thread_access, "none")
        end)

        test.it("rejects a package ceiling without explicit approval", function()
            local entry = assert(registry.get("bee.env:gov_activation_profiles"))
            local data = entry.data :: {[string]: unknown}
            local narrow = (data.workspace_applications :: {[string]: unknown})
            local wide = (data.packages :: {[string]: unknown})
            local kinds = (wide.kinds :: {unknown})
            local modules = (wide.modules :: {unknown})
            local value: {[string]: unknown} = {profiles = {}, workspace_applications = narrow,
                packages = {kinds = kinds, modules = modules, policies = {},
                    thread_access = "none"}}
            test.is_nil(profiles.decode(value))
        end)
    end)
    test.describe("host-composed package selection", function()
        local WORKSPACE = string.rep("a", 32)
        local NODE = "node-local"
        local function rule(): {[string]: unknown}
            return {approval_policy = "package-delivery", kinds = {"process.lua", "security.policy"},
                modules = {"tty"}, policies = {"bee.security:ordinary_app_subsystem_boundary"},
                thread_access = "none", applications = {
                    {component = "bee.probe.manager", definition_id = "bee.probe.manager:app",
                        capabilities = {"hive.view", "hive.remote_view"},
                        policies = {"bee.probe.manager:client_policy"},
                        application_stop = true, thread_access = "none"}}}
        end
        test.it("instantiates one profile per package source this node composes", function()
            local configured = assert(profiles.decode({profiles = {}, packages = rule()}))
            test.eq(profiles.package_owner(WORKSPACE, "bee.probe.manager"),
                "bee.packages:" .. WORKSPACE .. ".bee.probe.manager")
            test.is_nil(profiles.package_owner(WORKSPACE, "probe"))
            local selected, refused = profiles.select_decoded(configured, WORKSPACE, NODE,
                "bee.probe.manager", NODE)
            if not selected then error(tostring(refused)) end
            test.eq(selected.component, "bee.probe.manager")
            test.eq(selected.source_workspace, "bee.probe.manager")
            test.eq(selected.overlay_owner, "bee.packages:" .. WORKSPACE .. ".bee.probe.manager")
            test.eq(selected.approval_policy, "package-delivery")
            test.is_true(selected.kinds["security.policy"])
            test.is_true(selected.namespaces["bee.probe.manager"])
            test.is_false(selected.auto_start)
            local applications = selected.applications :: {{[string]: unknown}}
            test.eq(#applications, 1)
            test.eq(applications[1].definition_id, "bee.probe.manager:app")
            test.eq((applications[1].policies :: {string})[1], "bee.probe.manager:client_policy")
            test.eq((applications[1].policies :: {string})[2], "bee.security:ordinary_app_subsystem_boundary")
            test.is_true(applications[1].application_stop == true)
            test.is_true(applications[1].appearance_write == false)
            test.eq(applications[1].close_grace_ms, 250)
            test.eq(applications[1].thread_access, "none")
            local measured = assert(profiles.select(assert(profiles.configuration(
                {profiles = {}, packages = rule()}, NODE)), WORKSPACE, NODE, "bee.probe.manager"))
            test.eq(#measured.policy_digest, 64)
            local again = assert(profiles.select(assert(profiles.configuration(
                {profiles = {}, packages = rule()}, NODE)), WORKSPACE, NODE, "bee.probe.manager"))
            test.eq(again.policy_digest, measured.policy_digest)
        end)
        test.it("prefers explicit rows and refuses foreign or unknown package sources", function()
            local configured = assert(profiles.decode({profiles = {{
                workspace_id = WORKSPACE, source_node = NODE, source_workspace = "bee.probe.manager",
                component = "vendor/probe", overlay_owner = "bee.vendor:probe",
                approval_policy = "vendor-install", parameters = {},
                allow = {packages = {"vendor/probe"}, namespaces = {"vendor.probe"},
                    kinds = {"process.lua"}, databases = {}, grants = {}, modules = {}}}},
                packages = rule()}))
            local explicit = assert(profiles.select_decoded(configured, WORKSPACE, NODE,
                "bee.probe.manager", NODE))
            test.eq(explicit.overlay_owner, "bee.vendor:probe")
            local foreign, foreign_refusal = profiles.select_decoded(configured, WORKSPACE,
                "node-remote", "bee.probe.manager", NODE)
            test.is_nil(foreign)
            test.not_nil(string.find(foreign_refusal :: string, "bee.env:gov_activation_profiles", 1, true))
            local unknown, unknown_refusal = profiles.select_decoded(configured, WORKSPACE, NODE,
                "bee.probe.other", NODE)
            test.is_nil(unknown)
            test.not_nil(string.find(unknown_refusal :: string, "no activation profile for overlay", 1, true))
            local bare = assert(profiles.decode({profiles = {}}))
            test.is_nil(profiles.select_decoded(bare, WORKSPACE, NODE, "bee.probe.manager", NODE))
        end)
        test.it("rejects malformed package applications by shape", function()
            local function configured_with(entry: {[string]: unknown}): {[string]: unknown}
                local wide = rule()
                wide.applications = {entry}
                return {profiles = {}, packages = wide}
            end
            local dotted = rule().applications :: {{[string]: unknown}}
            local flat = {component = "probe", definition_id = "bee.probe.manager:app",
                capabilities = {}, policies = {}, thread_access = "none"}
            test.is_nil(profiles.decode(configured_with(flat)))
            local duplicated = {component = "bee.probe.second", definition_id = "bee.probe.manager:app",
                capabilities = {}, policies = {}, thread_access = "none"}
            local wide = rule()
            wide.applications = {dotted[1], duplicated}
            test.is_nil(profiles.decode({profiles = {}, packages = wide}))
            local capabilities = {component = "bee.probe.manager", definition_id = "bee.probe.manager:app",
                capabilities = {"Hive.View"}, policies = {}, thread_access = "none"}
            test.is_nil(profiles.decode(configured_with(capabilities)))
            local flags = {component = "bee.probe.manager", definition_id = "bee.probe.manager:app",
                capabilities = {}, policies = {}, thread_access = "none", close_grace_ms = 70000}
            test.is_nil(profiles.decode(configured_with(flags)))
            local decoded = assert(profiles.decode({profiles = {}, packages = rule()}))
            test.is_nil(profiles.find_package(assert(decoded.packages), "bee.probe.other"))
            test.eq(assert(profiles.find_package(assert(decoded.packages),
                "bee.probe.manager")).definition_id, "bee.probe.manager:app")
        end)
        test.it("admits composed packages and drops an entry whose definition is not composed", function()
            local configured = assert(profiles.decode({profiles = {}, packages = rule()}))
            local definition = {id = "bee.probe.manager:app", kind = "process.lua",
                meta = {type = "bee.application"}, data = {}}
            local policy = {id = "bee.probe.manager:client_policy", kind = "security.policy",
                data = {policy = {actions = {}, resources = "*", effect = "allow"}}}
            local base = {id = "bee.security:ordinary_app_subsystem_boundary", kind = "security.policy",
                data = {policy = {actions = {}, resources = "*", effect = "allow"}}}
            local installed: {[string]: unknown} = {
                ["bee.probe.manager:app"] = definition,
                ["bee.probe.manager:client_policy"] = policy,
                ["bee.security:ordinary_app_subsystem_boundary"] = base,
            }
            local admitted, evidence, error_message = profiles.package_bindings(configured, WORKSPACE,
                NODE, function(id: string): unknown return installed[id] end)
            if not admitted or not evidence then error(tostring(error_message)) end
            test.eq(#admitted, 1)
            test.eq(admitted[1].definition_id, "bee.probe.manager:app")
            test.eq(#evidence, 1)
            -- Without the composed definition the entry admits nothing and the
            -- call reports no error: the missing-definition path a host takes
            -- when a package is uninstalled.
            installed["bee.probe.manager:app"] = nil
            local dropped, dropped_evidence, dropped_error = profiles.package_bindings(configured,
                WORKSPACE, NODE, function(id: string): unknown return installed[id] end)
            if not dropped or not dropped_evidence then error(tostring(dropped_error)) end
            test.eq(#dropped, 0)
            test.eq(#dropped_evidence, 0)
        end)
    end)
end

return test.run_cases(define_tests)
