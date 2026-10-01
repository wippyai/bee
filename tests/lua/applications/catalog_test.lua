-- MIT. Governed application admission joins the static catalog only for the
-- broker's workspace and only while the host profile still selects it.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local registry = require("registry")
local system = require("system")
local uuid = require("uuid")
local hash = require("hash")
local security = require("security")
local funcs = require("funcs")
local catalog = require("catalog")
local admission = require("admission")
local activation_store = require("activation_store")
local canonical = require("canonical")

local WORKSPACE = string.rep("a", 32)
local FOREIGN = string.rep("b", 32)
local OWNER = "bee.catalog_test:overlay"
local APP = "bee.catalog_test:app"
local POLICY = "bee.security:ordinary_app_subsystem_boundary"
local DIGEST = string.rep("c", 64)

type Object = {[string]: unknown}
type Selection = catalog.Selection

local function blob(bytes: string): Object
    local digest = assert(hash.sha256(bytes))
    return {bytes = bytes, digest = digest}
end

local function ok(result: Object): Object
    test.is_true(result.ok == true, tostring(result.code) .. ": " .. tostring(result.message))
    return assert(bounds.object(result.value))
end

local function profile(definition_id: string): Object
    return {workspace_id = WORKSPACE, source_node = "source-node", source_workspace = "source-workspace",
        component = "vendor/catalog-test", overlay_owner = OWNER, approval_policy = "local-install",
        parameters = {}, allow = {packages = {}, namespaces = {}, kinds = {}, databases = {}, grants = {}, modules = {}},
        applications = {{definition_id = definition_id, policies = {POLICY}, thread_access = "observe_post"}}}
end

local function app(id: string?): Object
    return {id = id or APP, kind = "process.lua", data = {source = "return {}"},
        meta = {type = "bee.app", application = {api_version = 1, title = "Governed catalog probe",
            lifetime = "view", revision = "1", instance_policy = "multiple", restart_policy = "never"}}}
end

local function find(entries: {Object}, id: string): Object
    for _, entry in ipairs(entries) do if entry.id == id then return entry end end
    error("missing fixture entry " .. id)
end

local function project(binding_profile: Object, definition: Object, owner: string, source_node: string,
    source_workspace: string): Object
    local state = assert(registry.snapshot():state())
    local selected = principals.objects(binding_profile.applications)
    local projected, project_error = admission.project({workspace_id = WORKSPACE, overlay_owner = owner,
        source_node = source_node, source_workspace = source_workspace, artifact_digest = DIGEST,
        bindings = selected, artifact_entries = {definition},
        registry_entries = {find(principals.objects(state.entries), POLICY)}, overlay_ids = {}})
    if not projected then error(tostring(project_error)) end
    return {id = projected.id, kind = "registry.entry", data = projected.record}
end

local function measured(binding_profile: Object, definition: Object): Object
    return project(binding_profile, definition, OWNER, "source-node", "source-workspace")
end

local function has(snapshot: {bindings: {Object}}, id: string): boolean
    for _, binding in ipairs(snapshot.bindings) do if binding.definition_id == id then return true end end
    return false
end

