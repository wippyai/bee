-- MIT. Governed application admission joins the static catalog only for the
-- broker's workspace and only while the host profile still selects it.
local test = require("test")
local registry = require("registry")
local catalog = require("catalog")
local admission = require("admission")

local WORKSPACE = string.rep("a", 32)
local FOREIGN = string.rep("b", 32)
local OWNER = "bee.catalog_test:overlay"
local APP = "bee.catalog_test:app"
local POLICY = "bee:ordinary_app_subsystem_boundary"
local DIGEST = string.rep("c", 64)

type Object = {[string]: unknown}

local function profile(definition_id: string): Object
    return {workspace_id = WORKSPACE, source_node = "source-node", source_workspace = "source-workspace",
        component = "vendor/catalog-test", overlay_owner = OWNER, approval_policy = "local-install",
        parameters = {}, allow = {packages = {}, namespaces = {}, kinds = {}, databases = {}, grants = {}, modules = {}},
        applications = {{definition_id = definition_id, policies = {POLICY}, thread_access = "observe_post"}}}
end

local function app(): Object
    return {id = APP, kind = "process.lua", data = {source = "return {}"},
        meta = {type = "bee.application", application = {api_version = 1, title = "Governed catalog probe",
            lifetime = "view", revision = "1", instance_policy = "multiple", restart_policy = "never"}}}
end

local function find(entries: {Object}, id: string): Object
    for _, entry in ipairs(entries) do if entry.id == id then return entry end end
    error("missing fixture entry " .. id)
end

local function measured(binding_profile: Object, definition: Object): Object
    local state = assert(registry.snapshot():state())
    local selected = binding_profile.applications :: {Object}
    local projected, project_error = admission.project({workspace_id = WORKSPACE, overlay_owner = OWNER,
        source_node = "source-node", source_workspace = "source-workspace", artifact_digest = DIGEST,
        bindings = selected, artifact_entries = {definition},
        registry_entries = {find(state.entries :: {Object}, POLICY)}, overlay_ids = {}})
    if not projected then error(tostring(project_error)) end
    return {id = projected.id, kind = "registry.entry", data = projected.record}
end

local function has(snapshot: {bindings: {Object}}, id: string): boolean
    for _, binding in ipairs(snapshot.bindings) do if binding.definition_id == id then return true end end
    return false
end

local function define_tests()
    test.describe("governed application catalog", function()
        test.it("scopes a measured binding and withdraws it with its host profile", function()
            local original = assert(registry.get("bee.governance:activation_profiles"))
            local definition = app()
            local selected_profile = profile(APP)
            local derived = measured(selected_profile, definition)
            local install = registry.snapshot():changes()
            local configured = assert(registry.get("bee.governance:activation_profiles"))
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
                if binding.definition_id == APP then governed_binding = binding :: Object; break end
            end
            if not governed_binding then error("governed binding missing") end
            test.eq(governed_binding.thread_access, "observe_post")
            test.is_false(governed_binding.appearance_write)
            test.is_true(selected.evidence ~= "")

            local withdraw = registry.snapshot():changes()
            local withdrawn = assert(registry.get("bee.governance:activation_profiles"))
            local withdrawn_profile = profile(APP)
            withdrawn_profile.applications = {}
            withdrawn.data = {profiles = {withdrawn_profile}}
            assert(withdraw:update(withdrawn))
            assert(withdraw:apply())
            local after = catalog.read(WORKSPACE)
            test.is_false(has(after, APP))
            test.is_true(has(after, "bee.settings:app"))

            local cleanup = registry.snapshot():changes()
            assert(cleanup:update(original))
            assert(cleanup:delete(derived.id :: string))
            assert(cleanup:delete(APP))
            assert(cleanup:apply())
        end)
    end)
end

return test.run_cases(define_tests)
