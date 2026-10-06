-- MIT. Immutable destination-local work for a later migration owner.
--
-- This module captures exact migration definitions and their destination SQL
-- bindings. It performs no database access, approval, publication or execution.
local artifact = require("artifact")
local canonical = require("canonical")
local hash = require("hash")
local json = require("json")
local preflight = require("preflight")
local bounds = require("bounds")

local M = {}

M.SCHEMA = "bee.governance-migration-work@3"
M.LEGACY_SCHEMA = "bee.governance-migration-work@2"
M.MAX_MIGRATIONS = 128
M.MAX_DATABASES = 128
M.MAX_BYTES = 1048576

type Schema = "bee.governance-migration-work@3" | "bee.governance-migration-work@2"
type Object = {[string]: unknown}
type Migration = {id: string, target_db: string, ordinal: integer, checksum: string, package: string, definition: Object}
type DatabaseKind = "db.sql.sqlite" | "db.sql.postgres" | "db.sql.mysql"
type Database = {target_db: string, database_id: string, table_prefix: string?, kind: DatabaseKind,
    package: string, digest: string, planned: boolean, definition: Object?}
type Payload = {schema_revision: Schema, destination_node: string, source_node: string, base_revision: integer,
    base_digest: string, policy_digest: string, candidate_digest: string, artifact_digest: string,
    plan_digest: string, migrations: {Migration}, databases: {Database}}
type Work = Payload & {bytes: string, digest: string}

local function object(value: unknown): Object?
    return bounds.object(value)
end

local function fields(value: Object, allowed: {string}): string?
    return bounds.fields(value, allowed)
end

local function dense(value: unknown, label: string, maximum: integer): ({unknown}?, string?)
    return bounds.dense_list(value, maximum, label)
end

local function identifier(value: unknown): string?
    if type(value) ~= "string" then return nil end
    if #value == 0 then return nil end
    if #value > 160 then return nil end
    if value:find("%c") then return nil end
    return value
end

-- Registry source roots use the empty owner marker. It is still host-captured
-- provenance and is compared exactly on recovery; unlike authored package
-- identities, it does not need to be nonempty.
local function owner(value: unknown): string?
    if type(value) ~= "string" then return nil end
    if #value > 160 then return nil end
    if value:find("%c") then return nil end
    return value
end

local function registry_id(value: unknown): string?
    local id = identifier(value)
    if not id then return nil end
    if not id:match("^[A-Za-z0-9][A-Za-z0-9_.-]*:[A-Za-z0-9][A-Za-z0-9_.-]*$") then return nil end
    return id
end

-- A migration's logical database target: a host database's registry ID or
-- the name of the application database the host provisions for the grant.
local function target(value: unknown): string?
    local id = registry_id(value)
    if id then return id end
    local name = identifier(value)
    if not name or #name > 64 or not name:match("^[A-Za-z][A-Za-z0-9_]*$") then return nil end
    return name
end

local function package_name(value: unknown): string?
    local name = identifier(value)
    if not name then return nil end
    local organization, module = name:match("^([%w_.-]+)/([%w_.-]+)$")
    if not organization then return nil end
    if not module then return nil end
    if organization == "." then return nil end
    if organization == ".." then return nil end
    if module == "." then return nil end
    if module == ".." then return nil end
    return name
end

local function sha(value: unknown): string?
    if type(value) ~= "string" then return nil end
    if #value ~= 64 then return nil end
    if not value:match("^[0-9a-f]+$") then return nil end
    return value
end

local function database_kind(value: unknown): DatabaseKind?
    if value == "db.sql.sqlite" then return "db.sql.sqlite" end
    if value == "db.sql.postgres" then return "db.sql.postgres" end
    if value == "db.sql.mysql" then return "db.sql.mysql" end
    return nil
end

local function digest(bytes: string): (string?, string?)
    local measured, problem = hash.sha256(bytes)
    if not measured then return nil, tostring(problem or "measure migration work") end
    return measured, nil
end

local function definition_digest(value: Object): (string?, string?)
    local bytes, encode_error = canonical.encode(value, artifact.MAX_BYTES)
    if not bytes then return nil, tostring(encode_error or "encode migration definition") end
    return digest(bytes)
end

