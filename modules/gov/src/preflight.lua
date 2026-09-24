-- MIT. Internal preflight over a host-resolved immutable closure. This helper
-- neither resolves packages nor grants authority or publishes registry changes.
local canonical = require("canonical")
local hash = require("hash")
local json = require("json")
local M = {}
type Entry = {id: string, kind: string, package: string, digest: string, references: {string}, auto_start: boolean,
    grants: {string}, modules: {string}, config_objects: {string}?, config_lists: {string}?,
    config_empty: {string}?}
type Artifact = {component: string, version: string, digest: string, dependencies: {string}, namespaces: {string}}
type Requirement = {id: string, package: string, value: string?, expected_kind: string?, targets: {string}}
type Migration = {id: string, target_db: string, checksum: string, ordinal: integer}
type DatabaseBinding = {database_id: string, table_prefix: string?}
type DatabaseEvidence = {database_id: string, table_prefix: string?, kind: string, package: string, digest: string}
type Candidate = {destination_node: string, source_node: string, base_revision: integer, base_digest: string,
    artifacts: {Artifact}, entries: {Entry}, requirements: {Requirement}, migrations: {Migration}}
type Context = {node_id: string, registry_revision: integer, registry_digest: string, policy_digest: string,
    packages: {[string]: boolean}, namespaces: {[string]: boolean}, kinds: {[string]: boolean}, databases: {[string]: boolean},
    grants: {[string]: boolean}, modules: {[string]: boolean},
    database_bindings: {[string]: DatabaseBinding}?,
    entries: {[string]: Entry}, installed_entries: {[string]: Entry}?, applied: {[string]: Migration}, applied_databases: {[string]: DatabaseEvidence}?, exact_expansion: boolean,
    migration_barrier: boolean, auto_start: boolean}
type Diagnostic = {code: string, target: string, message: string, remedy: string}
type Report = {schema_revision: string, plan_digest: string, destination_node: string,
    base_revision: integer, policy_digest: string, ready: boolean, diagnostics: {Diagnostic}, pending_migrations: {string}}
local function digest(value: string): boolean
    return #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end
local function identifier(value: string): boolean
    return #value > 0 and #value <= 160 and not value:find("%c")
end
-- The runtime unpacks these kinds into a typed config. A field it reads as a
-- list refuses an object at apply, a field it reads as a nested config refuses
-- a list, and an empty declared field crosses into the destination as neither,
-- so review answers for all three here.
local CONFIG_LISTS: {[string]: {[string]: boolean}} = {
    ["function.lua"] = {modules = true},
    ["library.lua"] = {modules = true},
    ["process.lua"] = {modules = true},
    ["workflow.lua"] = {modules = true},
}
local CONFIG_OBJECTS: {[string]: {[string]: boolean}} = {
    ["function.lua"] = {imports = true, security = true, pool = true},
    ["library.lua"] = {imports = true},
    ["process.lua"] = {imports = true, security = true},
    ["workflow.lua"] = {imports = true},
}
-- Exported so the authoring guide and its test derive the destination's
-- configuration-shape rule from the tables that enforce it, not from memory.
M.CONFIG_LISTS = CONFIG_LISTS
M.CONFIG_OBJECTS = CONFIG_OBJECTS
local function migration_key(item: Migration): string
    return item.target_db .. "\n" .. item.id
