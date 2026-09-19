-- MIT. Immutable destination-local work for a later migration owner.
--
-- This module captures exact migration definitions and their destination SQL
-- bindings. It performs no database access, approval, publication or execution.
local artifact = require("artifact")
local canonical = require("canonical")
local hash = require("hash")
local json = require("json")
local preflight = require("preflight")

local M = {}

M.SCHEMA = "bee.governance-migration-work@2"
M.MAX_MIGRATIONS = 128
M.MAX_DATABASES = 128
M.MAX_BYTES = 1048576

type Object = {[string]: unknown}
type Migration = {id: string, target_db: string, ordinal: integer, checksum: string, package: string, definition: Object}
type Database = {id: string, kind: string, package: string, digest: string, planned: boolean, definition: Object?}
type Work = {schema_revision: string, destination_node: string, source_node: string, base_revision: integer,
    base_digest: string, policy_digest: string, candidate_digest: string, artifact_digest: string,
    plan_digest: string, migrations: {Migration}, databases: {Database}, bytes: string, digest: string}

local function object(value: unknown): Object?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do if type(key) ~= "string" then return nil end end
    return value :: Object
end

local function fields(value: Object, allowed: {string}): string?
    local known: {[string]: boolean} = {}
    for _, name in ipairs(allowed) do known[name] = true end
    for name in pairs(value) do
        if not known[name] then return "unknown field " .. name end
    end
    return nil
end

local function dense(value: unknown, label: string, maximum: integer): ({unknown}?, string?)
    if type(value) ~= "table" then return nil, label .. " must be a dense list" end
    local source = value :: table
    local count = 0
    for key in pairs(source) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return nil, label .. " must be a dense list"
        end
        count = count + 1
    end
    if count > maximum or count ~= #source then return nil, label .. " exceeds its bound or is sparse" end
    local result: {unknown} = {}
    for index = 1, count do
        if source[index] == nil then return nil, label .. " must be a dense list" end
        result[index] = source[index]
    end
    return result, nil
end

