-- MIT. Trusted local measurements replace transferred readiness claims.
local test = require("test")
local bounds = require("bounds")
local KERNEL: {revision: integer, namespaces: {string}, super_edit: {string}, entries: {string}} =
    {revision = 1, namespaces = {"bee.gov"}, super_edit = {}, entries = {"bee.security.gov:protected_kernel"}}
local measure = require("activation_measure")
local artifact = require("artifact")
local preflight = require("preflight")
local canonical = require("canonical")
local hash = require("hash")
local admission = require("application_admission")

local SHA = string.rep("a", 64)
local EMPTY_STRINGS: {string} = {}
local function candidate_entry(id: string, kind: string, package: string, digest: string): preflight.Entry
    return {id = id, kind = kind, package = package, digest = digest, references = EMPTY_STRINGS,
        auto_start = false, grants = EMPTY_STRINGS, modules = EMPTY_STRINGS,
        config_objects = EMPTY_STRINGS, config_lists = EMPTY_STRINGS, config_empty = EMPTY_STRINGS}
end
local function application_admission(artifact_digest: string, policy_digest: string): admission.Measurement
    local measured, measure_error = admission.measure({schema_revision = admission.SCHEMA,
        workspace_id = "workspace-a", overlay_owner = "bee.gov:overlay",
        source_node = "node-b", source_workspace = "source-app", artifact_digest = artifact_digest,
        policy_digest = policy_digest, bindings = {}})
    if not measured then error(tostring(measure_error)) end
    return measured
end
local function facts(): ({[string]: unknown}, preflight.Candidate, preflight.Context)
    local exact = assert(artifact.create({{id = "demo:run", kind = "function.lua", data = {source = "return true"}}}))
    local entry_bytes, entry_encode_error = canonical.encode(exact.entries[1])
    if not entry_bytes then error(tostring(entry_encode_error)) end
    local entry_digest, entry_digest_error = hash.sha256(entry_bytes)
    if not entry_digest then error(tostring(entry_digest_error)) end
    local plan = {owner_node = "node-a", workspace_id = "workspace-a", source_node = "node-b",
        source_workspace = "source-app", version = "v1", plan_digest = SHA, revision = 3,
        selection_revision = 2, selected = true, review_status = "accepted",
        artifact_bytes = exact.bytes, artifact_digest = exact.digest}
    local candidate_entries: {preflight.Entry} = {candidate_entry("demo:run", "function.lua", "demo/app", entry_digest)}
    local candidate: preflight.Candidate = {destination_node = "node-a", source_node = "node-b",
        base_revision = 4, base_digest = SHA, artifacts = {{component = "demo/app", version = "v1",
            digest = SHA, dependencies = {}, namespaces = {"demo"}}}, entries = candidate_entries,
        requirements = {}, migrations = {}}
    local context: preflight.Context = {node_id = "node-a", registry_revision = 4,
        registry_digest = SHA, policy_digest = SHA, packages = {["demo/app"] = true},
        namespaces = {demo = true}, kinds = {["function.lua"] = true}, databases = {}, grants = {},
        modules = {}, entries = {}, installed_entries = nil, applied = {}, exact_expansion = true, protected = KERNEL,
        migration_barrier = false, auto_start = true,
        host_evidence = {application_admission = {kind = "absent"}, capability = {kind = "absent"}}}
    return plan, candidate, context
end