end
local function normalize_report(raw: unknown): (Report?, string?)
    if type(raw) ~= "table" then return nil, "preflight report must be an object" end
    local value = raw :: {[string]: unknown}
    local allowed: {[string]: boolean} = {schema_revision = true, plan_digest = true, destination_node = true,
        base_revision = true, policy_digest = true, ready = true, diagnostics = true, pending_migrations = true}
    for name in pairs(value) do if type(name) ~= "string" or not allowed[name] then return nil, "preflight report has an unknown field" end end
    if value.schema_revision ~= "bee.governance-preflight@1" or type(value.plan_digest) ~= "string" or not digest(value.plan_digest)
        or not identifier(value.destination_node :: string) or type(value.base_revision) ~= "number"
        or value.base_revision ~= math.floor(value.base_revision :: number) or (value.base_revision :: number) < 0
        or type(value.policy_digest) ~= "string" or not digest(value.policy_digest)
        or type(value.ready) ~= "boolean" or type(value.diagnostics) ~= "table" or type(value.pending_migrations) ~= "table" then
        return nil, "preflight report is malformed"
    end
    local diagnostics: {Diagnostic} = {}
    local diagnostic_count = 0
    for key in pairs(value.diagnostics :: table) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then return nil, "preflight diagnostics must be a dense list" end
        diagnostic_count = diagnostic_count + 1
    end
    if diagnostic_count > 128 then return nil, "preflight diagnostics exceed bound" end
    for index = 1, diagnostic_count do
        local raw_diagnostic = (value.diagnostics :: table)[index]
        if type(raw_diagnostic) ~= "table" then return nil, "preflight diagnostic is malformed" end
        local item = raw_diagnostic :: {[string]: unknown}
        for name in pairs(item) do if name ~= "code" and name ~= "target" and name ~= "message" and name ~= "remedy" then return nil, "preflight diagnostic has an unknown field" end end
        if type(item.code) ~= "string" or not identifier(item.code) or type(item.target) ~= "string" or #item.target > 512
            or type(item.message) ~= "string" or #item.message > 2048 or type(item.remedy) ~= "string" or #item.remedy > 2048 then
            return nil, "preflight diagnostic is malformed"
        end
        diagnostics[index] = {code = item.code, target = item.target, message = item.message, remedy = item.remedy}
    end
    if value.ready ~= (diagnostic_count == 0) then return nil, "preflight readiness does not match diagnostics" end
    local pending: {string} = {}
    local pending_count = 0
    for key in pairs(value.pending_migrations :: table) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then return nil, "pending migrations must be a dense list" end
        pending_count = pending_count + 1
    end
    if pending_count > 128 then return nil, "pending migrations exceed bound" end
    local prior = ""
    for index = 1, pending_count do
        local item = (value.pending_migrations :: table)[index]
        if type(item) ~= "string" or #item == 0 or #item > 400 or item <= prior then return nil, "pending migrations are malformed" end
        pending[index], prior = item, item
    end
    return {schema_revision = "bee.governance-preflight@1", plan_digest = value.plan_digest :: string,
        destination_node = value.destination_node :: string, base_revision = math.floor(value.base_revision :: number),
        policy_digest = value.policy_digest :: string, ready = value.ready :: boolean,
        diagnostics = diagnostics, pending_migrations = pending}, nil
end

function M.encode_report(raw: unknown): (string?, string?, string?)
    local report, report_error = normalize_report(raw)
    if not report then return nil, nil, report_error end
    local bytes, encode_error = canonical.encode(report, 131072)
    if not bytes or #bytes > 131072 then return nil, nil, encode_error or "preflight report exceeds bound" end
    local measured, measure_error = hash.sha256(bytes)
    if not measured then return nil, nil, tostring(measure_error) end
    return bytes, measured, nil
end

function M.decode_report(bytes_raw: unknown, digest_raw: unknown): (Report?, string?)
    if type(bytes_raw) ~= "string" or #bytes_raw == 0 or #bytes_raw > 131072 then return nil, "preflight report bytes exceed bound" end
    if type(digest_raw) ~= "string" or not digest(digest_raw) then return nil, "preflight report digest is malformed" end
    local bytes: string = bytes_raw :: string
    local measured, measure_error = hash.sha256(bytes)
    if not measured or measure_error or measured ~= digest_raw then return nil, "preflight report digest does not match bytes" end
    local decoded, decode_error = json.decode(bytes)
    if decode_error then return nil, "preflight report bytes are not JSON" end
    local report, report_error = normalize_report(decoded)
    if not report then return nil, report_error end
    local canonical_bytes, encode_error = canonical.encode(report, 131072)
    if not canonical_bytes or canonical_bytes ~= bytes then return nil, encode_error or "preflight report bytes are not canonical" end
    return report, nil