local function identifier(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > 160 or value:find("%c") then return nil end
    return value
end

local function registry_id(value: unknown): string?
    local id = identifier(value)
    if not id or not id:match("^[A-Za-z0-9][A-Za-z0-9_.-]*:[A-Za-z0-9][A-Za-z0-9_.-]*$") then return nil end
    return id
end

local function package_name(value: unknown): string?
    local name = identifier(value)
    if not name then return nil end
    local organization, module = name:match("^([%w_.-]+)/([%w_.-]+)$")
    if not organization or not module or organization == "." or organization == ".."
        or module == "." or module == ".." then return nil end
    return name
end

local function sha(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
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

local function normalize(raw: unknown): (Object?, string?)
    local value = object(raw)
    if not value then return nil, "migration work must be an object" end
    local extra = fields(value, {"schema_revision", "destination_node", "source_node", "base_revision", "base_digest",
        "policy_digest", "candidate_digest", "artifact_digest", "plan_digest", "migrations", "databases"})
    if extra then return nil, extra end
    local destination, source = identifier(value.destination_node), identifier(value.source_node)
    local revision = value.base_revision
    local base_digest, policy_digest = sha(value.base_digest), sha(value.policy_digest)
    local candidate_digest, artifact_digest, plan_digest = sha(value.candidate_digest), sha(value.artifact_digest), sha(value.plan_digest)
    if value.schema_revision ~= M.SCHEMA or not destination or not source
        or type(revision) ~= "number" or revision ~= math.floor(revision) or revision < 0 or revision > 9007199254740991
        or not base_digest or not policy_digest or not candidate_digest or not artifact_digest or not plan_digest then
        return nil, "migration work identity or measurement is invalid"
    end

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
        local id, target_db = registry_id(item.id), registry_id(item.target_db)
        local ordinal, checksum, package = item.ordinal, sha(item.checksum), package_name(item.package)
        local definition = object(item.definition)
        if not id or not target_db or type(ordinal) ~= "number" or ordinal ~= math.floor(ordinal)
            or ordinal < 1 or ordinal > 9007199254740991 or not checksum or not package or not definition then
            return nil, "migration work contains an invalid migration definition"
        end
        local key = target_db .. "\n" .. id
        local ordinal_key = target_db .. "\n" .. tostring(ordinal)
        if seen_migrations[key] or seen_ids[id] or seen_ordinals[ordinal_key] or target_db < previous_target
            or (target_db == previous_target and (ordinal < previous_ordinal
                or (ordinal == previous_ordinal and id <= previous_id))) then
            return nil, "migration work migrations are duplicated or out of order"
        end
        if definition.id ~= id or definition.kind ~= "function.lua" then
            return nil, "migration work definition identity or kind differs"
        end
        local meta = object(definition.meta)
        if not meta or meta.type ~= "migration" or meta.target_db ~= target_db or meta.ordinal ~= ordinal then
            return nil, "migration work definition metadata differs"
        end
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
    local seen_databases: {[string]: boolean} = {}
    local previous_database = ""
    for index, raw_database in ipairs(supplied_databases) do
        local item = object(raw_database)
        if not item then return nil, "migration work databases[" .. tostring(index) .. "] must be an object" end
        local extra_database = fields(item, {"id", "kind", "package", "digest", "planned", "definition"})
        if extra_database then return nil, extra_database end
        local id, kind, package, measured = registry_id(item.id), identifier(item.kind), identifier(item.package), sha(item.digest)
        if not id or (kind ~= "db.sql.sqlite" and kind ~= "db.sql.postgres" and kind ~= "db.sql.mysql")
            or not package or not measured
            or type(item.planned) ~= "boolean" or seen_databases[id] or id <= previous_database then
            return nil, "migration work contains an invalid database binding"
        end
        local definition: Object? = nil
        if item.planned then
            definition = object(item.definition)
            if not definition or definition.id ~= id or definition.kind ~= kind then
                return nil, "planned migration database definition differs"
            end
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
        databases[#databases + 1] = {id = id, kind = kind, package = package, digest = measured,
            planned = item.planned :: boolean, definition = definition}
        seen_databases[id], previous_database = true, id
    end
    local required_databases: {[string]: boolean} = {}
    for _, migration in ipairs(migrations) do required_databases[migration.target_db] = true end
    for id in pairs(required_databases) do
        if not seen_databases[id] then return nil, "migration work is missing database " .. id end
    end
    for id in pairs(seen_databases) do
        if not required_databases[id] then return nil, "migration work contains an unused database " .. id end
    end
    return {schema_revision = M.SCHEMA, destination_node = destination, source_node = source,
        base_revision = math.floor(revision :: number), base_digest = base_digest, policy_digest = policy_digest,
        candidate_digest = candidate_digest, artifact_digest = artifact_digest, plan_digest = plan_digest,
        migrations = migrations, databases = databases}, nil
end

local function seal(payload: Object): (Work?, string?)
    local normalized, normalize_error = normalize(payload)
    if not normalized then return nil, normalize_error end
    local bytes, encode_error = canonical.encode(normalized, M.MAX_BYTES)
    if not bytes or #bytes > M.MAX_BYTES then return nil, encode_error or "migration work exceeds byte bound" end
    local measured, measure_error = digest(bytes)
    if not measured then return nil, measure_error end
    normalized.bytes, normalized.digest = bytes, measured
    return normalized :: Work, nil
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
    if copied.bytes ~= value.bytes or copied.digest ~= value.digest then return nil, "migration work artifact changed during capture" end
    return copied, nil
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
        if not id or artifact_entries[id] then return nil, "migration work artifact contains duplicate or invalid IDs" end
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
        if not selected or not id or selected_ids[id] then
            return nil, "migration candidate omits or changes an artifact entry"
        end
        if not full or selected.kind ~= full.kind then return nil, "migration candidate omits or changes an artifact entry" end
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
        if not entry or entry.kind ~= "function.lua" or not meta or meta.type ~= "migration"
            or meta.target_db ~= item.target_db or meta.ordinal ~= item.ordinal then
            return nil, "migration candidate differs from its exact artifact definition: " .. item.id
        end
        local measured, measure_error = definition_digest(entry)
        if not measured then return nil, measure_error end
        if measured ~= item.checksum then return nil, "migration checksum differs from its exact artifact definition: " .. item.id end
    end

    local pending: {preflight.Migration} = {}
    for _, key in ipairs(report.pending_migrations) do
        local separator = key:find("\n", 1, true)
        local target_db = separator and key:sub(1, separator - 1) or ""
        local id = separator and key:sub(separator + 1) or ""
        local item = migrations_by_key[target_db .. "\n" .. id]
        if not item then return nil, "preflight migration is outside the exact candidate" end
        pending[#pending + 1] = item
    end
    table.sort(pending, function(left: preflight.Migration, right: preflight.Migration): boolean
        if left.target_db ~= right.target_db then return left.target_db < right.target_db end
        if left.ordinal ~= right.ordinal then return left.ordinal < right.ordinal end
        return left.id < right.id
    end)
    if #pending > M.MAX_MIGRATIONS then return nil, "pending migration work exceeds its bound" end

    local final: {[string]: preflight.Entry} = {}
    local package_set: {[string]: boolean} = {}
    for _, item in ipairs(candidate.artifacts) do package_set[item.component] = true end
    for id, item in pairs(context.entries) do if not package_set[item.package] then final[id] = item end end
    local planned: {[string]: preflight.Entry} = {}
    for _, item in ipairs(candidate.entries) do final[item.id], planned[item.id] = item, item end
    local target_ids: {[string]: boolean} = {}
    for _, item in ipairs(pending) do target_ids[item.target_db] = true end
    local databases: {Database} = {}
    for id in pairs(target_ids) do
        local summary = final[id]
        if not summary or not context.databases[id] or not summary.kind:match("^db%.sql%.") then
            return nil, "migration database is not an admitted final-state SQL resource: " .. id
        end
        local definition: Object? = nil
        local is_planned = planned[id] ~= nil
        if is_planned then
            definition = artifact_entries[id]
            if not definition or definition.kind ~= summary.kind then
                return nil, "planned migration database is missing from the exact artifact: " .. id
            end
            local measured, measure_error = definition_digest(definition)
            if not measured then return nil, measure_error end
            if measured ~= summary.digest then return nil, "planned migration database differs from its artifact: " .. id end
        end
        databases[#databases + 1] = {id = id, kind = summary.kind, package = summary.package,
            digest = summary.digest, planned = is_planned, definition = definition}
    end
    table.sort(databases, function(left: Database, right: Database): boolean return left.id < right.id end)

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
    if type(bytes_raw) ~= "string" or #bytes_raw == 0 or #bytes_raw > M.MAX_BYTES then
        return nil, "migration work bytes exceed bound"
    end
    local recorded = sha(digest_raw)
    if not recorded then return nil, "migration work digest is malformed" end
    local measured, measure_error = digest(bytes_raw)
    if not measured then return nil, measure_error end
    if measured ~= recorded then return nil, "migration work digest does not match bytes" end
    local decoded, decode_error = json.decode(bytes_raw)
    if decode_error then return nil, "migration work bytes are not JSON" end
    local normalized, normalize_error = normalize(decoded)
    if not normalized then return nil, normalize_error end
    local canonical_bytes, encode_error = canonical.encode(normalized, M.MAX_BYTES)
    if not canonical_bytes or canonical_bytes ~= bytes_raw then
        return nil, encode_error or "migration work bytes are not canonical"
    end
    normalized.bytes, normalized.digest = bytes_raw, recorded
    return normalized :: Work, nil
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
    if not supplied_bytes or supplied_bytes ~= bytes then return false, encode_error or "migration work fields differ from its bytes" end
    local expected, capture_error = M.capture(candidate, artifact_raw, context)
    if not expected then return false, capture_error end
    if expected.bytes ~= decoded.bytes or expected.digest ~= decoded.digest then
        return false, "migration work differs from the destination candidate, artifact or context"
    end
    return true, nil
end

return M