local function activate(workspace: string, owner_node: string, source_node: string,
    source_workspace: string, overlay_owner: string, measurement: Object, resource: string?): ()
    local state = assert(activation_store.open(resource or "bee.gov:activation_test_db", owner_node, workspace))
    local nonce = assert(uuid.v7())
    local intent_id = "intent-catalog-" .. nonce
    local plan_digest = string.rep("a", 64)
    local migration_work = blob(assert(canonical.encode({schema_revision = "bee.governance-migration-work@2",
        destination_node = owner_node, source_node = source_node, base_revision = 0,
        base_digest = plan_digest, policy_digest = string.rep("b", 64),
        candidate_digest = string.rep("c", 64), artifact_digest = string.rep("d", 64),
        plan_digest = string.rep("e", 64), migrations = {}, databases = {}})))
    local input: Object = {operation = "prepare_activation", intent_id = intent_id, expected_revision = 0,
        idempotency_key = intent_id .. "-prepare", overlay_owner = overlay_owner,
        source_node = source_node, source_workspace = source_workspace, version = "1.0.0",
        plan_digest = plan_digest, plan_revision = 1, selection_revision = 1,
        artifact = blob("catalog artifact " .. nonce), resolution = blob("catalog resolution " .. nonce),
        preflight = blob("catalog preflight " .. nonce), migration_work = migration_work,
        application_admission = {bytes = measurement.bytes, digest = measurement.digest}}
    local prepared = ok(activation_store.call(state, "actor-catalog", input))
    local proposal_digest = string.rep("f", 64)
    local bound = ok(activation_store.call(state, "actor-catalog", {operation = "bind_approval",
        intent_id = intent_id, expected_revision = prepared.revision, idempotency_key = intent_id .. "-bind",
        approval_id = intent_id .. "-approval", approval_proposal_digest = proposal_digest,
        approval_owner_incarnation = 1}))
    local consuming = ok(activation_store.call(state, "actor-catalog", {operation = "begin_consume",
        intent_id = intent_id, expected_revision = bound.revision, idempotency_key = intent_id .. "-consume"}))
    local consumed = ok(activation_store.call(state, "actor-catalog", {operation = "record_consumption",
        intent_id = intent_id, expected_revision = consuming.revision, idempotency_key = intent_id .. "-receipt",
        consumer_id = "governance-host", proposal_digest = proposal_digest, effect_key = prepared.effect_key}))
    local applying = ok(activation_store.call(state, "actor-catalog", {operation = "begin_apply",
        intent_id = intent_id, expected_revision = consumed.revision, idempotency_key = intent_id .. "-apply"}))
    local applied = ok(activation_store.call(state, "actor-catalog", {operation = "record_outcome",
        intent_id = intent_id, expected_revision = applying.revision, idempotency_key = intent_id .. "-outcome",
        outcome = "applied", diagnostics = "definitions observed"}))
    test.eq(applied.observed_outcome, "applied")
    assert(activation_store.close(state))
end

local function broker_revision(workspace_id: string): string
    local broker_policy = assert(security.policy("bee.security.desktop:broker_policy"))
    local call_policy = assert(security.policy("bee.apps:catalog_revision_probe_call_policy"))
    local scope = assert(security.new_scope({broker_policy, call_policy}))
    local actor = assert(security.new_actor("bee.apps:broker"))
    local executor = assert(funcs.new():with_actor(actor):with_scope(scope))
    local value, call_error = executor:call("bee.apps:catalog_revision_probe", {workspace_id = workspace_id})
    if call_error or type(value) ~= "string" then
        error("read application catalog revision as broker: " .. tostring(call_error or type(value)))
    end
    return value
end