end
local CANDIDATE_LIMIT = 1048576
local function dense_count(raw: unknown, label: string, maximum: integer): (integer?, string?)
    if type(raw) ~= "table" then return nil, label .. " must be a list" end
    local count = 0
    for key in pairs(raw :: table) do
        if type(key) ~= "number" or key ~= math.floor(key :: number) or (key :: number) < 1 then return nil, label .. " must be a dense list" end
        count = count + 1
    end
    if count > maximum then return nil, label .. " exceeds its bound" end
    for index = 1, count do
        if (raw :: table)[index] == nil then return nil, label .. " must be a dense list" end
    end
    return count, nil
end
local function identifiers(raw: unknown, label: string, maximum: integer): ({string}?, string?)
    local count, count_error = dense_count(raw, label, maximum)
    if not count then return nil, count_error end
    local result: {string} = {}
    for index = 1, count do
        local value = (raw :: table)[index]
        if type(value) ~= "string" or not identifier(value :: string) then return nil, label .. " has a malformed value" end
        result[index] = value :: string
    end
    return result, nil
end
local function only(value: {[string]: unknown}, allowed: {[string]: boolean}, label: string): string?
    for name in pairs(value) do
        if type(name) ~= "string" or not allowed[name] then return label .. " has an unknown field" end
    end
    return nil
end
local function candidate_artifacts(raw: unknown): ({Artifact}?, string?)
    local count, count_error = dense_count(raw, "candidate artifacts", 32)
    if not count then return nil, count_error end
    local allowed: {[string]: boolean} = {component = true, version = true, digest = true,
        dependencies = true, namespaces = true}
    local result: {Artifact} = {}
    for index = 1, count do
        local row = (raw :: table)[index]
        if type(row) ~= "table" then return nil, "candidate artifact is malformed" end
        local item = row :: {[string]: unknown}
        local extra = only(item, allowed, "candidate artifact")
        if extra then return nil, extra end
        local dependencies, dependencies_error = identifiers(item.dependencies, "artifact dependencies", 32)
        if not dependencies then return nil, dependencies_error end
        local namespaces, namespaces_error = identifiers(item.namespaces, "artifact namespaces", 64)
        if not namespaces then return nil, namespaces_error end
        if #namespaces == 0 then return nil, "candidate artifact declares no namespace" end
        if type(item.component) ~= "string" or not identifier(item.component :: string)
            or type(item.version) ~= "string" or not identifier(item.version :: string)
            or type(item.digest) ~= "string" or not digest(item.digest :: string) then
            return nil, "candidate artifact is malformed"
        end
        result[index] = {component = item.component :: string, version = item.version :: string,
            digest = item.digest :: string, dependencies = dependencies, namespaces = namespaces}
    end
    if #result < 1 then return nil, "candidate declares no artifact" end
    return result, nil
end
local function candidate_entries(raw: unknown): ({Entry}?, string?)
    local count, count_error = dense_count(raw, "candidate entries", 512)
    if not count then return nil, count_error end
    local allowed: {[string]: boolean} = {id = true, kind = true, package = true, digest = true,
        references = true, auto_start = true, grants = true, modules = true,
        config_objects = true, config_lists = true, config_empty = true}
    local result: {Entry} = {}
    for index = 1, count do
        local row = (raw :: table)[index]
        if type(row) ~= "table" then return nil, "candidate entry is malformed" end
        local item = row :: {[string]: unknown}
        local extra = only(item, allowed, "candidate entry")
        if extra then return nil, extra end
        local references, references_error = identifiers(item.references, "entry references", 64)
        if not references then return nil, references_error end
        local grants, grants_error = identifiers(item.grants, "entry grants", 32)
        if not grants then return nil, grants_error end
        local modules, modules_error = identifiers(item.modules, "entry modules", 32)
        if not modules then return nil, modules_error end
        local config_objects, objects_error = identifiers(item.config_objects, "entry config objects", 32)
        if not config_objects then return nil, objects_error end
        local config_lists, lists_error = identifiers(item.config_lists, "entry config lists", 32)
        if not config_lists then return nil, lists_error end
        local config_empty, empty_error = identifiers(item.config_empty, "entry config empty fields", 32)
        if not config_empty then return nil, empty_error end
        if type(item.id) ~= "string" or not identifier(item.id :: string)
            or type(item.kind) ~= "string" or not identifier(item.kind :: string)
            or type(item.package) ~= "string" or not identifier(item.package :: string)
            or type(item.digest) ~= "string" or not digest(item.digest :: string)
            or type(item.auto_start) ~= "boolean" then
            return nil, "candidate entry is malformed"
        end
        result[index] = {id = item.id :: string, kind = item.kind :: string, package = item.package :: string,
            digest = item.digest :: string, references = references, auto_start = item.auto_start :: boolean,
            grants = grants, modules = modules, config_objects = config_objects, config_lists = config_lists,
            config_empty = config_empty}
    end
    return result, nil
