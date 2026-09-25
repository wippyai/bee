-- MIT. A workspace's own agents deliver applications to it under one host
-- rule: an eligible local overlay gets exactly the ceilings the host names,
-- a Hive-received overlay gets its own destination profile, one name stays
-- with the source node that holds it, an ineligible name gets none, and
-- explicit rows win.
local test = require("test")
local profiles = require("activation_profiles")
local naming = require("workspace_applications")
local grants = require("capability_grants")
local catalog = require("capability_catalog")
local registry = require("registry")

local WORKSPACE = string.rep("a", 32)
local NODE = "node-local"

type Object = {[string]: unknown}

local function rule(): Object
    return {approval_policy = "workspace-application-delivery", kinds = {"process.lua", "library.lua"},
        modules = {"tty", "process", "channel", "json"}, policies = {"bee.security:ordinary_app_subsystem_boundary"},
        thread_access = "none"}
end

local function configured(): Object
    return {profiles = {}, workspace_applications = rule()}
end

local function define_tests()
    test.describe("workspace application naming", function()
        test.it("derives one namespace, application entry and owner from an overlay name", function()
            local identity = assert(naming.identity(WORKSPACE, "tally_2"))
            test.eq(identity.namespace, "app.tally_2")
            test.eq(identity.component, "app.tally_2")
            test.eq(identity.definition_id, "app.tally_2:app")
            test.eq(identity.overlay_owner, "bee.gov.apps:" .. WORKSPACE .. ".tally_2")
            test.eq(naming.prior_owner(WORKSPACE, "tally_2"),
                "bee.governance.workspace_applications:" .. WORKSPACE .. ".tally_2")
            test.eq(naming.source_of("app.tally_2"), "tally_2")
            test.is_nil(naming.source_of("vendor.tally"))
        end)
        test.it("refuses names that cannot be a namespace segment and states the rule", function()
            for _, name in ipairs({"Tally", "2tally", "tally-app", "tally.app", "", string.rep("a", 49)}) do
                local identity, refused = naming.identity(WORKSPACE, name)
                test.is_nil(identity)
                test.not_nil(string.find(refused :: string, "app.<overlay_id>:app", 1, true))
            end
        end)
    end)

    test.describe("workspace application activation profile", function()
        test.it("makes the granted function call module available to workspace apps", function()
            local entry = assert(registry.get("bee.env:gov_activation_profiles"))
            local data = entry.data :: Object
            local shipped = data.workspace_applications :: Object
            local found = false
            for _, module in ipairs(shipped.modules :: {string}) do
                if module == "funcs" then found = true end
            end
            test.is_true(found)
        end)
        test.it("selects the host ceilings for an eligible overlay this node authored", function()
            local config = assert(profiles.configuration(configured(), NODE))
            local profile, refused = profiles.select(config, WORKSPACE, NODE, "tally")
            if not profile then error(tostring(refused)) end
            test.eq(profile.component, "app.tally")
            test.eq(profile.resolver, "overlay")
            test.eq(profile.approval_policy, "workspace-application-delivery")
            test.eq(profile.overlay_owner, "bee.gov.apps:" .. WORKSPACE .. ".tally")
            test.is_true(profile.packages["app.tally"])
            test.is_true(profile.namespaces["app.tally"])
            test.is_nil(profile.namespaces["app"])
            test.is_true(profile.kinds["process.lua"] and profile.kinds["library.lua"])
            test.is_nil(profile.kinds["security.policy"])
            test.is_true(profile.modules.tty)
            test.is_nil(next(profile.grants))
            -- An application under the default rule runs only when the app
            -- broker launches it; nothing in it starts on its own.
            test.is_false(profile.auto_start)
            test.is_nil(next(profile.databases))
            local applications = profile.applications :: {Object}
            test.eq(#applications, 1)
            test.eq(applications[1].definition_id, "app.tally:app")
            test.eq((applications[1].policies :: {string})[1], "bee.security:ordinary_app_subsystem_boundary")
            test.eq(applications[1].thread_access, "none")
            test.eq(#profile.policy_digest, 64)
            local again = assert(profiles.select(assert(profiles.configuration(configured(), NODE)), WORKSPACE, NODE, "tally"))
            test.eq(again.policy_digest, profile.policy_digest)
            local other = assert(profiles.select(config, WORKSPACE, NODE, "notes"))
            test.is_true(other.policy_digest ~= profile.policy_digest)
        end)
        test.it("resumes an old activation under its measured owner", function()
            local config = assert(profiles.configuration(configured(), NODE))
            local prior = assert(naming.prior_owner(WORKSPACE, "tally"))
            local restored = assert(profiles.select(config, WORKSPACE, NODE, "tally", nil, nil, prior))
            test.eq(restored.overlay_owner, prior)
            local current = assert(profiles.select(config, WORKSPACE, NODE, "tally"))
            test.is_true(restored.policy_digest ~= current.policy_digest)
        end)
        test.it("derives the installed application allowance from its host grant record", function()
            local identity = assert(naming.identity(WORKSPACE, "tally"))
            local vocabulary = assert(catalog.decode(assert(registry.get("bee:capability_catalog"))))
            local requested = assert(grants.propose(vocabulary, identity.overlay_owner, identity.definition_id, {{
                id = "app.tally:threads", expected_kind = "security.policy", targets = {identity.definition_id},
                capability_request = {capability = "threads.read", parameters = {scope = "owned"},
                    catalog_revision = vocabulary.revision, template_revision = 1,
                    target = identity.definition_id, path = ".security.policies +="}}}))
            local installed = assert(grants.record(identity.overlay_owner, WORKSPACE,
                identity.definition_id, requested, "approved-1", 1))
            local configuration = assert(profiles.configuration(configured(), NODE))
            local selected = assert(profiles.select(configuration, WORKSPACE, NODE, "tally", installed, vocabulary))
            test.is_true(selected.grants[requested.policies[1].id :: string])
            local binding = (selected.applications :: {Object})[1]
            test.eq(#(binding.policies :: {string}), 2)
            test.eq((binding.policies :: {string})[1], requested.policies[1].id)
            test.eq((binding.policies :: {string})[2], "bee.security:ordinary_app_subsystem_boundary")
            test.eq(binding.thread_access, requested.thread_access)
            local remote = assert(profiles.select(configuration, WORKSPACE, "node-remote", "tally", installed,
                vocabulary, nil, "node-remote"))
            test.is_true(remote.grants[requested.policies[1].id :: string])
            local denied = profiles.select(configuration, WORKSPACE, NODE, "tally",
                {id = installed.id, kind = installed.kind, meta = installed.meta, data = {digest = "bad"}}, vocabulary)
            test.is_nil(denied)
        end)
        test.it("admits a Hive-received overlay under its own destination profile", function()
            local config = assert(profiles.configuration(configured(), NODE))
            local remote = assert(profiles.select(config, WORKSPACE, "node-remote", "tally"))
            test.eq(remote.source_node, "node-remote")
            test.eq(remote.component, "app.tally")
            test.eq(remote.overlay_owner, "bee.gov.apps:" .. WORKSPACE .. ".tally")
            test.is_true(next(remote.grants) == nil)
            local held = assert(profiles.select(config, WORKSPACE, "node-remote", "tally", nil, nil, nil,
                "node-remote"))
            test.eq(held.policy_digest, remote.policy_digest)
            local hijack, hijack_refusal = profiles.select(config, WORKSPACE, "node-remote", "tally", nil, nil,
                nil, NODE)
            test.is_nil(hijack)
            test.not_nil(string.find(hijack_refusal :: string, "cannot replace it", 1, true))
            local displaced, displaced_refusal = profiles.select(config, WORKSPACE, NODE, "tally", nil, nil, nil,
                "node-remote")
            test.is_nil(displaced)
            test.not_nil(string.find(displaced_refusal :: string, "installed from node node-remote", 1, true))
            local closed = configured()
            local closed_rule = closed.workspace_applications :: Object
            closed_rule.hive = false
            local refused, refusal = profiles.select(
                assert(profiles.configuration(closed, NODE)), WORKSPACE, "node-remote", "tally")
            test.is_nil(refused)
            test.not_nil(string.find(refusal :: string, "bee.env:gov_activation_profiles", 1, true))
        end)
        test.it("grants nothing to an ineligible name or a missing rule", function()
            local config = assert(profiles.configuration(configured(), NODE))
            local invalid, invalid_refusal = profiles.select(config, WORKSPACE, NODE, "Tally App")
            test.is_nil(invalid)
            test.not_nil(string.find(invalid_refusal :: string, "app.<overlay_id>", 1, true))
            local disabled = assert(profiles.configuration({profiles = {}}, NODE))
            local none, none_refusal = profiles.select(disabled, WORKSPACE, NODE, "tally")
            test.is_nil(none)
            test.not_nil(string.find(none_refusal :: string, "no activation profile for overlay tally", 1, true))
        end)
        test.it("keeps an explicit host row ahead of the rule", function()
            local config = configured()
            config.profiles = {{workspace_id = WORKSPACE, source_node = NODE, source_workspace = "tally",
                component = "vendor/tally", overlay_owner = "bee.vendor:tally", approval_policy = "vendor-install",
                parameters = {}, allow = {packages = {"vendor/tally"}, namespaces = {"vendor.tally"},
                    kinds = {"process.lua"}, databases = {}, grants = {}, modules = {}}}}
            local explicit = assert(profiles.select(assert(profiles.configuration(config, NODE)), WORKSPACE, NODE, "tally"))
            test.eq(explicit.component, "vendor/tally")
            -- An explicit row keeps the host's authority to admit auto start
            -- and may withhold it.
            test.is_true(explicit.auto_start)
            local rows = config.profiles :: {Object}
            local allow = rows[1].allow :: Object
            allow.auto_start = false
            test.is_false(assert(profiles.select(assert(profiles.configuration(config, NODE)), WORKSPACE, NODE, "tally")).auto_start)
            allow.auto_start = "yes"
            test.is_nil(profiles.configuration(config, NODE))
            allow.auto_start = nil
            local decoded = assert(profiles.decode(config))
            local chosen = assert(profiles.select_decoded(decoded, WORKSPACE, NODE, "tally", NODE))
            test.eq(chosen.overlay_owner, "bee.vendor:tally")
            local derived = assert(profiles.select_decoded(decoded, WORKSPACE, NODE, "notes", NODE))
            test.eq(derived.component, "app.notes")
            local remote = assert(profiles.select_decoded(decoded, WORKSPACE, "node-remote", "notes", NODE))
            test.eq(remote.source_node, "node-remote")
            test.eq(remote.component, "app.notes")
        end)
        test.it("rejects a rule that widens authority by shape", function()
            local unknown_field = configured()
            local widened = rule()
            widened.grants = {"db.get"}
            unknown_field.workspace_applications = widened
            test.is_nil(profiles.configuration(unknown_field, NODE))
            local no_kinds = configured()
            local empty = rule()
            empty.kinds = {}
            no_kinds.workspace_applications = empty
            test.is_nil(profiles.configuration(no_kinds, NODE))
            local bad_access = configured()
            local access = rule()
            access.thread_access = "own"
            bad_access.workspace_applications = access
            test.is_nil(profiles.configuration(bad_access, NODE))
            test.is_nil(profiles.configuration({profiles = {}, extra = true}, NODE))
        end)
    end)
end

return test.run_cases(define_tests)
