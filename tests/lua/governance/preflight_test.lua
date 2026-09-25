-- MIT. Preflight has no runtime-write route; host evidence remains separate.
local test = require("test")
local preflight = require("preflight")
local canonical = require("canonical")
local artifact = require("artifact")
local hash = require("hash")
local SHA = string.rep("a", 64)
local function fixture(): (preflight.Candidate, preflight.Context)
    local references: {string} = {}
    local database: preflight.Entry = {id = "host:db", kind = "db.sql.sqlite", package = "host", digest = SHA, references = references, auto_start = true, grants = {}, modules = {}, config_objects = {}, config_lists = {}, config_empty = {}}
    local entries: {[string]: preflight.Entry} = {["host:db"] = database}
    local candidate: preflight.Candidate = {destination_node = "node-a", source_node = "node-b", base_revision = 7, base_digest = SHA,
        artifacts = {{component = "wolfy-j/demo", version = "1.0.0", digest = SHA, dependencies = {}, namespaces = {"demo"}}},
        entries = {{id = "demo:run", kind = "function.lua", package = "wolfy-j/demo", digest = SHA, references = {"host:db"}, auto_start = false, grants = {}, modules = {}, config_objects = {}, config_lists = {}, config_empty = {}}},
        requirements = {{id = "demo:target_db", package = "wolfy-j/demo", value = "host:db", expected_kind = "db.sql.sqlite", targets = {"demo:run"}}},
        migrations = {{id = "demo:001", target_db = "host:db", checksum = SHA, ordinal = 1}}}
    local context: preflight.Context = {node_id = "node-a", registry_revision = 7, registry_digest = SHA, policy_digest = SHA,
        packages = {["wolfy-j/demo"] = true}, namespaces = {demo = true}, kinds = {["function.lua"] = true}, databases = {["host:db"] = true},
        entries = entries, installed_entries = nil,
        applied = {}, grants = {}, modules = {}, exact_expansion = true, migration_barrier = false, auto_start = true,
        protected = {revision = 1, namespaces = {"bee.gov", "bee.security"},
            entries = {"bee:approver_policies", "bee:protected_kernel"}}}
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
            context.entries["demo.child:foreign"] = {id = "demo.child:foreign", kind = "function.lua", package = "other/owner", digest = SHA, references = {}, auto_start = false, grants = {}, modules = {}, config_objects = {}, config_lists = {}, config_empty = {}}
            test.is_true(has(checked(candidate, context), "NAMESPACE_COLLISION"))
        end)
        test.it("refuses a configuration shape the runtime's typed config rejects", function()
            local candidate, context = fixture()
            local function shaped(config: {[string]: unknown})
                local objects, lists, empty = artifact.config_shapes(config)
                if not objects or not lists or not empty then error("measure configuration shapes") end
                candidate.entries[1].config_objects = objects
                candidate.entries[1].config_lists = lists
                candidate.entries[1].config_empty = empty
            end
            shaped({source = "file://run.lua", method = "handle", modules = {json = true}})
            local blocked = checked(candidate, context)
            test.is_false(blocked.ready)
            test.is_true(has(blocked, "CONFIG_SHAPE"))
            -- An empty declared field crosses as neither shape, whichever
            -- allocation it carries.
            shaped({source = "file://run.lua", method = "handle", modules = table.create(1, 0)})
            test.is_true(has(checked(candidate, context), "CONFIG_SHAPE"))
            shaped({source = "file://run.lua", method = "handle", imports = table.create(0, 1)})
            test.is_true(has(checked(candidate, context), "CONFIG_SHAPE"))
            shaped({source = "file://run.lua", method = "handle", modules = {"json"}, imports = {demo = "bee.demo:library"}})
            test.is_true(checked(candidate, context).ready)
            shaped({source = "file://run.lua", method = "handle", modules = {"json"}, imports = {"bee.demo:library"}})
            test.is_true(has(checked(candidate, context), "CONFIG_SHAPE"))
        end)
        test.it("refuses an entry that starts itself where the host admits no auto start", function()
            local candidate, context = fixture()
            context.migration_barrier = true
            candidate.entries[1].auto_start = true
            test.is_true(checked(candidate, context).ready)
            context.auto_start = false
            local refused = checked(candidate, context)
            test.is_false(refused.ready)
            test.is_true(has(refused, "AUTO_START_DENIED"))
            candidate.entries[1].auto_start = false
            test.is_true(checked(candidate, context).ready)
        end)
        test.it("refuses protected kernel edits even under a permissive profile", function()
            local function entry(id: string, package: string, references: {string}): preflight.Entry
                return {id = id, kind = "library.lua", package = package, digest = SHA, references = references,
                    auto_start = false, grants = {}, modules = {}, config_objects = {}, config_lists = {},
                    config_empty = {}}
            end
            local candidate, context = fixture()
            context.entries["bee.gov:preflight"] = entry("bee.gov:preflight", "bee/gov", {"shared.util:bounds"})
            context.entries["shared.util:bounds"] = entry("shared.util:bounds", "bee/shared", {})
            local policies = entry("bee:approver_policies", "bee", {"demo:run"})
            policies.kind = "registry.entry"
            context.entries["bee:approver_policies"] = policies
            local owned = entry("demo:run", "wolfy-j/demo", {})
            owned.kind = "function.lua"
            context.entries["demo:run"] = owned
            -- A host record naming an application does not make it kernel code.
            test.is_true(checked(candidate, context).ready)
            -- A permissive explicit profile admits every package, namespace and kind.
            context.packages["bee/gov"], context.packages["bee/shared"] = true, true
            context.namespaces["bee.gov"], context.namespaces["bee.gov.extra"] = true, true
            context.namespaces["shared.util"], context.namespaces["bee"] = true, true
            context.kinds["library.lua"], context.kinds["registry.entry"] = true, true
            local direct, _ = fixture()
            direct.artifacts[1].namespaces = {"demo", "bee.gov.extra"}
            direct.entries[#direct.entries + 1] = entry("bee.gov.extra:shadow", "wolfy-j/demo", {})
            local refused = checked(direct, context)
            test.is_false(refused.ready)
            test.is_true(has(refused, "PROTECTED_KERNEL"))
            local transitive, _ = fixture()
            transitive.artifacts[1] = {component = "bee/shared", version = "2.0.0", digest = SHA,
                dependencies = {}, namespaces = {"shared.util"}}
            transitive.entries = {entry("shared.util:bounds", "bee/shared", {})}
            transitive.requirements, transitive.migrations = {}, {}
            test.is_true(has(checked(transitive, context), "PROTECTED_KERNEL"))
            -- A host record composed into the application's own overlay.
            context.installed_entries = {["bee.gov:admission.demo"] = {id = "bee.gov:admission.demo",
                kind = "registry.entry", package = "wolfy-j/demo", digest = SHA, references = {"demo:run"},
                auto_start = false, grants = {}, modules = {}, config_objects = {}, config_lists = {},
                config_empty = {}}}
            test.is_true(checked(candidate, context).ready)
            context.installed_entries = nil
            local selector, _ = fixture()
            selector.requirements[1].targets = {"bee:approver_policies"}
            test.is_true(has(checked(selector, context), "PROTECTED_KERNEL"))
            local exact, _ = fixture()
            exact.artifacts[1].namespaces = {"demo", "bee"}
            exact.entries[#exact.entries + 1] = entry("bee:protected_kernel", "wolfy-j/demo", {})
            test.is_true(has(checked(exact, context), "PROTECTED_KERNEL"))
            context.protected = nil
            local missing, missing_error = preflight.check(candidate, context)
            test.is_nil(missing)
            test.not_nil(missing_error)
            context.protected = {revision = 1, namespaces = {"bee.gov"}, entries = {"bee:approver_policies"}}
            local open_map, open_error = preflight.check(candidate, context)
            test.is_nil(open_map)
            test.not_nil(string.find(tostring(open_error), "protect itself", 1, true))
        end)
        test.it("refuses app-shipped actor and group selectors on every entry kind", function()
            local candidate, context = fixture()
            local entry = candidate.entries[1] :: {[string]: unknown}
            for _, kind in ipairs({"process.lua", "function.lua", "library.lua"}) do
                candidate.entries[1].kind = kind
                context.kinds[kind] = true
                entry.security_actor = true
                entry.security_groups = false
                test.is_true(has(checked(candidate, context), "SECURITY_DENIED"))
                entry.security_actor = false
                entry.security_groups = true
                test.is_true(has(checked(candidate, context), "SECURITY_DENIED"))
            end
        end)
        test.it("preserves capability requests in exact candidate bytes and rejects forged targets", function()
            local candidate, context = fixture()
            candidate.entries[1].kind = "process.lua"
            context.kinds["process.lua"] = true
            candidate.requirements[1].value = nil
            candidate.requirements[1].expected_kind = "security.policy"
            candidate.requirements[1].capability_request = {capability = "workspace.files.read",
                parameters = {subpath = "docs"}, reason = "Show docs", target = "demo:run",
                path = ".security.policies +=", catalog_revision = 1, template_revision = 1}
            local bytes = assert(canonical.encode(candidate, 1048576))
            local decoded = assert(preflight.decode_candidate(bytes, assert(hash.sha256(bytes))))
            test.eq((decoded.requirements[1].capability_request :: preflight.CapabilityRequest).reason, "Show docs")
            test.is_true(checked(decoded, context).ready)
            candidate.requirements[1].capability_request.target = "other:run"
            test.is_true(has(checked(candidate, context), "CAPABILITY_REQUEST_DENIED"))
            bytes = assert(canonical.encode(candidate, 1048576))
            test.is_nil(preflight.decode_candidate(bytes, assert(hash.sha256(bytes))))
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
        test.it("resolves a logical migration target only through the host database binding", function()
            local function logical(binding: preflight.DatabaseBinding?): (preflight.Candidate, preflight.Context)
                local candidate, context = fixture()
                candidate.migrations[1].target_db = "demo:data"
                local bindings: {[string]: preflight.DatabaseBinding} = {}
                if binding then bindings["demo:data"] = binding end
                local mapped: preflight.Context = {node_id = context.node_id,
                    registry_revision = context.registry_revision, registry_digest = context.registry_digest,
                    policy_digest = context.policy_digest, packages = context.packages,
                    namespaces = context.namespaces, kinds = context.kinds, databases = {["demo:data"] = true},
                    grants = context.grants, modules = context.modules, database_bindings = bindings,
                    entries = context.entries, installed_entries = context.installed_entries,
                    applied = context.applied, exact_expansion = context.exact_expansion,
                    migration_barrier = context.migration_barrier, auto_start = context.auto_start,
                    protected = context.protected}
                return candidate, mapped
            end
            local candidate, context = logical({database_id = "host:db", table_prefix = "demo_"})
            local report = checked(candidate, context)
            test.is_true(report.ready)
            test.eq(report.pending_migrations[1], "demo:data\ndemo:001")
            local missing_candidate, missing_context = logical(nil)
            test.is_true(has(checked(missing_candidate, missing_context), "MISSING_DATABASE_BINDING"))
            local wrong_candidate, wrong_context = logical({database_id = "demo:run"})
            test.is_true(has(checked(wrong_candidate, wrong_context), "MISSING_DATABASE"))
            candidate, context = logical({database_id = "host:db"})
            candidate.entries[#candidate.entries + 1] = {id = "host:db", kind = "db.sql.sqlite",
                package = "wolfy-j/demo", digest = string.rep("b", 64), references = {}, auto_start = false,
                grants = {}, modules = {}, config_objects = {}, config_lists = {}, config_empty = {}}
            test.is_true(has(checked(candidate, context), "DATABASE_REPLACEMENT"))
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
            context.entries["demo:run"] = {id = "demo:run", kind = "function.lua", package = "other/owner", digest = SHA, references = {}, auto_start = false, grants = {}, modules = {}, config_objects = {}, config_lists = {}, config_empty = {}}
            candidate.entries[1].references = {"demo:missing"}
            local report = checked(candidate, context)
            test.is_true(has(report, "ENTRY_COLLISION"))
            test.is_true(has(report, "DANGLING_REFERENCE"))
            context.entries["demo:removed"] = {id = "demo:removed", kind = "function.lua", package = "wolfy-j/demo", digest = SHA, references = {}, auto_start = false, grants = {}, modules = {}, config_objects = {}, config_lists = {}, config_empty = {}}
            candidate.entries[1].references = {"demo:removed"}
            test.is_true(has(checked(candidate, context), "DANGLING_REFERENCE"))
        end)
        test.it("attributes only the references this plan is answerable for", function()
            local candidate, context = fixture()
            -- The destination host supplies part of its own composition out of
            -- band. An entry already pointing at an absent target is the host's
            -- standing state, not a fault this candidate introduces.
            context.entries["host:option"] = {id = "host:option", kind = "function.lua", package = "host", digest = SHA, references = {"host:supplied"}, auto_start = false, grants = {}, modules = {}, config_objects = {}, config_lists = {}, config_empty = {}}
            local report = checked(candidate, context)
            test.is_true(report.ready)
            test.is_false(has(report, "DANGLING_REFERENCE"))
            -- Removing a target that a retained entry still references is a
            -- fault this candidate does introduce.
            context.entries["host:option"].references = {"demo:retired"}
            context.entries["demo:retired"] = {id = "demo:retired", kind = "function.lua", package = "wolfy-j/demo", digest = SHA, references = {}, auto_start = false, grants = {}, modules = {}, config_objects = {}, config_lists = {}, config_empty = {}}
            test.is_true(has(checked(candidate, context), "DANGLING_REFERENCE"))
        end)
        test.it("validates removals against the separately installed private overlay", function()
            local candidate, context = fixture()
            local retained: preflight.Entry = {id = "host:option", kind = "function.lua", package = "host",
                digest = SHA, references = {"demo:retired"}, auto_start = false, grants = {}, modules = {},
                config_objects = {}, config_lists = {}, config_empty = {}}
            local retired: preflight.Entry = {id = "demo:retired", kind = "function.lua", package = "wolfy-j/demo",
                digest = SHA, references = {}, auto_start = false, grants = {}, modules = {},
                config_objects = {}, config_lists = {}, config_empty = {}}
            context.entries[retained.id] = retained
            context.installed_entries = {[retired.id] = retired}
            local report = checked(candidate, context)
            test.is_false(report.ready)
            test.is_true(has(report, "DANGLING_REFERENCE"))
            candidate.entries[#candidate.entries + 1] = retired
            test.is_true(checked(candidate, context).ready)
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
        test.it("refuses changed physical evidence for an applied migration chain", function()
            local candidate, context = fixture()
            context.applied["host:db\ndemo:001"] = candidate.migrations[1]
            context.applied_databases = {["host:db"] = {database_id = "host:db", kind = "db.sql.sqlite",
                package = "host", digest = string.rep("b", 64)}}
            local changed = checked(candidate, context)
            test.is_true(has(changed, "APPLIED_DATABASE_CHANGED"))
            context.applied_databases["host:db"].digest = SHA
            local stable = checked(candidate, context)
            test.is_true(stable.ready)
            test.is_false(stable.plan_digest == changed.plan_digest)
        end)
        test.it("rejects activation before migrations and unauthorized resource targets", function()
            local candidate, context = fixture()
            candidate.entries[1].auto_start = true
            candidate.entries[1].grants = {"bee.security.approvals:approval_owner_policy"}
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
        test.it("decodes the reviewed candidate only from its exact measured bytes", function()
            local candidate = fixture()
            local bytes = assert(canonical.encode(candidate, 1048576))
            local digest = assert(hash.sha256(bytes))
            local decoded = assert(preflight.decode_candidate(bytes, digest))
            test.eq(decoded.base_digest, candidate.base_digest)
            test.eq(decoded.base_revision, candidate.base_revision)
            test.eq(#decoded.entries, 1)
            test.eq(decoded.entries[1].id, "demo:run")
            test.eq(decoded.entries[1].kind, "function.lua")
            test.eq(decoded.requirements[1].value, "host:db")
            test.eq(decoded.migrations[1].ordinal, 1)
            test.is_nil(preflight.decode_candidate(bytes .. " ", digest))
            test.is_nil(preflight.decode_candidate(bytes, string.rep("b", 64)))
            local widened = assert(canonical.encode({destination_node = candidate.destination_node,
                source_node = candidate.source_node, base_revision = candidate.base_revision,
                base_digest = candidate.base_digest, artifacts = candidate.artifacts,
                entries = candidate.entries, requirements = candidate.requirements,
                migrations = candidate.migrations, resolver = "overlay"}, 1048576))
            test.is_nil(preflight.decode_candidate(widened, assert(hash.sha256(widened))))
        end)
    end)
end
return test.run_cases(define_tests)
