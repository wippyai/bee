-- MIT. Host configuration is the authority boundary for destination activation.
local test = require("test")
local service = require("destination_service")
local registry = require("registry")

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
        test.it("binds logical databases to host resources inside the measured policy", function()
            local config = valid()
            local profiles = config.profiles :: {{[string]: unknown}}
            local allow = profiles[1].allow :: {[string]: unknown}
            allow.databases = {"vendor:data"}
            profiles[1].database_bindings = {{target_db = "vendor:data",
                database_id = "bee.host:application_db", table_prefix = "vendor_"}}
            profiles[1].migration_policies = {"bee.host:vendor_migration_policy"}
            local decoded, decode_error = service.configuration(config, "node-destination")
            if not decoded then error(tostring(decode_error)) end
            local binding = decoded.profiles[1].database_bindings
            if not binding then error("database binding missing") end
            test.eq(binding["vendor:data"].database_id, "bee.host:application_db")
            test.eq(binding["vendor:data"].table_prefix, "vendor_")
            test.eq(decoded.profiles[1].migration_policies[1], "bee.host:vendor_migration_policy")
            local original_digest = decoded.profiles[1].policy_digest
            local rows = profiles[1].database_bindings :: {{[string]: unknown}}
            rows[1].database_id = "bee.host:alternate_db"
            local changed = assert(service.configuration(config, "node-destination"))
            test.is_true(changed.profiles[1].policy_digest ~= original_digest)
        end)
        test.it("rejects unsafe, duplicate and non-admitted database bindings", function()
            local config = valid()
            local profiles = config.profiles :: {{[string]: unknown}}
            local allow = profiles[1].allow :: {[string]: unknown}
            allow.databases = {"vendor:data"}
            profiles[1].database_bindings = {{target_db = "vendor:data",
                database_id = "bee.host:application_db", table_prefix = "bad-prefix"}}
            local unsafe, unsafe_error = service.configuration(config, "node-destination")
            test.is_nil(unsafe)
            test.is_true(unsafe_error ~= nil)
            profiles[1].database_bindings = {{target_db = "other:data", database_id = "bee.host:application_db"}}
            local outside, outside_error = service.configuration(config, "node-destination")
            test.is_nil(outside)
            test.is_true(outside_error ~= nil)
            profiles[1].database_bindings = {
                {target_db = "vendor:data", database_id = "bee.host:application_db"},
                {target_db = "vendor:data", database_id = "bee.host:alternate_db"},
            }
            local duplicate, duplicate_error = service.configuration(config, "node-destination")
            test.is_nil(duplicate)
            test.is_true(duplicate_error ~= nil)
            profiles[1].database_bindings = {}
            profiles[1].migration_policies = {"bee.host:policy", "bee.host:policy"}
            local duplicate_policy, duplicate_policy_error = service.configuration(config, "node-destination")
            test.is_nil(duplicate_policy)
            test.is_true(duplicate_policy_error ~= nil)
        end)
        test.it("normalizes application admission into the host policy digest", function()
            local config = valid()
            local profile = (config.profiles :: {{[string]: unknown}})[1]
            profile.applications = {{definition_id = "vendor.app:main",
                policies = {"bee:policy-b", "bee:policy-a"}, thread_access = "observe_post"}}
            local decoded, decode_error = service.configuration(config, "node-destination")
            if not decoded then error(tostring(decode_error)) end
            test.eq(decoded.profiles[1].applications[1].policies[1], "bee:policy-a")
            test.eq(decoded.profiles[1].applications[1].thread_access, "observe_post")
            local digest = decoded.profiles[1].policy_digest
            local applications = profile.applications :: {{[string]: unknown}}
            applications[1].thread_access = nil
            local changed = assert(service.configuration(config, "node-destination"))
            test.is_true(changed.profiles[1].policy_digest ~= digest)
            applications[1].appearance_write = true
            test.is_nil(service.configuration(config, "node-destination"))
        end)
        test.it("admits a super-edit profile only while unexpired and explicitly confirmed", function()
            local function install(name: string, confirm: unknown?, approvers: unknown?)
                local current = assert(registry.get("bee:approver_policies"))
                local data = current.data :: {[string]: unknown}
                local rows: {{[string]: unknown}} = {}
                for _, policy in ipairs(data.policies :: {{[string]: unknown}}) do
                    if policy.name ~= name then rows[#rows + 1] = policy end
                end
                local row: {[string]: unknown} = {name = name, max_ttl_ms = 60000,
                    approvers = approvers or {{definition_id = "bee.approvals.inbox:app"}}}
                if confirm ~= nil then row.confirm = confirm end
                rows[#rows + 1] = row
                data.policies = rows
                local changes = registry.snapshot():changes()
                assert(changes:update(current))
                local applied, apply_error = changes:apply()
                if not applied then error("install super-edit policy: " .. tostring(apply_error)) end
            end
            local function row(overrides: {[string]: unknown}): {[string]: unknown}
                local value: {[string]: unknown} = {workspace_id = "workspace-a", source_node = "node-source",
                    source_workspace = "vendor/app", component = "vendor/app",
                    overlay_owner = "bee.apps:workspace-a", approval_policy = "super-edit-host",
                    parameters = {}, expires_at = "2999-01-01T00:00:00.000Z",
                    allow = {packages = {"vendor/app"}, namespaces = {"vendor.app"},
                        kinds = {"function.lua"}, databases = {}, grants = {}, modules = {}, auto_start = false}}
                for name, item in pairs(overrides) do value[name] = item end
                return value
            end
            local function profile_of(raw: {[string]: unknown}): {[string]: unknown}
                local config = assert(service.configuration({profiles = {raw}}, "node-destination"))
                return config.profiles[1]
            end
            install("super-edit-host", "explicit")
            local admitted, refusal = service.super_edit_admission(profile_of(row({})))
            if not admitted then error(tostring(refusal)) end
            -- An expired row is refused at the destination.
            local expired, expired_error = service.super_edit_admission(
                profile_of(row({expires_at = "2000-01-01T00:00:00.000Z"})))
            test.is_false(expired)
            test.not_nil(string.find(expired_error :: string, "expired", 1, true))
            -- A dedicated approver policy that does not confirm explicitly is refused.
            install("super-edit-host", "standard")
            local unconfirmed, unconfirmed_error = service.super_edit_admission(profile_of(row({})))
            test.is_false(unconfirmed)
            test.not_nil(string.find(unconfirmed_error :: string, "explicitly", 1, true))
            -- An explicit policy that names no approver is refused.
            install("super-edit-host", "explicit", {})
            local approverless, approverless_error = service.super_edit_admission(profile_of(row({})))
            test.is_false(approverless)
            test.not_nil(string.find(approverless_error :: string, "names no approvers", 1, true))
            -- A dedicated policy absent from the host table is refused.
            local stripped = assert(registry.get("bee:approver_policies"))
            local stripped_data = stripped.data :: {[string]: unknown}
            stripped_data.policies = {{name = "workspace-application-delivery",
                approvers = {{definition_id = "bee.approvals.inbox:app"}}, max_ttl_ms = 600000}}
            local changes = registry.snapshot():changes()
            assert(changes:update(stripped))
            assert(changes:apply())
            local missing, missing_error = service.super_edit_admission(profile_of(row({})))
            test.is_false(missing)
            test.not_nil(string.find(missing_error :: string, "not configured", 1, true))
            -- A non-super-edit profile bypasses the gate entirely.
            local plain = assert(service.super_edit_admission({super_edit = false}))
            test.is_true(plain)
        end)
        test.it("names one delivery action per operation and refuses unknown ones", function()
            test.eq(service.required_action("list"), "bee.gov.delivery.read")
            test.eq(service.required_action("get"), "bee.gov.delivery.read")
            test.eq(service.required_action("changes"), "bee.gov.delivery.read")
            test.eq(service.required_action("status"), "bee.gov.delivery.read")
            test.eq(service.required_action("stage"), "bee.gov.delivery.manage")
            test.eq(service.required_action("review"), "bee.gov.delivery.manage")
            test.eq(service.required_action("select"), "bee.gov.delivery.manage")
            test.eq(service.required_action("prepare"), "bee.gov.delivery.activate")
            test.eq(service.required_action("step"), "bee.gov.delivery.activate")
            test.eq(service.required_action("recover"), "bee.gov.delivery.activate")
            test.is_nil(service.required_action("apply"))
            test.is_nil(service.required_action(7))
        end)
    end)
end

return test.run_cases(define_tests)