end
local function candidate_requirements(raw: unknown): ({Requirement}?, string?)
    local count, count_error = dense_count(raw, "candidate requirements", 128)
    if not count then return nil, count_error end
    local allowed: {[string]: boolean} = {id = true, package = true, value = true,
        expected_kind = true, targets = true}
    local result: {Requirement} = {}
    for index = 1, count do
        local row = (raw :: table)[index]
        if type(row) ~= "table" then return nil, "candidate requirement is malformed" end
        local item = row :: {[string]: unknown}
        local extra = only(item, allowed, "candidate requirement")
        if extra then return nil, extra end
        local targets, targets_error = identifiers(item.targets, "requirement targets", 64)
        if not targets then return nil, targets_error end
        if type(item.id) ~= "string" or not identifier(item.id :: string)
            or type(item.package) ~= "string" or not identifier(item.package :: string)
            or (item.value ~= nil and (type(item.value) ~= "string" or not identifier(item.value :: string)))
            or (item.expected_kind ~= nil and (type(item.expected_kind) ~= "string" or not identifier(item.expected_kind :: string))) then
            return nil, "candidate requirement is malformed"
        end
        local requirement: Requirement = {id = item.id :: string, package = item.package :: string,
            value = item.value :: string?, expected_kind = item.expected_kind :: string?, targets = targets}
        result[index] = requirement
    end
    return result, nil
end
local function candidate_migrations(raw: unknown): ({Migration}?, string?)
    local count, count_error = dense_count(raw, "candidate migrations", 128)
    if not count then return nil, count_error end
    local allowed: {[string]: boolean} = {id = true, target_db = true, checksum = true, ordinal = true}
    local result: {Migration} = {}
    for index = 1, count do
        local row = (raw :: table)[index]
        if type(row) ~= "table" then return nil, "candidate migration is malformed" end
        local item = row :: {[string]: unknown}
        local extra = only(item, allowed, "candidate migration")
        if extra then return nil, extra end
        if type(item.id) ~= "string" or not identifier(item.id :: string)
            or type(item.target_db) ~= "string" or not identifier(item.target_db :: string)
            or type(item.checksum) ~= "string" or not digest(item.checksum :: string)
            or type(item.ordinal) ~= "number" or item.ordinal ~= math.floor(item.ordinal :: number)
            or (item.ordinal :: number) < 1 then
            return nil, "candidate migration is malformed"
        end
        result[index] = {id = item.id :: string, target_db = item.target_db :: string,
            checksum = item.checksum :: string, ordinal = math.floor(item.ordinal :: number)}
    end
    return result, nil
