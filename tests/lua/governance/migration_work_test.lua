-- MIT. Migration work is a pure exact receipt; these tests perform no writes.
local test = require("test")
local migration_work = require("migration_work")
local artifact = require("artifact")
local canonical = require("canonical")
local preflight = require("preflight")
local hash = require("hash")

local SHA = string.rep("a", 64)
type Object = {[string]: unknown}

local function measured(value: {[string]: unknown}): string
    local bytes, problem = canonical.encode(value)
    if not bytes then error(tostring(problem)) end
    local digest, digest_error = hash.sha256(bytes)
    if not digest then error(tostring(digest_error)) end
    return digest
end

local function fixture(existing_database: boolean?): (artifact.Artifact, preflight.Candidate, preflight.Context)
    local target_db = existing_database and "host:db" or "demo:db"
    local migration: {[string]: unknown} = {id = "demo:001", kind = "function.lua",
        meta = {type = "migration", target_db = target_db, ordinal = 1}, data = {up = "create table users"}}
    local definitions: {{[string]: unknown}} = {migration}
    local candidate_entries: {preflight.Entry} = {{id = migration.id :: string, kind = migration.kind :: string,
        package = "demo/app", digest = measured(migration), references = {}, auto_start = false, grants = {}, modules = {}, config_objects = {}, config_lists = {}, config_empty = {}}}
    local host_database: preflight.Entry = {id = "host:db",
        kind = "db.sql.sqlite", package = "host/storage", digest = SHA, references = {}, auto_start = false,
        grants = {}, modules = {}, config_objects = {}, config_lists = {}, config_empty = {}}
    local destination_entries: {[string]: preflight.Entry} = {["host:db"] = host_database}
    local exact = assert(artifact.create(definitions))
    local candidate: preflight.Candidate = {destination_node = "node-a", source_node = "node-b", base_revision = 7,
        base_digest = SHA, artifacts = {{component = "demo/app", version = "1.0.0", digest = SHA,
            dependencies = {}, namespaces = {"demo"}}}, entries = candidate_entries, requirements = {},
        migrations = {{id = "demo:001", target_db = target_db, checksum = measured(migration), ordinal = 1}}}
    local bindings: {[string]: preflight.DatabaseBinding}? = nil
    if not existing_database then
        bindings = {["demo:db"] = {database_id = "host:db", table_prefix = "demo_"}}
    end
    local context: preflight.Context = {node_id = "node-a", registry_revision = 7, registry_digest = SHA,
        policy_digest = SHA, packages = {["demo/app"] = true}, namespaces = {demo = true},
        kinds = {["db.sql.sqlite"] = true, ["function.lua"] = true}, databases = {[target_db] = true},
        grants = {}, modules = {}, database_bindings = bindings,
        entries = destination_entries, installed_entries = nil, applied = {}, exact_expansion = true,
        migration_barrier = false}
    return exact, candidate, context
end

