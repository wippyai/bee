-- MIT. Internal preflight over a host-resolved immutable closure. This helper
-- neither resolves packages nor grants authority or publishes registry changes.
local canonical = require("canonical")
local hash = require("hash")
local M = {}
type Entry = {id: string, kind: string, package: string, digest: string, references: {string}, auto_start: boolean,
    grants: {string}, modules: {string}}
type Artifact = {component: string, version: string, digest: string, dependencies: {string}, namespaces: {string}}
type Requirement = {id: string, package: string, value: string?, expected_kind: string?, targets: {string}}
type Migration = {id: string, target_db: string, checksum: string, ordinal: integer}
type Candidate = {destination_node: string, source_node: string, base_revision: integer, base_digest: string,
    artifacts: {Artifact}, entries: {Entry}, requirements: {Requirement}, migrations: {Migration}}
type Context = {node_id: string, registry_revision: integer, registry_digest: string, policy_digest: string,
    packages: {[string]: boolean}, namespaces: {[string]: boolean}, kinds: {[string]: boolean}, databases: {[string]: boolean},
    grants: {[string]: boolean}, modules: {[string]: boolean},
    entries: {[string]: Entry}, applied: {[string]: Migration}, guarded_publication: boolean,
    exact_expansion: boolean, migration_barrier: boolean}
type Diagnostic = {code: string, target: string, message: string, remedy: string}
type Report = {schema_revision: string, plan_digest: string, destination_node: string,
    base_revision: integer, policy_digest: string, ready: boolean, diagnostics: {Diagnostic}, pending_migrations: {string}}
local function digest(value: string): boolean
    return #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end
local function identifier(value: string): boolean
    return #value > 0 and #value <= 160 and not value:find("%c")
end
local function migration_key(item: Migration): string
    return item.target_db .. "\n" .. item.id
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
    local encoded, encode_error = canonical.encode(candidate)
    if not encoded or #encoded > 262144 then return nil, encode_error or "candidate exceeds encoded bound" end
    local diagnostics: {Diagnostic} = {}
    local function issue(code: string, target: string, message: string, remedy: string)
        if #diagnostics < 128 then diagnostics[#diagnostics + 1] = {code = code, target = target, message = message, remedy = remedy} end
    end
    if candidate.destination_node ~= context.node_id then issue("WRONG_DESTINATION", candidate.destination_node, "plan is for another owner", "replan at the destination") end
    if candidate.base_revision ~= context.registry_revision then issue("STALE_BASE", tostring(candidate.base_revision), "registry changed since resolution", "resolve again and request new approval") end
    if candidate.base_digest ~= context.registry_digest then issue("STALE_BASE", "composed-registry", "registry content or overlays changed since resolution", "resolve again against the current composed registry") end
    if not context.guarded_publication then issue("RUNTIME_GATE", "publication", "runtime lacks atomic expected-base publication", "install a verified runtime capability") end
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
        local existing = context.entries[item.id]
        if existing and (existing.package ~= item.package or existing.kind ~= item.kind) then
            issue("ENTRY_COLLISION", item.id, "entry ownership or kind would change", "choose a nonconflicting destination")
        end
        if item.auto_start and #candidate.migrations > 0 and not context.migration_barrier then
            issue("MIGRATION_BARRIER_REQUIRED", item.id, "service can activate before its schema is ready", "declare a supported post-migration activation barrier")
        end
        final[item.id] = item
    end
    for id, item in pairs(final) do
        for _, reference in ipairs(item.references) do
            if not final[reference] then issue("DANGLING_REFERENCE", id, "missing final-state target " .. reference, "repair the reference or include its target") end
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
        local database = final[item.target_db]
        if not database or not database.kind:match("^db%.sql%.") then issue("MISSING_DATABASE", item.id, "migration target is not a final-state SQL resource", "bind an existing SQL resource") end
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
    local measurement = canonical.encode({candidate = candidate, policy_digest = context.policy_digest, applied = context.applied})
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