end
local function normalize_candidate(raw: unknown): (Candidate?, string?)
    if type(raw) ~= "table" then return nil, "candidate must be an object" end
    local value = raw :: {[string]: unknown}
    local allowed: {[string]: boolean} = {destination_node = true, source_node = true, base_revision = true,
        base_digest = true, artifacts = true, entries = true, requirements = true, migrations = true}
    local extra = only(value, allowed, "candidate")
    if extra then return nil, extra end
    if type(value.destination_node) ~= "string" or not identifier(value.destination_node :: string)
        or type(value.source_node) ~= "string" or not identifier(value.source_node :: string)
        or type(value.base_revision) ~= "number" or value.base_revision ~= math.floor(value.base_revision :: number)
        or (value.base_revision :: number) < 0
        or type(value.base_digest) ~= "string" or not digest(value.base_digest :: string) then
        return nil, "candidate identity is malformed"
    end
    local artifacts, artifacts_error = candidate_artifacts(value.artifacts)
    if not artifacts then return nil, artifacts_error end
    local entries, entries_error = candidate_entries(value.entries)
    if not entries then return nil, entries_error end
    local requirements, requirements_error = candidate_requirements(value.requirements)
    if not requirements then return nil, requirements_error end
    local migrations, migrations_error = candidate_migrations(value.migrations)
    if not migrations then return nil, migrations_error end
    return {destination_node = value.destination_node :: string, source_node = value.source_node :: string,
        base_revision = math.floor(value.base_revision :: number), base_digest = value.base_digest :: string,
        artifacts = artifacts, entries = entries, requirements = requirements, migrations = migrations}, nil
end

-- The stored candidate is review evidence, never authority: this decoder
-- answers for the exact bytes a plan was measured over and refuses anything
-- that does not re-encode to them.
function M.decode_candidate(bytes_raw: unknown, digest_raw: unknown): (Candidate?, string?)
    if type(bytes_raw) ~= "string" or #bytes_raw == 0 or #bytes_raw > CANDIDATE_LIMIT then return nil, "candidate bytes exceed bound" end
    if type(digest_raw) ~= "string" or not digest(digest_raw :: string) then return nil, "candidate digest is malformed" end
    local bytes: string = bytes_raw :: string
    local measured, measure_error = hash.sha256(bytes)
    if not measured or measure_error or measured ~= digest_raw then return nil, "candidate digest does not match bytes" end
    local decoded, decode_error = json.decode(bytes)
    if decode_error then return nil, "candidate bytes are not JSON" end
    local candidate, candidate_error = normalize_candidate(decoded)
    if not candidate then return nil, candidate_error end
    local canonical_bytes, encode_error = canonical.encode(candidate, CANDIDATE_LIMIT)
    if not canonical_bytes or canonical_bytes ~= bytes then return nil, encode_error or "candidate bytes are not canonical" end
    return candidate, nil
