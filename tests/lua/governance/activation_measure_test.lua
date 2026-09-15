-- MIT. Trusted local measurements replace transferred readiness claims.
local test = require("test")
local measure = require("activation_measure")
local artifact = require("artifact")
local preflight = require("preflight")
local canonical = require("canonical")
local hash = require("hash")

local SHA = string.rep("a", 64)
local function facts(): ({[string]: unknown}, preflight.Candidate, preflight.Context)
    local exact = assert(artifact.create({{id = "demo:run", kind = "function.lua", source = "return true"}}))
    local entry_bytes, entry_encode_error = canonical.encode(exact.entries[1])
    if not entry_bytes then error(tostring(entry_encode_error)) end
    local entry_digest, entry_digest_error = hash.sha256(entry_bytes)
    if not entry_digest then error(tostring(entry_digest_error)) end
    local plan = {owner_node = "node-a", workspace_id = "workspace-a", source_node = "node-b",
        source_workspace = "source-app", version = "v1", plan_digest = SHA, revision = 3,
        selection_revision = 2, selected = true, review_status = "accepted",
        artifact_bytes = exact.bytes, artifact_digest = exact.digest}
    local candidate: preflight.Candidate = {destination_node = "node-a", source_node = "node-b",
        base_revision = 4, base_digest = SHA, artifacts = {{component = "demo/app", version = "v1",
            digest = SHA, dependencies = {}, namespaces = {"demo"}}}, entries = {{id = "demo:run",
            kind = "function.lua", package = "demo/app", digest = entry_digest, references = {}, auto_start = false,
            grants = {}, modules = {}}}, requirements = {}, migrations = {}}
    local context: preflight.Context = {node_id = "node-a", registry_revision = 4,
        registry_digest = SHA, policy_digest = SHA, packages = {["demo/app"] = true},
        namespaces = {demo = true}, kinds = {["function.lua"] = true}, databases = {}, grants = {},
        modules = {}, entries = {}, applied = {}, exact_expansion = true, migration_barrier = false}
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
            test.is_true((result.report :: preflight.Report).ready)
        end)
        test.it("rejects remote readiness, pending migrations and overlay directives", function()
            local plan, candidate, context = facts()
            context.registry_revision = 5
            test.is_nil(measure.measure(plan, candidate, context))
            context.registry_revision = 4
            candidate.migrations = {{id = "demo:001", target_db = "demo:db", checksum = SHA, ordinal = 1}}
            context.databases["demo:db"] = true
            context.entries["demo:db"] = {id = "demo:db", kind = "db.sql.sqlite", package = "base",
                digest = SHA, references = {}, auto_start = false, grants = {}, modules = {}}
            test.is_nil(measure.measure(plan, candidate, context))
            local directive = assert(artifact.create({{id = "demo:root", kind = "ns.dependency", data = {}}}))
            plan.artifact_bytes, plan.artifact_digest = directive.bytes, directive.digest
            candidate.migrations = {}
            test.is_nil(measure.measure(plan, candidate, context))
        end)
    end)
end
return test.run_cases(define_tests)
