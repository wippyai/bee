-- MIT. Preflight has no runtime-write route; host evidence remains separate.
local test = require("test")
local preflight = require("preflight")
local SHA = string.rep("a", 64)
local function fixture(): (preflight.Candidate, preflight.Context)
    local references: {string} = {}
    local database: preflight.Entry = {id = "host:db", kind = "db.sql.sqlite", package = "host", digest = SHA, references = references, auto_start = true, grants = {}, modules = {}}
    local entries: {[string]: preflight.Entry} = {["host:db"] = database}
    local candidate: preflight.Candidate = {destination_node = "node-a", source_node = "node-b", base_revision = 7, base_digest = SHA,
        artifacts = {{component = "wolfy-j/demo", version = "1.0.0", digest = SHA, dependencies = {}, namespaces = {"demo"}}},
        entries = {{id = "demo:run", kind = "function.lua", package = "wolfy-j/demo", digest = SHA, references = {"host:db"}, auto_start = false, grants = {}, modules = {}}},
        requirements = {{id = "demo:target_db", package = "wolfy-j/demo", value = "host:db", expected_kind = "db.sql.sqlite", targets = {"demo:run"}}},
        migrations = {{id = "demo:001", target_db = "host:db", checksum = SHA, ordinal = 1}}}
    local context: preflight.Context = {node_id = "node-a", registry_revision = 7, registry_digest = SHA, policy_digest = SHA,
        packages = {["wolfy-j/demo"] = true}, namespaces = {demo = true}, kinds = {["function.lua"] = true}, databases = {["host:db"] = true},
        entries = entries,
        applied = {}, grants = {}, modules = {}, exact_expansion = true, migration_barrier = false}
    return candidate, context
end
local function checked(candidate: preflight.Candidate, context: preflight.Context): preflight.Report
    local result, err = preflight.check(candidate, context)
    if not result then error(tostring(err)) end
    return result
end
local function has(report: preflight.Report, code: string): boolean
    for _, diagnostic in ipairs(report.diagnostics) do if diagnostic.code == code then return true end end
    return false