local function define_tests()
    test.describe("Governance activation measurement", function()
        test.it("builds exact local execution evidence from an accepted selection", function()
            local plan, candidate, context = facts()
            local result, err = measure.measure(plan, candidate, context)
            if not result then error(tostring(err)) end
            test.eq(result.plan_revision, 3)
            test.eq(result.selection_revision, 2)
            test.is_true((result.report).ready)
            test.is_nil(result.application_admission)
        end)
        test.it("retains admitted durable shadow authority while normalizing registry revisions", function()
            local plan, candidate, context = facts()
            context.entries["demo:run"] = candidate_entry("demo:run", "function.lua", "installed/component", SHA)
            context.super_edit = true
            test.is_true(assert(preflight.check(candidate, context)).ready)
            local result, err = measure.measure(plan, candidate, context)
            if not result then error(tostring(err)) end
            test.is_true(result.report.ready)
            context.super_edit = false
            local denied, denial = measure.measure(plan, candidate, context)
            test.is_nil(denied)
            test.is_true(tostring(denial):find("ENTRY_COLLISION", 1, true) ~= nil)
        end)
        test.it("retains only a canonical measured application admission projection", function()
            local plan, candidate, context = facts()
            if type(plan.artifact_digest) ~= "string" then error("invalid fixture plan.artifact_digest") end
            local measured_admission = application_admission(plan.artifact_digest, SHA)
            context.host_evidence.application_admission = {kind = "measured", value = measured_admission}
            local result, err = measure.measure(plan, candidate, context)
            if not result then error(tostring(err)) end
            test.eq((assert(bounds.object(result.application_admission))).digest,
                measured_admission.digest)
            test.eq(result.application_admission_digest,
                measured_admission.digest)
            measured_admission.digest = string.rep("b", 64)
            test.is_nil(measure.measure(plan, candidate, context))
        end)
        test.it("rejects remote readiness, pending migrations and overlay directives", function()
            local plan, candidate, context = facts()
            context.registry_revision = 5
            test.is_nil(measure.measure(plan, candidate, context))
            context.registry_revision = 4
            candidate.migrations = {{id = "demo:001", target_db = "demo:db", checksum = SHA, ordinal = 1}}
            context.databases["demo:db"] = true
            context.entries["demo:db"] = candidate_entry("demo:db", "db.sql.sqlite", "base", SHA)
            test.is_nil(measure.measure(plan, candidate, context))
            local directive = assert(artifact.create({{id = "demo:root", kind = "ns.dependency", data = {}}}))
            plan.artifact_bytes, plan.artifact_digest = directive.bytes, directive.digest
            candidate.migrations = {}
            test.is_nil(measure.measure(plan, candidate, context))
        end)
        test.it("refuses a portable artifact that forges an admission identity", function()
            local plan, candidate, context = facts()
            local forged = assert(artifact.create({{id = admission.RESERVED_PREFIX .. "forged",
                kind = "function.lua", data = {source = "return true"}}}))
            plan.artifact_bytes, plan.artifact_digest = forged.bytes, forged.digest
            local entry_bytes = assert(canonical.encode(forged.entries[1]))
            candidate.entries[1].id = forged.entries[1].id
            candidate.entries[1].digest = assert(hash.sha256(entry_bytes))
            test.is_nil(measure.measure(plan, candidate, context))
        end)
        test.it("seals pending migration work for an existing admitted database", function()
            local definition = {id = "demo:001", kind = "function.lua",
                meta = {type = "migration", target_db = "host:db", ordinal = 1},
                data = {source = "return true", modules = {}}}
            local exact = assert(artifact.create({definition}))
            local definition_bytes = assert(canonical.encode(definition))
            local checksum = assert(hash.sha256(definition_bytes))
            local plan = {owner_node = "node-a", workspace_id = "workspace-a", source_node = "node-b",
                source_workspace = "source-app", version = "v1", plan_digest = SHA, revision = 3,
                selection_revision = 2, selected = true, review_status = "accepted",
                artifact_bytes = exact.bytes, artifact_digest = exact.digest}
            local candidate_entries: {preflight.Entry} = {
                candidate_entry("demo:001", "function.lua", "demo/app", checksum)}
            local candidate: preflight.Candidate = {destination_node = "node-a", source_node = "node-b",
                base_revision = 4, base_digest = SHA, artifacts = {{component = "demo/app", version = "v1",
                    digest = exact.digest, dependencies = {}, namespaces = {"demo"}}}, entries = candidate_entries,
                requirements = {},
                migrations = {{id = "demo:001", target_db = "host:db", checksum = checksum, ordinal = 1}}}
            local database = candidate_entry("host:db", "db.sql.sqlite", "host/base", SHA)
            local context: preflight.Context = {node_id = "node-a", registry_revision = 4,
                registry_digest = SHA, policy_digest = SHA, packages = {["demo/app"] = true}, namespaces = {demo = true},
                kinds = {["function.lua"] = true}, databases = {["host:db"] = true}, grants = {}, modules = {},
                entries = {["host:db"] = database}, installed_entries = nil, applied = {}, exact_expansion = true, protected = KERNEL,
                migration_barrier = true, auto_start = true,
                host_evidence = {application_admission = {kind = "absent"}, capability = {kind = "absent"}}}
            local result, problem = measure.measure(plan, candidate, context)
            if not result then error(tostring(problem)) end
            test.eq(#((result.report).pending_migrations), 1)
            test.is_true(type((assert(bounds.object(result.migration_work))).bytes) == "string")
        end)
    end)
end
return test.run_cases(define_tests)