end
-- Context is supplied by an authorized destination adapter, never decoded from
-- a remote plan as authority. Every suggested remedy requires a NEW candidate.
function M.check(candidate: Candidate, context: Context): (Report?, string?)
    if #candidate.artifacts == 0 or #candidate.artifacts > 32 or #candidate.entries > 512
        or #candidate.requirements > 128 or #candidate.migrations > 128 then return nil, "candidate exceeds preflight bounds" end
    if not identifier(candidate.destination_node) or not identifier(candidate.source_node)
        or candidate.base_revision < 0 or candidate.base_revision > 9007199254740991
        or not digest(candidate.base_digest) or not digest(context.registry_digest)
        or not digest(context.policy_digest) then return nil, "invalid candidate or host measurement" end
    local encoded, encode_error = canonical.encode(candidate, 262144)
    if not encoded or #encoded > 262144 then return nil, encode_error or "candidate exceeds encoded bound" end
    local diagnostics: {Diagnostic} = {}
    local function issue(code: string, target: string, message: string, remedy: string)
        if #diagnostics < 128 then diagnostics[#diagnostics + 1] = {code = code, target = target, message = message, remedy = remedy} end
    end
    if candidate.destination_node ~= context.node_id then issue("WRONG_DESTINATION", candidate.destination_node, "plan is for another owner", "replan at the destination") end
    if candidate.base_revision ~= context.registry_revision then issue("STALE_BASE", tostring(candidate.base_revision), "registry changed since resolution", "resolve again and request new approval") end
    if candidate.base_digest ~= context.registry_digest then issue("STALE_BASE", "composed-registry", "registry content or overlays changed since resolution", "resolve again against the current composed registry") end
    if not context.exact_expansion then issue("RUNTIME_GATE", "resolution", "runtime has not measured the exact publishable closure", "resolve through a verified expansion adapter") end
    local artifacts: {[string]: Artifact} = {}
    local namespace_owners: {[string]: string} = {}
    for _, item in ipairs(candidate.artifacts) do
        if not identifier(item.component) or not identifier(item.version) or not digest(item.digest)
            or #item.dependencies > 32 or #item.namespaces == 0 or #item.namespaces > 64 then return nil, "invalid artifact measurement" end
        if artifacts[item.component] then issue("DUPLICATE_PACKAGE", item.component, "closure contains competing package selections", "resolve all incoming constraints together") end
        if not context.packages[item.component] then issue("PACKAGE_DENIED", item.component, "package is outside host policy", "request an explicit host policy change") end
        artifacts[item.component] = item
        for _, namespace in ipairs(item.namespaces) do
            if not identifier(namespace) or namespace:find(":", 1, true) then return nil, "invalid owned namespace" end
            if namespace_owners[namespace] then issue("NAMESPACE_COLLISION", namespace, "namespace has duplicate ownership declarations", "declare each namespace under exactly one package") end
            namespace_owners[namespace] = item.component
            if not context.namespaces[namespace] then issue("NAMESPACE_DENIED", namespace, "declared namespace is outside host policy", "request explicit admission for this namespace") end
        end
    end
    for id, item in pairs(context.entries) do
        local namespace = id:match("^([^:]+):[^:]+$")
        local owner = namespace and namespace_owners[namespace] or nil
        if owner and owner ~= item.package then issue("NAMESPACE_COLLISION", id, "existing namespace belongs to another package", "choose a namespace not owned by another package") end
    end
    for _, item in ipairs(candidate.artifacts) do
        for _, dependency in ipairs(item.dependencies) do
            if not artifacts[dependency] then issue("UNRESOLVED_DEPENDENCY", dependency, "dependency is missing from measured closure", "resolve the full transitive graph") end
        end
    end
    local final: {[string]: Entry} = {}
    for id, item in pairs(context.entries) do final[id] = item end
    -- The selected private overlay is deliberately absent from `entries`: it
    -- cannot be part of the external-base approval digest or applying the
    -- approved overlay would invalidate its own evidence. It is still part of
    -- the installed state this complete-set update replaces, so retain it for
    -- final-state reference validation only.
    local installed: {[string]: Entry} = context.installed_entries or {}
    for id, item in pairs(installed) do final[id] = item end
    -- Updates replace the complete owned set; removed definitions do not remain
    -- available merely because they existed in the pre-update registry.
    for id, item in pairs(final) do if artifacts[item.package] then final[id] = nil end end
    local seen: {[string]: boolean} = {}
    for _, item in ipairs(candidate.entries) do
        if not identifier(item.id) or not identifier(item.kind) or not digest(item.digest) or #item.references > 64
            or #item.grants > 32 or #item.modules > 32 then return nil, "invalid entry measurement" end
        if seen[item.id] then issue("DUPLICATE_ENTRY", item.id, "candidate defines an entry twice", "remove the conflicting definition") end
        seen[item.id] = true
        local namespace = item.id:match("^([^:]+):[^:]+$")
        if not namespace or not context.namespaces[namespace] then issue("NAMESPACE_DENIED", item.id, "entry namespace is outside host policy", "choose an explicitly admitted namespace") end
        if namespace and namespace_owners[namespace] ~= item.package then issue("NAMESPACE_OWNER", item.id, "entry namespace is not declared by its package", "include the exact child namespace in the package ownership manifest") end
        if not artifacts[item.package] then issue("UNKNOWN_OWNER", item.id, "entry is not owned by the measured package closure", "repair the ownership manifest") end
        if not context.kinds[item.kind] then issue("KIND_DENIED", item.id, "entry kind is outside host policy", "remove the entry or request host policy review") end
        for _, grant in ipairs(item.grants) do
            if not context.grants[grant] then issue("GRANT_DENIED", item.id, "unadmitted security policy " .. grant, "remove the grant or request host policy review") end
        end
        for _, module in ipairs(item.modules) do
            if not context.modules[module] then issue("MODULE_DENIED", item.id, "unadmitted runtime module " .. module, "remove the module or request host policy review") end
        end
        local config_objects, config_lists = item.config_objects, item.config_lists
        local config_empty = item.config_empty
        if config_objects == nil or config_lists == nil or config_empty == nil then return nil, "invalid entry measurement" end
        local wants_list = CONFIG_LISTS[item.kind]
        local wants_object = CONFIG_OBJECTS[item.kind]
        if wants_list then
            for _, field in ipairs(config_objects) do
                if wants_list[field] then
                    issue("CONFIG_SHAPE", item.id, "configuration field " .. field .. " reaches the destination as an object, not a list",
                        "declare " .. field .. " with its values, or omit it")
                end
            end
        end
        if wants_object then
            for _, field in ipairs(config_lists) do
                if wants_object[field] then
                    issue("CONFIG_SHAPE", item.id, "configuration field " .. field .. " reaches the destination as a list, not an object",
                        "declare " .. field .. " as named values, or omit it")
                end
            end
        end
        if wants_list or wants_object then
            for _, field in ipairs(config_empty) do
                if (wants_list and wants_list[field]) or (wants_object and wants_object[field]) then
                    issue("CONFIG_SHAPE", item.id, "configuration field " .. field .. " is empty and reaches the destination as neither shape",
                        "omit " .. field)
                end
            end
        end
        local existing = context.entries[item.id]
        if existing and (existing.package ~= item.package or existing.kind ~= item.kind) then
            issue("ENTRY_COLLISION", item.id, "entry ownership or kind would change", "choose a nonconflicting destination")
        end
        if item.auto_start and not context.auto_start then
            issue("AUTO_START_DENIED", item.id, "entry starts itself outside the application lifecycle and host policy admits no auto start",
                "remove lifecycle.auto_start; the application starts its work when it is opened")
        end
        if item.auto_start and #candidate.migrations > 0 and not context.migration_barrier then
            issue("MIGRATION_BARRIER_REQUIRED", item.id, "service can activate before its schema is ready", "declare a supported post-migration activation barrier")
        end
        final[item.id] = item
    end
    -- A destination composes part of its own registry out of band, so the base
    -- carries references whose targets the host supplies or withholds. This
    -- plan answers for the references it defines and for base references whose
    -- targets it removes; a target already absent before the plan is the
    -- destination's standing state and is diagnosed where it is owned.
    for id, item in pairs(final) do
        for _, reference in ipairs(item.references) do
            if not final[reference] and (seen[id] or context.entries[reference] ~= nil
                or installed[reference] ~= nil) then
                issue("DANGLING_REFERENCE", id, "missing final-state target " .. reference, "repair the reference or include its target")
            end
        end
    end
    local requirements: {[string]: boolean} = {}
    for _, item in ipairs(candidate.requirements) do
        if not identifier(item.id) or #item.targets > 64 then return nil, "invalid requirement" end
        if requirements[item.id] then issue("DUPLICATE_REQUIREMENT", item.id, "ambiguous requirement identity", "resolve by full requirement identity") end
        requirements[item.id] = true
        if not artifacts[item.package] then issue("UNKNOWN_OWNER", item.id, "requirement is outside measured closure", "repair requirement ownership") end
        local target = item.value and final[item.value] or nil
        if not target then issue("MISSING_BINDING", item.id, "requirement has no existing final-state target", "select an explicit destination resource; do not guess from the name")
        elseif item.expected_kind and target.kind ~= item.expected_kind then issue("BINDING_KIND", item.id, "resource does not match declared kind", "select a resource of the declared kind") end
        for _, reference in ipairs(item.targets) do
            if not final[reference] then issue("DANGLING_REQUIREMENT_TARGET", item.id, "missing target entry " .. reference, "repair the package requirement target") end
        end
    end
    local migrations: {[string]: Migration} = {}
    local ordinals: {[string]: boolean} = {}
    local pending: {Migration} = {}
    for _, item in ipairs(candidate.migrations) do
        if not identifier(item.id) or not identifier(item.target_db) or not digest(item.checksum) or item.ordinal < 1 then return nil, "invalid migration measurement" end
        local key = migration_key(item)
        local ordinal = item.target_db .. "\n" .. tostring(item.ordinal)
        if migrations[key] or ordinals[ordinal] then issue("MIGRATION_COLLISION", item.id, "duplicate migration identity or order", "append a uniquely ordered migration") end
        migrations[key], ordinals[ordinal] = item, true
        if not context.databases[item.target_db] then issue("DATABASE_DENIED", item.id, "migration database is outside host policy", "select a host-authorized database") end
        local binding = context.database_bindings and context.database_bindings[item.target_db] or nil
        if context.database_bindings ~= nil and not binding then
            issue("MISSING_DATABASE_BINDING", item.id, "migration target has no host database binding", "select an explicit host database binding")
        end
        local database_id = binding and binding.database_id or item.target_db
        local database = final[database_id]
        local existing_database = context.entries[database_id]
        if not database or not database.kind:match("^db%.sql%.") then
            issue("MISSING_DATABASE", item.id, "migration target is not bound to a final-state SQL resource", "bind an existing SQL resource")
        elseif not existing_database or existing_database.kind ~= database.kind
            or existing_database.package ~= database.package or existing_database.digest ~= database.digest then
            issue("DATABASE_REPLACEMENT", item.id, "migration binding does not retain the host database definition", "bind an unchanged host SQL resource")
        end
        local historical = context.applied_databases and context.applied_databases[item.target_db] or nil
        if historical and (historical.database_id ~= database_id
            or historical.table_prefix ~= (binding and binding.table_prefix or nil)
            or not database or historical.kind ~= database.kind or historical.package ~= database.package
            or historical.digest ~= database.digest) then
            issue("APPLIED_DATABASE_CHANGED", item.id, "applied migration database binding or definition changed",
                "retain the original database binding or use an explicit relocation operation")
        end
        local previous = context.applied[key]
        if previous then
            if previous.checksum ~= item.checksum or previous.ordinal ~= item.ordinal then issue("APPLIED_MIGRATION_CHANGED", item.id, "applied migration body or order changed", "restore the applied migration and append a new one") end
        else pending[#pending + 1] = item end
    end
    for key, item in pairs(context.applied) do
        -- Adapter supplies the applied ledgers belonging to this candidate's
        -- updated packages, not unrelated packages' migration history.
        if not migrations[key] then issue("APPLIED_MIGRATION_REMOVED", item.id, "candidate omits an applied migration", "retain applied migration history") end
    end
    table.sort(pending, function(a: Migration, b: Migration): boolean
        if a.target_db ~= b.target_db then return a.target_db < b.target_db end
        if a.ordinal ~= b.ordinal then return a.ordinal < b.ordinal end
        return a.id < b.id
    end)
    table.sort(diagnostics, function(a: Diagnostic, b: Diagnostic): boolean
        if a.code ~= b.code then return a.code < b.code end
        if a.target ~= b.target then return a.target < b.target end
        return a.message < b.message
    end)
    local measurement = canonical.encode({candidate = candidate, policy_digest = context.policy_digest,
        applied = context.applied, applied_databases = context.applied_databases or {}}, 262144)
    if not measurement then return nil, "cannot measure plan" end
    local measured, measure_error = hash.sha256(measurement)
    if not measured then return nil, tostring(measure_error) end
    local pending_ids: {string} = {}
    for _, item in ipairs(pending) do pending_ids[#pending_ids + 1] = migration_key(item) end
    return {schema_revision = "bee.governance-preflight@1", plan_digest = measured, destination_node = context.node_id,
        base_revision = candidate.base_revision, policy_digest = context.policy_digest, ready = #diagnostics == 0,
        diagnostics = diagnostics, pending_migrations = pending_ids}, nil
end
return M