end
local function define_tests()
    test.describe("Governance preflight", function()
        test.it("requires explicit child namespace ownership and host admission", function()
            local candidate, context = fixture()
            candidate.entries[1].id = "demo.child:run"
            candidate.requirements[1].targets = {"demo.child:run"}
            context.namespaces["demo.child"] = true
            test.is_true(has(checked(candidate, context), "NAMESPACE_OWNER"))
            candidate.artifacts[1].namespaces = {"demo", "demo.child"}
            test.is_true(checked(candidate, context).ready)
            context.namespaces["demo.child"] = false
            test.is_true(has(checked(candidate, context), "NAMESPACE_DENIED"))
            context.namespaces["demo.child"] = true
            context.entries["demo.child:foreign"] = {id = "demo.child:foreign", kind = "function.lua", package = "other/owner", digest = SHA, references = {}, auto_start = false, grants = {}, modules = {}}
            test.is_true(has(checked(candidate, context), "NAMESPACE_COLLISION"))
        end)
        test.it("measures an exact destination plan without executing it", function()
            local candidate, context = fixture()
            local report = checked(candidate, context)
            test.is_true(report.ready)
            test.eq(#report.pending_migrations, 1)
            test.eq(report.pending_migrations[1], "host:db\ndemo:001")
            test.eq(report.plan_digest, checked(candidate, context).plan_digest)
            candidate.destination_node = "node-b"
            local other = checked(candidate, context)
            test.is_false(other.ready)
            test.is_true(has(other, "WRONG_DESTINATION"))
            test.is_false(other.plan_digest == report.plan_digest)
        end)
        test.it("fails closed on missing runtime gates and changed destination base", function()
            local candidate, context = fixture()
            context.exact_expansion = false
            context.registry_revision = 8
            local report = checked(candidate, context)
            test.is_false(report.ready)
            test.is_true(has(report, "RUNTIME_GATE"))
            test.is_true(has(report, "STALE_BASE"))
            context.exact_expansion = true
            context.registry_revision = 7
            context.registry_digest = string.rep("b", 64)
            test.is_true(has(checked(candidate, context), "STALE_BASE"))
        end)
        test.it("reports missing graph members and bindings without guessing fixes", function()
            local candidate, context = fixture()
            candidate.artifacts[1].dependencies = {"other/dependency"}
            candidate.requirements[1].value = nil
            local report = checked(candidate, context)
            test.is_true(has(report, "UNRESOLVED_DEPENDENCY"))
            test.is_true(has(report, "MISSING_BINDING"))
            test.is_nil(candidate.requirements[1].value)
        end)
        test.it("checks final-state references and refuses cross-owner replacement", function()
            local candidate, context = fixture()
            context.entries["demo:run"] = {id = "demo:run", kind = "function.lua", package = "other/owner", digest = SHA, references = {}, auto_start = false, grants = {}, modules = {}}
            candidate.entries[1].references = {"demo:missing"}
            local report = checked(candidate, context)
            test.is_true(has(report, "ENTRY_COLLISION"))
            test.is_true(has(report, "DANGLING_REFERENCE"))
            context.entries["demo:removed"] = {id = "demo:removed", kind = "function.lua", package = "wolfy-j/demo", digest = SHA, references = {}, auto_start = false, grants = {}, modules = {}}
            candidate.entries[1].references = {"demo:removed"}
            test.is_true(has(checked(candidate, context), "DANGLING_REFERENCE"))
        end)
        test.it("preserves applied migrations and binds their baseline into the measurement", function()
            local candidate, context = fixture()
            local before = checked(candidate, context)
            context.applied["host:db\ndemo:001"] = candidate.migrations[1]
            local applied = checked(candidate, context)
            test.is_true(applied.ready)
            test.eq(#applied.pending_migrations, 0)
            test.is_false(applied.plan_digest == before.plan_digest)
            candidate.migrations = {{id = "demo:001", target_db = "host:db", checksum = string.rep("b", 64), ordinal = 1}}
            test.is_true(has(checked(candidate, context), "APPLIED_MIGRATION_CHANGED"))
            candidate.migrations = {}
            test.is_true(has(checked(candidate, context), "APPLIED_MIGRATION_REMOVED"))
        end)
        test.it("rejects activation before migrations and unauthorized resource targets", function()
            local candidate, context = fixture()
            candidate.entries[1].auto_start = true
            candidate.entries[1].grants = {"bee:approval_owner_policy"}
            candidate.entries[1].modules = {"os"}
            context.databases["host:db"] = false
            context.packages["wolfy-j/demo"] = false
            context.namespaces.demo = false
            local report = checked(candidate, context)
            test.is_true(has(report, "MIGRATION_BARRIER_REQUIRED"))
            test.is_true(has(report, "DATABASE_DENIED"))
            test.is_true(has(report, "PACKAGE_DENIED"))
            test.is_true(has(report, "NAMESPACE_DENIED"))
            test.is_true(has(report, "GRANT_DENIED"))
            test.is_true(has(report, "MODULE_DENIED"))
        end)
        test.it("round trips canonical source evidence without granting readiness", function()
            local candidate, context = fixture()
            local report = checked(candidate, context)
            local bytes, digest = preflight.encode_report(report)
            test.is_true(bytes ~= nil and digest ~= nil)
            local decoded = assert(preflight.decode_report(bytes, digest))
            test.eq(decoded.plan_digest, report.plan_digest)
            test.is_nil(preflight.decode_report((bytes :: string) .. " ", digest))
            local forged = {schema_revision = report.schema_revision, plan_digest = report.plan_digest,
                destination_node = report.destination_node, base_revision = report.base_revision,
                policy_digest = report.policy_digest, ready = true,
                diagnostics = {{code = "DENIED", target = "x", message = "x", remedy = "x"}},
                pending_migrations = report.pending_migrations}
            test.is_nil(preflight.encode_report(forged))
        end)
    end)
end
return test.run_cases(define_tests)