local function define_tests()
    test.describe("Governance exact migration work", function()
        test.it("captures canonical pending definitions and their final SQL binding", function()
            local exact, candidate, context = fixture()
            local work, problem = migration_work.capture(candidate, exact, context)
            if not work then error(tostring(problem)) end
            test.eq(work.schema_revision, migration_work.SCHEMA)
            test.eq(#work.migrations, 1)
            test.eq(work.migrations[1].id, "demo:001")
            test.eq(work.migrations[1].package, "demo/app")
            test.eq(work.migrations[1].definition.data.up, "create table users")
            test.eq(#work.databases, 1)
            test.eq(work.databases[1].target_db, "demo:db")
            test.eq(work.databases[1].database_id, "host:db")
            test.eq(work.databases[1].table_prefix, "demo_")
            test.is_false(work.databases[1].planned)
            test.is_nil(work.databases[1].definition)
            local decoded, decode_error = migration_work.decode(work.bytes, work.digest)
            if not decoded then error(tostring(decode_error)) end
            test.eq(decoded.bytes, work.bytes)
            test.eq(decoded.digest, work.digest)
            test.is_true(assert(migration_work.verify(work, candidate, exact, context)))
        end)

        test.it("preserves the registry root owner marker for a host database", function()
            local exact, candidate, context = fixture()
            context.entries["host:db"].package = ""
            local work, problem = migration_work.capture(candidate, exact, context)
            if not work then error(tostring(problem)) end
            test.eq(work.databases[1].package, "")
            local decoded, decode_error = migration_work.decode(work.bytes, work.digest)
            if not decoded then error(tostring(decode_error)) end
            test.eq(decoded.databases[1].package, "")
        end)

        test.it("preserves numeric order across multi-digit migration ordinals", function()
            local _, candidate, context = fixture()
            local first: {[string]: unknown} = {id = "demo:001", kind = "function.lua",
                meta = {type = "migration", target_db = "demo:db", ordinal = 2}, data = {up = "second"}}
            local later: {[string]: unknown} = {id = "demo:010", kind = "function.lua",
                meta = {type = "migration", target_db = "demo:db", ordinal = 10}, data = {up = "tenth"}}
            local exact = assert(artifact.create({first, later}))
            candidate.entries[1].digest = measured(first)
            candidate.migrations[1].checksum, candidate.migrations[1].ordinal = measured(first), 2
            candidate.entries[#candidate.entries + 1] = {id = "demo:010", kind = "function.lua", package = "demo/app",
                digest = measured(later), references = {}, auto_start = false, grants = {}, modules = {}, config_objects = {}, config_lists = {}, config_empty = {}}
            candidate.migrations[#candidate.migrations + 1] = {id = "demo:010", target_db = "demo:db",
                checksum = measured(later), ordinal = 10}
            local work = assert(migration_work.capture(candidate, exact, context))
            test.eq(work.migrations[1].ordinal, 2)
            test.eq(work.migrations[2].ordinal, 10)
            test.not_nil(migration_work.decode(work.bytes, work.digest))
        end)

        test.it("binds existing databases and the applied-migration baseline", function()
            local exact, candidate, context = fixture(true)
            local work = assert(migration_work.capture(candidate, exact, context))
            test.is_false(work.databases[1].planned)
            test.is_nil(work.databases[1].definition)
            context.applied[candidate.migrations[1].target_db .. "\ndemo:001"] = candidate.migrations[1]
            local already_applied = assert(migration_work.capture(candidate, exact, context))
            test.eq(#already_applied.migrations, 0)
            test.eq(#already_applied.databases, 0)
            test.is_false(work.digest == already_applied.digest)
            local matches = migration_work.verify(work, candidate, exact, context)
            test.is_false(matches)
        end)

        test.it("rejects drift in the destination candidate or exact artifact", function()
            local exact, candidate, context = fixture()
            local work = assert(migration_work.capture(candidate, exact, context))
            local changed_migration: {[string]: unknown} = {id = "demo:001", kind = "function.lua",
                meta = {type = "migration", target_db = "demo:db", ordinal = 1}, data = {up = "create table accounts"}}
            local changed_artifact = assert(artifact.create({
                changed_migration,
            }))
            candidate.migrations[1].checksum = measured(changed_migration)
            candidate.entries[1].digest = measured(changed_migration)
            local matches = migration_work.verify(work, candidate, changed_artifact, context)
            test.is_false(matches)
            test.is_nil(migration_work.capture(candidate, exact, context))
        end)

        test.it("decodes legacy work without rewriting its identity binding", function()
            local exact, candidate, context = fixture(true)
            local current = assert(migration_work.capture(candidate, exact, context))
            local legacy: {[string]: unknown} = {}
            for field, value in pairs(current) do
                if field ~= "bytes" and field ~= "digest" and field ~= "schema_revision" and field ~= "databases" then
                    legacy[field] = value
                end
            end
            legacy.schema_revision = migration_work.LEGACY_SCHEMA
            legacy.databases = {{id = "host:db", kind = "db.sql.sqlite", package = "host/storage",
                digest = SHA, planned = false}}
            local bytes = assert(canonical.encode(legacy))
            local digest = assert(hash.sha256(bytes))
            local decoded = assert(migration_work.decode(bytes, digest))
            test.eq(decoded.schema_revision, migration_work.LEGACY_SCHEMA)
            test.eq((decoded.databases[1] :: Object).id, "host:db")
            test.eq(decoded.bytes, bytes)
            test.eq(decoded.digest, digest)
        end)

        test.it("rejects noncanonical, tampered, and semantically forged bytes", function()
            local exact, candidate, context = fixture()
            local work = assert(migration_work.capture(candidate, exact, context))
            test.is_nil(migration_work.decode(work.bytes .. " ", assert(hash.sha256(work.bytes .. " "))))
            test.is_nil(migration_work.decode(work.bytes, string.rep("b", 64)))
            local payload: {[string]: unknown} = {}
            for field, value in pairs(work) do if field ~= "bytes" and field ~= "digest" then payload[field] = value end end
            payload.unreviewed = true
            local forged = assert(canonical.encode(payload))
            test.is_nil(migration_work.decode(forged, assert(hash.sha256(forged))))
            payload.unreviewed = nil
            payload.migrations = {{id = "other:001", target_db = "demo:db", ordinal = 1,
                checksum = SHA, definition = work.migrations[1].definition}}
            forged = assert(canonical.encode(payload))
            test.is_nil(migration_work.decode(forged, assert(hash.sha256(forged))))
        end)

        test.it("requires ready host preflight and fails closed on malformed target context", function()
            local exact, candidate, context = fixture()
            context.databases["demo:db"] = false
            test.is_nil(migration_work.capture(candidate, exact, context))
            context.databases["demo:db"] = true
            candidate.destination_node = "node-c"
            test.is_nil(migration_work.capture(candidate, exact, context))
            candidate.destination_node = "node-a"
            candidate.entries[1].package = "not-a-package"
            test.is_nil(migration_work.capture(candidate, exact, context))
        end)
    end)
end

return test.run_cases(define_tests)