local function normalize(raw: unknown): (Payload?, string?)
    local value = object(raw)
    if not value then return nil, "migration work must be an object" end
    local extra = fields(value, {"schema_revision", "destination_node", "source_node", "base_revision", "base_digest",
        "policy_digest", "candidate_digest", "artifact_digest", "plan_digest", "migrations", "databases"})
    if extra then return nil, extra end
    local destination, source = identifier(value.destination_node), identifier(value.source_node)
    local revision = value.base_revision
    local base_digest, policy_digest = sha(value.base_digest), sha(value.policy_digest)
    local candidate_digest, artifact_digest, plan_digest = sha(value.candidate_digest), sha(value.artifact_digest), sha(value.plan_digest)
    local schema: Schema? = nil
    if value.schema_revision == M.SCHEMA then schema = M.SCHEMA
    elseif value.schema_revision == M.LEGACY_SCHEMA then schema = M.LEGACY_SCHEMA end
    if not schema then return nil, "migration work schema is invalid" end
    if not destination then return nil, "migration work identity is invalid" end
    if not source then return nil, "migration work identity is invalid" end
    if type(revision) ~= "number" then return nil, "migration work base revision is invalid" end
    if revision ~= math.floor(revision) then return nil, "migration work base revision is invalid" end
    if revision < 0 then return nil, "migration work base revision is invalid" end
    if revision > 9007199254740991 then return nil, "migration work base revision is invalid" end
    if not base_digest then return nil, "migration work base digest is invalid" end
    if not policy_digest then return nil, "migration work policy digest is invalid" end
    if not candidate_digest then return nil, "migration work candidate digest is invalid" end
    if not artifact_digest then return nil, "migration work artifact digest is invalid" end
    if not plan_digest then return nil, "migration work plan digest is invalid" end

    local supplied_migrations, migration_error = dense(value.migrations, "migration work migrations", M.MAX_MIGRATIONS)
    if not supplied_migrations then return nil, migration_error end
    local migrations: {Migration} = {}
    local seen_migrations: {[string]: boolean} = {}
    local seen_ids: {[string]: boolean} = {}
    local seen_ordinals: {[string]: boolean} = {}
    local previous_target, previous_ordinal, previous_id = "", 0, ""
    for index, raw_migration in ipairs(supplied_migrations) do
        local item = object(raw_migration)
        if not item then return nil, "migration work migrations[" .. tostring(index) .. "] must be an object" end
        local extra_migration = fields(item, {"id", "target_db", "ordinal", "checksum", "package", "definition"})
        if extra_migration then return nil, extra_migration end
        local id, target_db = registry_id(item.id), target(item.target_db)
        local ordinal, checksum, package = item.ordinal, sha(item.checksum), package_name(item.package)
        local definition = object(item.definition)
        if not id then return nil, "migration work contains an invalid migration definition" end
        if not target_db then return nil, "migration work contains an invalid migration definition" end
        if type(ordinal) ~= "number" then return nil, "migration work contains an invalid migration definition" end
        if ordinal ~= math.floor(ordinal) then return nil, "migration work contains an invalid migration definition" end
        if ordinal < 1 then return nil, "migration work contains an invalid migration definition" end
        if ordinal > 9007199254740991 then return nil, "migration work contains an invalid migration definition" end
        if not checksum then return nil, "migration work contains an invalid migration definition" end
        if not package then return nil, "migration work contains an invalid migration definition" end
        if not definition then return nil, "migration work contains an invalid migration definition" end
        local key = target_db .. "\n" .. id
        local ordinal_key = target_db .. "\n" .. tostring(ordinal)
        if seen_migrations[key] then return nil, "migration work migrations are duplicated or out of order" end
        if seen_ids[id] then return nil, "migration work migrations are duplicated or out of order" end
        if seen_ordinals[ordinal_key] then return nil, "migration work migrations are duplicated or out of order" end
        if target_db < previous_target then return nil, "migration work migrations are duplicated or out of order" end
        if (target_db == previous_target and (ordinal < previous_ordinal
                or (ordinal == previous_ordinal and id <= previous_id))) then return nil, "migration work migrations are duplicated or out of order" end
        if definition.id ~= id then return nil, "migration work definition identity or kind differs" end
        if definition.kind ~= "function.lua" then return nil, "migration work definition identity or kind differs" end
        local meta = object(definition.meta)
        if not meta then return nil, "migration work definition metadata differs" end
        if meta.type ~= "migration" then return nil, "migration work definition metadata differs" end
        if meta.target_db ~= target_db then return nil, "migration work definition metadata differs" end
        if meta.ordinal ~= ordinal then return nil, "migration work definition metadata differs" end
        local validated, artifact_error = artifact.create({definition})
        if not validated then return nil, artifact_error end
        definition = object(validated.entries[1])
        if not definition then return nil, "migration work definition could not be copied" end
        local measured, measure_error = definition_digest(definition)
        if not measured then return nil, measure_error end
        if measured ~= checksum then return nil, "migration work definition checksum differs" end
        migrations[#migrations + 1] = {id = id, target_db = target_db, ordinal = ordinal,
            checksum = checksum, package = package, definition = definition}
        seen_migrations[key], seen_ids[id], seen_ordinals[ordinal_key] = true, true, true
        previous_target, previous_ordinal, previous_id = target_db, ordinal, id
    end

    local supplied_databases, database_error = dense(value.databases, "migration work databases", M.MAX_DATABASES)
    if not supplied_databases then return nil, database_error end
    local databases: {Database} = {}
    local seen_targets: {[string]: boolean} = {}
    local physical_evidence: {[string]: string} = {}
    local previous_target = ""
    for index, raw_database in ipairs(supplied_databases) do
        local item = object(raw_database)
        if not item then return nil, "migration work databases[" .. tostring(index) .. "] must be an object" end
        local database_fields: {string}
        if schema == M.LEGACY_SCHEMA then
            database_fields = {"id", "kind", "package", "digest", "planned", "definition"}
        else
            database_fields = {"target_db", "database_id", "table_prefix", "kind", "package", "digest", "planned", "definition"}
        end
        local extra_database = fields(item, database_fields)
        if extra_database then return nil, extra_database end
        local target_db = schema == M.LEGACY_SCHEMA and registry_id(item.id) or target(item.target_db)
        local database_id = registry_id(schema == M.LEGACY_SCHEMA and item.id or item.database_id)
        local prefix: string? = nil
        if schema ~= M.LEGACY_SCHEMA and item.table_prefix ~= nil then
            prefix = identifier(item.table_prefix)
            if not prefix then return nil, "migration work contains an invalid database prefix" end
            if #prefix > 64 then return nil, "migration work contains an invalid database prefix" end
            if not prefix:match("^[A-Za-z][A-Za-z0-9_]*$") then return nil, "migration work contains an invalid database prefix" end
        end
        local kind, package, measured = database_kind(item.kind), owner(item.package), sha(item.digest)
        if not target_db then return nil, "migration work database has an invalid logical target" end
        if not database_id then return nil, "migration work database has an invalid physical identity" end
        if not kind then return nil, "migration work database has an invalid SQL kind" end
        if not package then return nil, "migration work database has no trusted owner" end
        if not measured then return nil, "migration work database has an invalid definition digest" end
        if type(item.planned) ~= "boolean" then return nil, "migration work database has no planned-state evidence" end
        if seen_targets[target_db] then return nil, "migration work database targets are duplicated or out of order" end
        if target_db <= previous_target then return nil, "migration work database targets are duplicated or out of order" end
        local definition: Object? = nil
        if item.planned then
            definition = object(item.definition)
            if not definition then return nil, "planned migration database definition differs" end
            if definition.id ~= database_id then return nil, "planned migration database definition differs" end
            if definition.kind ~= kind then return nil, "planned migration database definition differs" end
            local definition_measure, measure_error = definition_digest(definition)
            if not definition_measure then return nil, measure_error end
            if definition_measure ~= measured then return nil, "planned migration database digest differs" end
            local validated, artifact_error = artifact.create({definition})
            if not validated then return nil, artifact_error end
            definition = object(validated.entries[1])
            if not definition then return nil, "planned database definition could not be copied" end
        elseif item.definition ~= nil then
            return nil, "existing migration database must not carry a package definition"
        end
        local evidence = table.concat({kind, package, measured,
            item.planned and "1" or "0", definition and assert(canonical.encode(definition, artifact.MAX_BYTES)) or ""}, "\n")
        if physical_evidence[database_id] and physical_evidence[database_id] ~= evidence then
            return nil, "migration work physical database evidence differs"
        end
        physical_evidence[database_id] = evidence
        if schema == M.LEGACY_SCHEMA then
            databases[#databases + 1] = {target_db = target_db, database_id = database_id, kind = kind,
                package = package, digest = measured, planned = item.planned, definition = definition}
        else
            local database: Database = {target_db = target_db, database_id = database_id, kind = kind,
                package = package, digest = measured, planned = item.planned, definition = definition}
            if prefix then database.table_prefix = prefix end
            databases[#databases + 1] = database
        end
        seen_targets[target_db], previous_target = true, target_db
    end
    local required_databases: {[string]: boolean} = {}
    for _, migration in ipairs(migrations) do required_databases[migration.target_db] = true end
    for id in pairs(required_databases) do
        if not seen_targets[id] then return nil, "migration work is missing database " .. id end
    end
    for id in pairs(seen_targets) do
        if not required_databases[id] then return nil, "migration work contains an unused database " .. id end
    end
    local payload: Payload = {schema_revision = schema, destination_node = destination, source_node = source,
        base_revision = math.floor(revision), base_digest = base_digest, policy_digest = policy_digest,
        candidate_digest = candidate_digest, artifact_digest = artifact_digest, plan_digest = plan_digest,
        migrations = migrations, databases = databases}
    return payload, nil
end

local function seal(payload: Payload): (Work?, string?)
    local normalized, normalize_error = normalize(payload)
    if not normalized then return nil, normalize_error end
    local bytes, encode_error = canonical.encode(normalized, M.MAX_BYTES)
    if not bytes then return nil, encode_error or "migration work exceeds byte bound" end
    if #bytes > M.MAX_BYTES then return nil, encode_error or "migration work exceeds byte bound" end
    local measured, measure_error = digest(bytes)
    if not measured then return nil, measure_error end
    local work: Work = {schema_revision = normalized.schema_revision, destination_node = normalized.destination_node,
        source_node = normalized.source_node, base_revision = normalized.base_revision,
        base_digest = normalized.base_digest, policy_digest = normalized.policy_digest,
        candidate_digest = normalized.candidate_digest, artifact_digest = normalized.artifact_digest,
        plan_digest = normalized.plan_digest, migrations = normalized.migrations, databases = normalized.databases,
        bytes = bytes, digest = measured}
    return work, nil
end

local function full_artifact(raw: unknown): (artifact.Artifact?, string?)
    local value = object(raw)
    if not value then return nil, "migration work artifact must be an object" end
    local valid, verify_error = artifact.verify(value)
    if not valid then return nil, verify_error end
    local entries, decode_error = artifact.decode(value.bytes, value.digest)
    if not entries then return nil, decode_error end
    local copied, copy_error = artifact.create(entries)
    if not copied then return nil, copy_error end
    if copied.bytes ~= value.bytes then return nil, "migration work artifact changed during capture" end
    if copied.digest ~= value.digest then return nil, "migration work artifact changed during capture" end
    return copied, nil
end

-- The definition of the application database the capability proposal
-- provisions under database_id, when it provisions one.
local function provisioned(context: preflight.Context, database_id: string): Object?
    local evidence = context.host_evidence.capability
    if evidence.kind == "absent" then return nil end
    for _, raw in ipairs(evidence.proposal.databases) do
        local entry = object(raw)
        if entry and entry.id == database_id then return entry end
    end
    return nil
end

function M.capture(candidate: preflight.Candidate, artifact_raw: unknown,
    context: preflight.Context): (Work?, string?)
    local exact_artifact, artifact_error = full_artifact(artifact_raw)
    if not exact_artifact then return nil, artifact_error end
    local report, preflight_error = preflight.check(candidate, context)
    if not report then return nil, preflight_error end
    if not report.ready then
        local reasons: {string} = {}
        for index, diagnostic in ipairs(report.diagnostics) do
            if index > 8 then break end
            reasons[#reasons + 1] = diagnostic.code .. ":" .. diagnostic.target
        end
        return nil, "destination preflight is not ready for migration work: " .. table.concat(reasons, ", ")
    end

    local candidate_bytes, candidate_error = canonical.encode(candidate, 1048576)
    if not candidate_bytes then return nil, candidate_error or "encode migration candidate" end
    local candidate_digest, candidate_measure_error = digest(candidate_bytes)
    if not candidate_digest then return nil, candidate_measure_error end

    local artifact_entries: {[string]: Object} = {}
    for _, raw_entry in ipairs(exact_artifact.entries) do
        local entry = object(raw_entry)
        if not entry then return nil, "migration work artifact contains an invalid entry" end
        if entry.kind == "ns.dependency" then return nil, "dependency directives cannot be migration work" end
        local id = registry_id(entry.id)
        if not id then return nil, "migration work artifact contains duplicate or invalid IDs" end
        if artifact_entries[id] then return nil, "migration work artifact contains duplicate or invalid IDs" end
        artifact_entries[id] = entry
    end
    local candidate_entries, entry_error = dense(candidate.entries, "candidate entries", artifact.MAX_ENTRIES)
    if not candidate_entries then return nil, entry_error end
    if #candidate_entries ~= #exact_artifact.entries then return nil, "migration candidate does not match the exact artifact closure" end
    local selected_ids: {[string]: boolean} = {}
    for _, raw_entry in ipairs(candidate_entries) do
        local selected = object(raw_entry)
        local id = selected and registry_id(selected.id) or nil
        local full = id and artifact_entries[id] or nil
        if not selected then return nil, "migration candidate omits or changes an artifact entry" end
        if not id then return nil, "migration candidate omits or changes an artifact entry" end
        if selected_ids[id] then return nil, "migration candidate omits or changes an artifact entry" end
        if not full then return nil, "migration candidate omits or changes an artifact entry" end
        if selected.kind ~= full.kind then return nil, "migration candidate omits or changes an artifact entry" end
        local measured, measure_error = definition_digest(full)
        if not measured then return nil, measure_error end
        if selected.digest ~= measured then return nil, "migration candidate entry digest differs from artifact" end
        selected_ids[id] = true
    end

    local migrations_by_key: {[string]: preflight.Migration} = {}
    for _, item in ipairs(candidate.migrations) do
        local key = item.target_db .. "\n" .. item.id
        if migrations_by_key[key] then return nil, "migration candidate contains duplicate work" end
        migrations_by_key[key] = item
        local entry = artifact_entries[item.id]
        local meta = entry and object(entry.meta) or nil
        if not entry then return nil, "migration candidate differs from its exact artifact definition: " .. item.id end
        if entry.kind ~= "function.lua" then return nil, "migration candidate differs from its exact artifact definition: " .. item.id end
        if not meta then return nil, "migration candidate differs from its exact artifact definition: " .. item.id end
        if meta.type ~= "migration" then return nil, "migration candidate differs from its exact artifact definition: " .. item.id end
        if meta.target_db ~= item.target_db then return nil, "migration candidate differs from its exact artifact definition: " .. item.id end
        if meta.ordinal ~= item.ordinal then return nil, "migration candidate differs from its exact artifact definition: " .. item.id end
        local measured, measure_error = definition_digest(entry)
        if not measured then return nil, measure_error end
        if measured ~= item.checksum then return nil, "migration checksum differs from its exact artifact definition: " .. item.id end
    end

    local pending: {preflight.Migration} = {}
    for _, key in ipairs(report.pending_migrations) do
        local target_db, id = preflight.migration_parts(key)
        local item = target_db and id and migrations_by_key[preflight.migration_key({target_db = target_db, id = id})] or nil
        if not item then return nil, "preflight migration is outside the exact candidate" end
        pending[#pending + 1] = item
    end
    table.sort(pending, function(left: preflight.Migration, right: preflight.Migration): boolean
        if left.target_db ~= right.target_db then return left.target_db < right.target_db end
        if left.ordinal ~= right.ordinal then return left.ordinal < right.ordinal end
        return left.id < right.id
    end)
    if #pending > M.MAX_MIGRATIONS then return nil, "pending migration work exceeds its bound" end

    local target_ids: {[string]: boolean} = {}
    for _, item in ipairs(pending) do target_ids[item.target_db] = true end
    local databases: {Database} = {}
    for target_db in pairs(target_ids) do
        local binding = context.database_bindings and context.database_bindings[target_db] or nil
        if context.database_bindings ~= nil and not binding then
            return nil, "migration database has no host binding: " .. target_db
        end
        local database_id = binding and binding.database_id or target_db
        if not context.databases[target_db] then return nil, "migration database is not an admitted host SQL resource: " .. target_db end
        local summary = context.entries[database_id]
        local planned: Object? = nil
        -- An application database the capability grant provisions is this
        -- overlay's own: installed by an earlier version, or planned here and
        -- installed before its migrations run.
        local generated = context.generated_databases and context.generated_databases[database_id] == target_db
        if not summary and generated then
            summary = context.installed_entries and context.installed_entries[database_id] or nil
            if not summary then planned = provisioned(context, database_id) end
        end
        if planned then
            local kind = database_kind(planned.kind)
            local measured, measure_error = definition_digest(planned)
            if not kind then return nil, "planned migration database is not an SQL resource: " .. target_db end
            if not measured then return nil, measure_error end
            if #candidate.artifacts ~= 1 then return nil, "planned migration database has no single owning package: " .. target_db end
            databases[#databases + 1] = {target_db = target_db, database_id = database_id,
                table_prefix = binding and binding.table_prefix or nil, kind = kind,
                package = candidate.artifacts[1].component, digest = measured, planned = true, definition = planned}
        else
            if not summary then return nil, "migration database is not an admitted host SQL resource: " .. target_db end
            local kind = database_kind(summary.kind)
            if not kind then return nil, "migration database is not an admitted host SQL resource: " .. target_db end
            databases[#databases + 1] = {target_db = target_db, database_id = database_id,
                table_prefix = binding and binding.table_prefix or nil, kind = kind,
                package = summary.package, digest = summary.digest, planned = false, definition = nil}
        end
    end
    table.sort(databases, function(left: Database, right: Database): boolean return left.target_db < right.target_db end)

    local work_migrations: {Migration} = {}
    for _, item in ipairs(pending) do
        local definition = artifact_entries[item.id]
        if not definition then return nil, "pending migration is missing from its exact artifact: " .. item.id end
        local summary: preflight.Entry? = nil
        for _, candidate_entry in ipairs(candidate.entries) do
            if candidate_entry.id == item.id then summary = candidate_entry; break end
        end
        if not summary then return nil, "pending migration has no trusted package owner: " .. item.id end
        work_migrations[#work_migrations + 1] = {id = item.id, target_db = item.target_db,
            ordinal = item.ordinal, checksum = item.checksum, package = summary.package, definition = definition}
    end
    return seal({schema_revision = M.SCHEMA, destination_node = candidate.destination_node,
        source_node = candidate.source_node, base_revision = candidate.base_revision,
        base_digest = candidate.base_digest, policy_digest = context.policy_digest,
        candidate_digest = candidate_digest, artifact_digest = exact_artifact.digest,
        plan_digest = report.plan_digest, migrations = work_migrations, databases = databases})
end

function M.decode(bytes_raw: unknown, digest_raw: unknown): (Work?, string?)
    if type(bytes_raw) ~= "string" then
        return nil, "migration work bytes exceed bound"
    end
    local bytes = bytes_raw
    if #bytes == 0 then return nil, "migration work bytes exceed bound" end
    if #bytes > M.MAX_BYTES then return nil, "migration work bytes exceed bound" end
    local recorded = sha(digest_raw)
    if not recorded then return nil, "migration work digest is malformed" end
    local measured, measure_error = digest(bytes)
    if not measured then return nil, measure_error end
    if measured ~= recorded then return nil, "migration work digest does not match bytes" end
    local decoded, decode_error = json.decode(bytes)
    if decode_error then return nil, "migration work bytes are not JSON" end
    local canonical_input, input_error = canonical.encode(decoded, M.MAX_BYTES)
    if not canonical_input then return nil, input_error or "migration work bytes are not canonical" end
    if canonical_input ~= bytes then return nil, input_error or "migration work bytes are not canonical" end
    local normalized, normalize_error = normalize(decoded)
    if not normalized then return nil, normalize_error end
    local work: Work = {schema_revision = normalized.schema_revision, destination_node = normalized.destination_node,
        source_node = normalized.source_node, base_revision = normalized.base_revision,
        base_digest = normalized.base_digest, policy_digest = normalized.policy_digest,
        candidate_digest = normalized.candidate_digest, artifact_digest = normalized.artifact_digest,
        plan_digest = normalized.plan_digest, migrations = normalized.migrations, databases = normalized.databases,
        bytes = bytes, digest = recorded}
    return work, nil
end

-- Resolve one logical target from already validated immutable work. Legacy
-- work used one `id` for both sides and never carried a prefix.
function M.database(work: Work, target_raw: unknown): (Database?, string?)
    local wanted = target(target_raw)
    if not wanted then
        return nil, "migration work database lookup is invalid"
    end
    local found: Database? = nil
    for _, item in ipairs(work.databases) do
        if item.target_db == wanted then
            if found then return nil, "migration work database binding is ambiguous" end
            found = item
        end
    end
    if not found then return nil, "migration work is missing database " .. wanted end
    return found, nil
end

-- forward_only: prove a compensating migration set advances a target ledger
-- instead of rewriting it. Applied migrations are immutable and forward-only,
-- so a revert may not re-run or renumber an applied migration: every
-- compensating migration targets a database it does not already occupy and
-- carries an ordinal strictly greater than the highest applied ordinal for
-- that target. Pure: it reads no database and changes nothing.
function M.forward_only(applied: unknown, migrations: unknown): (boolean, string?)
    if type(applied) ~= "table" then return false, "applied migration evidence must be a table" end
    if type(migrations) ~= "table" then return false, "compensating migrations must be a table" end
    local highest: {[string]: integer} = {}
    local occupied: {[string]: boolean} = {}
    for key, raw in pairs(applied) do
        if type(key) ~= "string" then return false, "applied migration keys must be strings" end
        local row = object(raw)
        if not row then return false, "applied migration evidence is malformed" end
        local applied_target, ordinal = target(row.target_db), row.ordinal
        if not applied_target then return false, "applied migration evidence is malformed" end
        if type(ordinal) ~= "number" then return false, "applied migration evidence is malformed" end
        if ordinal ~= math.floor(ordinal) then return false, "applied migration evidence is malformed" end
        if ordinal < 1 then return false, "applied migration evidence is malformed" end
        local id = registry_id(row.id)
        if not id then return false, "applied migration evidence is malformed" end
        local target_key = applied_target
        local seen = highest[target_key]
        if seen == nil or ordinal > seen then highest[target_key] = ordinal end
        occupied[target_key .. "\n" .. id] = true
    end
    local previous_target, previous_ordinal, previous_id = "", 0, ""
    for index, raw in ipairs(migrations) do
        local item = object(raw)
        if not item then return false, "compensating migration " .. tostring(index) .. " is malformed" end
        local id, compensated, ordinal = registry_id(item.id), target(item.target_db), item.ordinal
        if not id then return false, "compensating migration identity is invalid" end
        if not compensated then return false, "compensating migration identity is invalid" end
        if type(ordinal) ~= "number" then return false, "compensating migration identity is invalid" end
        if ordinal ~= math.floor(ordinal) then return false, "compensating migration identity is invalid" end
        if ordinal < 1 then return false, "compensating migration identity is invalid" end
        if occupied[compensated .. "\n" .. id] then
            return false, "compensating migration re-runs an applied migration: " .. id
        end
        local target_key = compensated
        local floor = highest[target_key]
        if floor ~= nil and ordinal <= floor then
            return false, "compensating migration does not move forward on " .. compensated .. ": " .. id
        end
        if compensated < previous_target then return false, "compensating migrations are duplicated or out of order" end
        if (compensated == previous_target and (ordinal < previous_ordinal
                or (ordinal == previous_ordinal and id <= previous_id))) then return false, "compensating migrations are duplicated or out of order" end
        previous_target, previous_ordinal, previous_id = compensated, ordinal, id
    end
    return true, nil
end

function M.verify(raw: unknown, candidate: preflight.Candidate, artifact_raw: unknown,
    context: preflight.Context): (boolean, string?)
    local supplied = object(raw)
    if not supplied then return false, "migration work must be an object" end
    local bytes, recorded = supplied.bytes, supplied.digest
    if type(bytes) ~= "string" then return false, "migration work bytes are missing" end
    local decoded, decode_error = M.decode(bytes, recorded)
    if not decoded then return false, decode_error end
    local payload: Object = {}
    for field, value in pairs(supplied) do
        if field ~= "bytes" and field ~= "digest" then payload[field] = value end
    end
    local normalized, normalize_error = normalize(payload)
    if not normalized then return false, normalize_error end
    local supplied_bytes, encode_error = canonical.encode(normalized, M.MAX_BYTES)
    if not supplied_bytes then return false, encode_error or "migration work fields differ from its bytes" end
    if supplied_bytes ~= bytes then return false, encode_error or "migration work fields differ from its bytes" end
    local expected, capture_error = M.capture(candidate, artifact_raw, context)
    if not expected then return false, capture_error end
    if expected.bytes ~= decoded.bytes then return false, "migration work differs from the destination candidate, artifact or context" end
    if expected.digest ~= decoded.digest then return false, "migration work differs from the destination candidate, artifact or context" end
    return true, nil
end

return M