local function define_tests()
    test.describe("governed application catalog", function()
        test.it("scopes a measured binding and withdraws it with its host profile", function()
            local original = assert(registry.get("bee.env:gov_activation_profiles"))
            local definition = app()
            local selected_profile = profile(APP)
            local derived = measured(selected_profile, definition)
            local install = registry.snapshot():changes()
            local configured = assert(registry.get("bee.env:gov_activation_profiles"))
            configured.data = {profiles = {selected_profile}}
            assert(install:update(configured))
            assert(install:create(definition))
            assert(install:create(derived))
            assert(install:apply())

            local selected = catalog.read(WORKSPACE)
            test.is_true(has(selected, APP))
            test.is_false(has(catalog.read(FOREIGN), APP))
            local governed_binding: Object? = nil
            for _, binding in ipairs(selected.bindings) do
                if binding.definition_id == APP then governed_binding = assert(bounds.object(binding)); break end
            end
            if not governed_binding then error("governed binding missing") end
            test.eq(governed_binding.thread_access, "observe_post")
            test.is_false(governed_binding.appearance_write)
            test.is_true(selected.evidence ~= "")

            local withdraw = registry.snapshot():changes()
            local withdrawn = assert(registry.get("bee.env:gov_activation_profiles"))
            local withdrawn_profile = profile(APP)
            withdrawn_profile.applications = {}
            withdrawn.data = {profiles = {withdrawn_profile}}
            assert(withdraw:update(withdrawn))
            assert(withdraw:apply())
            local after = catalog.read(WORKSPACE)
            test.is_false(has(after, APP))
            test.is_true(has(after, "bee.settings.app:app"))

            local cleanup = registry.snapshot():changes()
            assert(cleanup:update(original))
            assert(cleanup:delete(derived.id))
            assert(cleanup:delete(APP))
            assert(cleanup:apply())
        end)

        test.it("admits workspace applications under the host rule and Hive-received ones only with Hive admission", function()
            local node = assert(system.node.id())
            local derived_app = "app.catalog_probe:app"
            local derived_owner = "bee.gov.apps:" .. WORKSPACE .. ".catalog_probe"
            local definition = app(derived_app)
            local rule_profile = {applications = {{definition_id = derived_app, policies = {POLICY}, thread_access = "none"}}}
            local derived = project(rule_profile, definition, derived_owner, node, "catalog_probe")
            local foreign_app = "app.catalog_foreign:app"
            local foreign_definition = app(foreign_app)
            local foreign = project({applications = {{definition_id = foreign_app, policies = {POLICY},
                thread_access = "none"}}}, foreign_definition,
                "bee.gov.apps:" .. WORKSPACE .. ".catalog_foreign", "node-remote", "catalog_foreign")
            local original = assert(registry.get("bee.env:gov_activation_profiles"))
            local install = registry.snapshot():changes()
            assert(install:create(definition))
            assert(install:create(derived))
            assert(install:create(foreign_definition))
            assert(install:create(foreign))
            assert(install:apply())

            local selected = catalog.read(WORKSPACE)
            test.is_true(has(selected, derived_app))
            -- The shipped rule admits a Hive-received application under the
            -- destination's own profile.
            test.is_true(has(selected, foreign_app))
            test.is_false(has(catalog.read(FOREIGN), derived_app))

            -- Without Hive admission the rule covers only this node's own.
            local local_only = registry.snapshot():changes()
            local closed = assert(registry.get("bee.env:gov_activation_profiles"))
            local closed_data = assert(bounds.object(closed.data))
            local closed_rule = assert(bounds.object(closed_data.workspace_applications))
            closed_rule.hive = false
            assert(local_only:update(closed))
            assert(local_only:apply())
            local local_selected = catalog.read(WORKSPACE)
            test.is_true(has(local_selected, derived_app))
            test.is_false(has(local_selected, foreign_app))

            local withdraw = registry.snapshot():changes()
            local withdrawn = assert(registry.get("bee.env:gov_activation_profiles"))
            withdrawn.data = {profiles = {}}
            assert(withdraw:update(withdrawn))
            assert(withdraw:apply())
            test.is_false(has(catalog.read(WORKSPACE), derived_app))

            local cleanup = registry.snapshot():changes()
            assert(cleanup:update(original))
            for _, id in ipairs({derived.id, derived_app, foreign.id, foreign_app}) do
                assert(cleanup:delete(id))
            end
            assert(cleanup:apply())
        end)

        test.it("keeps a local app admission under the persisted node identity", function()
            local source_node = assert(system.node.id())
            local runtime_node = assert(system.node.id())
            test.eq(source_node, runtime_node)
            local app_id = "app.catalog_restart_probe:app"
            local source_workspace = "catalog_restart_probe"
            local overlay_owner = "bee.gov.apps:" .. WORKSPACE .. "." .. source_workspace
            local definition = app(app_id)
            local projected = project({applications = {{definition_id = app_id, policies = {POLICY},
                thread_access = "none"}}}, definition, overlay_owner, source_node, source_workspace)
            local measurement = assert(admission.measure(projected.data))
            local original_profiles = assert(registry.get("bee.env:gov_activation_profiles"))
            local original_database_ref = assert(registry.get("bee.gov:database_ref"))
            local changes = registry.snapshot():changes()
            local configured = assert(registry.get("bee.env:gov_activation_profiles"))
            configured.data = {profiles = {}, workspace_applications = {
                approval_policy = "workspace-application-delivery", kinds = {"process.lua"},
                modules = {"process"}, policies = {POLICY}, thread_access = "none", hive = false}}
            local test_database_ref = assert(registry.get("bee.gov:database_ref"))
            test_database_ref.data = {resource_ref = "bee.gov:activation_test_db"}
            assert(changes:update(configured))
            assert(changes:update(test_database_ref))
            assert(changes:create(definition))
            assert(changes:create(projected))
            assert(changes:apply())

            -- The local workspace rule already names this state's persisted
            -- identity, so its admission remains selectable after owner restart.
            test.is_true(has(catalog.read(WORKSPACE), app_id))
            activate(WORKSPACE, source_node, source_node, source_workspace, overlay_owner, measurement)
            local restored = catalog.read(WORKSPACE)
            test.is_true(has(restored, app_id))
            local binding: Object? = nil
            for _, candidate in ipairs(restored.bindings) do
                if candidate.definition_id == app_id then binding = candidate; break end
            end
            if not binding then error("applied local binding missing after owner restart") end
            test.eq(binding.thread_access, "none")

            local cleanup = registry.snapshot():changes()
            assert(cleanup:update(original_profiles))
            assert(cleanup:update(original_database_ref))
            assert(cleanup:delete(projected.id))
            assert(cleanup:delete(app_id))
            assert(cleanup:apply())
        end)

        test.it("changes the catalog revision for a restored admission under the broker policy", function()
            local node = assert(system.node.id())
            local suffix = assert(uuid.v7()):gsub("-", "")
            local source_workspace = "catalog_recover_" .. suffix
            local overlay_owner = "bee.gov.apps:" .. WORKSPACE .. "." .. source_workspace
            local definition_id = "app." .. source_workspace .. ":app"
            local definition = app(definition_id)
            local selected_profile: Object = {workspace_id = WORKSPACE, source_node = node,
                source_workspace = source_workspace, component = "vendor/catalog-test", overlay_owner = overlay_owner,
                approval_policy = "local-install", resolver = "overlay", parameters = {},
                allow = {packages = {}, namespaces = {}, kinds = {}, databases = {}, grants = {}, modules = {}},
                applications = {{definition_id = definition_id, policies = {POLICY}, thread_access = "none"}}}
            local state = assert(registry.snapshot():state())
            local measured, measure_error = admission.project({workspace_id = WORKSPACE, overlay_owner = overlay_owner,
                source_node = node, source_workspace = source_workspace, artifact_digest = DIGEST,
                bindings = selected_profile.applications, artifact_entries = {definition},
                registry_entries = {find(principals.objects(state.entries), POLICY)}, overlay_ids = {}})
            if not measured then error("project restored admission: " .. tostring(measure_error)) end
            local derived: Object = {id = measured.id, kind = "registry.entry", data = measured.record}

            local original_profiles = assert(registry.get("bee.env:gov_activation_profiles"))
            local original_database_ref = assert(registry.get("bee.gov:database_ref"))
            local changes = registry.snapshot():changes()
            local configured = assert(registry.get("bee.env:gov_activation_profiles"))
            local configuration = assert(bounds.object(configured.data))
            local profiles = principals.items(configuration.profiles)
            configuration.profiles = profiles
            profiles[#profiles + 1] = selected_profile
            assert(changes:update(configured))
            local database_ref = assert(registry.get("bee.gov:database_ref"))
            database_ref.data = {resource_ref = "bee.gov:db"}
            assert(changes:update(database_ref))
            assert(changes:apply())

            local setup_ok, setup_error = pcall(function()
                activate(WORKSPACE, node, node, source_workspace, overlay_owner, assert(bounds.object(measured)), "bee.gov:db")
                local before = broker_revision(WORKSPACE)
                if before:match(":unavailable$") or before:match(":unlinked$") then
                    error("application broker could not read the governance activation revision after activation")
                end
                local stored_before_result = activation_store.catalog_revision("bee.gov:db", node, WORKSPACE)
                if not stored_before_result.ok then
                    error("read governance activation revision before overlay restoration: " .. tostring(stored_before_result.code))
                end
                local stored_before = (assert(bounds.object(stored_before_result.value))).revision
                local overlay = assert(registry.overlay(overlay_owner))
                local install = overlay:changes()
                assert(install:create(definition))
                assert(install:create(derived))
                assert(install:apply())
                local after = broker_revision(WORKSPACE)
                if after:match(":unavailable$") then
                    error("application broker could not fingerprint the protected admission overlay")
                end
                local stored_after_result = activation_store.catalog_revision("bee.gov:db", node, WORKSPACE)
                if not stored_after_result.ok then
                    error("read governance activation revision after overlay restoration: " .. tostring(stored_after_result.code))
                end
                test.eq((assert(bounds.object(stored_after_result.value))).revision, stored_before,
                    "overlay restoration does not change the activation-store revision")
                if after == before then
                    local stored = activation_store.catalog_revision("bee.gov:db", node, WORKSPACE)
                    local stored_value = stored.ok and (assert(bounds.object(stored.value))).revision or stored.code
                    error("restored admission did not invalidate the broker catalog revision; before=" .. before
                        .. "; after=" .. after .. "; stored=" .. tostring(stored_value))
                end
                test.is_true(has(catalog.read(WORKSPACE), definition_id),
                    "restored process-local application was not admitted")
            end)

            local overlay = assert(registry.overlay(overlay_owner))
            local cleanup_overlay = overlay:changes()
            cleanup_overlay:delete(definition_id)
            cleanup_overlay:delete(measured.id)
            assert(cleanup_overlay:apply())
            local cleanup = registry.snapshot():changes()
            assert(cleanup:update(original_profiles))
            assert(cleanup:update(original_database_ref))
            assert(cleanup:apply())
            assert(setup_ok, tostring(setup_error))
        end)

        test.it("admits host-composed packages through the measured packages rule", function()
            local selected = catalog.read(WORKSPACE)
            local bindings: {[string]: Object} = {}
            for _, binding in ipairs(selected.bindings) do
                bindings[binding.definition_id] = assert(bounds.object(binding))
            end
            local timeline = bindings["bee.threads.timeline.app:app"]
            if not timeline then error("timeline package binding missing") end
            -- Measured admissions carry sorted distinct policies.
            local policies = timeline.policies
            if type(policies) ~= "table" then error("timeline binding has no policy list") end
            test.eq(#policies, 3)
            test.eq(policies[1], "bee.security.threads:thread_workspace_list_policy")
            test.eq(policies[2], "bee.security:ordinary_app_subsystem_boundary")
            test.eq(policies[3], "bee.threads.timeline:client_policy")
            test.eq(timeline.thread_access, "none")
            local processes = bindings["bee.host.processes.app:app"]
            if not processes then error("processes package binding missing") end
            test.is_true(processes.application_stop == true)
            test.is_false(processes.appearance_write == true)
            test.eq(processes.close_grace_ms, 250)
            local manager = bindings["bee.hive.manager.app:app"]
            if not manager then error("hive manager package binding missing") end
            test.eq(#(principals.strings(manager.policies)), 3)
            test.is_true(has(selected, "bee.workspace.manager.app:app"))
            test.is_true(has(selected, "bee.hub.modules.app:app"))
            test.is_true(has(selected, "bee.gov.overlays.app:app"))
            local files = bindings["bee.files.app:app"]
            if not files then error("Files package binding missing") end
            test.eq(#(principals.strings(files.policies)), 2)
            test.eq((principals.strings(files.policies))[1], "bee.security.files:read_policy")
            test.eq((principals.strings(files.policies))[2], "bee.security:ordinary_app_subsystem_boundary")
            test.eq(files.thread_access, "observe_post")
            test.is_true(has(selected, "bee.settings.app:app"))
            test.is_true(selected.evidence ~= "")
            test.is_true(has(catalog.read(FOREIGN), "bee.threads.timeline.app:app"))
        end)

        test.it("refreshes a missing open selection once before refusing it", function()
            local visible = catalog.read(WORKSPACE)
            local stale: Selection = {revision = visible.revision, evidence = "", bindings = {}, items = {}}
            local refreshes = 0
            local selected, binding, descriptor = catalog.resolve_open("bee.settings.app:app", function()
                refreshes = refreshes + 1
                return refreshes == 1 and stale or visible
            end)
            test.eq(refreshes, 2)
            test.is_true(selected == visible)
            test.is_true(binding ~= nil)
            test.is_true(descriptor ~= nil)

            refreshes = 0
            local _, missing_binding, missing_descriptor = catalog.resolve_open("bee.catalog_test:missing", function()
                refreshes = refreshes + 1
                return visible
            end)
            test.eq(refreshes, 2)
            test.is_nil(missing_binding)
            test.is_nil(missing_descriptor)
        end)
    end)
end

return test.run_cases(define_tests)
