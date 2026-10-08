-- MIT. Destination-local Hub resolution through the runtime registry planner.
-- Hub artifacts and remote plans are evidence. The destination host supplies
-- the root mapping, policy ceiling and migration ledger used by preflight.
local registry = require("registry")
local artifact = require("artifact")
local canonical = require("canonical")
local hash = require("hash")
local bounds = require("bounds")
local application_admission = require("application_admission")
local protected_kernel = require("protected_kernel")
local preflight = require("preflight")
local lists = require("lists")
local resolution = require("resolution")
local requirement = require("requirement")
local capability_model = require("capability_model")
local application_capabilities = require("application_capabilities")
local hub_package = require("hub_package")
local graph = require("graph")

local M = {}
type Object = {[string]: unknown}
type Entry = {[string]: unknown}
type RegistryChange = {entry: Entry, op: string}
type RegistryPlan = {digest: string, changes: {RegistryChange}, resolution: Object?, retained: {[string]: boolean}?}
type ResolvedModule = {name: string, version: string, digest: string}
type Captured = {revision: integer, entries: {Entry}, resolution: Object?,
    overlay_ids: {[string]: boolean}?, preview: (Entry) -> (RegistryPlan?, string?)}
type Root = {component: string, version: string, parameters: {unknown}}
type DatabaseBinding = {database_id: string, table_prefix: string?}
type DatabaseBindings = {[string]: DatabaseBinding}
type Policy = application_capabilities.Policy
type Deps = {capture: () -> (Captured?, string?), root: (unknown) -> (Root?, string?),
    policy: (unknown, unknown, unknown) -> (Policy?, string?), folder: (() -> (unknown?, string?))?}
type Resolver = resolution.Resolver
type Instance = {capture: () -> (Captured?, string?), root: (unknown) -> (Root?, string?),
    policy: (unknown, unknown, unknown) -> (Policy?, string?),
    resolve: (Resolver, unknown) -> (preflight.Candidate?, preflight.Context?, string?)}

local function object(value: unknown): Object?
    return bounds.object(value)
end

local function sha(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end

local function module_sha(value: unknown): string?
    if type(value) == "string" and value:sub(1, 7) == "sha256:" then value = value:sub(8) end
    return sha(value)
end

local function copy_entry(raw: unknown): (Entry?, string?)
    local value = object(raw)
    local id = value and bounds.id(value.id) or nil
    local kind = value and bounds.id(value.kind) or nil
    if not value or not id or not kind then return nil, "registry state contains an invalid entry" end
    -- Copy retained definitions and ownership for bounded capture measurement.
    local result: Entry = {}
    for field, item in pairs(value) do result[field] = item end
    return result, nil
end

local function owner(entry: Entry): string?
    local metadata = object(entry.registry)
    return metadata and bounds.text(metadata.owner, 160) or nil
end

local function apply_preview(base: {Entry}, preview: RegistryPlan): ({Entry}?, string?)
    local by_id: {[string]: Entry} = {}
    for _, raw in ipairs(base) do
        local entry, entry_error = copy_entry(raw)
        if not entry then return nil, entry_error end
        local id = entry.id
        if by_id[id] then return nil, "registry state contains duplicate entry " .. id end
        by_id[id] = entry
    end
    local operations, operations_error = bounds.dense_list(preview.changes, 4096, "registry preview changes")
    if not operations then return nil, operations_error end
    for _, raw in ipairs(operations) do
        local operation = object(raw)
        local kind = operation and (operation.op or operation.kind) or nil
        local entry: Entry? = nil
        local entry_error: string? = nil
        if operation then entry, entry_error = copy_entry(operation.entry) end
        if not entry then return nil, entry_error or "registry preview contains an invalid operation" end
        local id = entry.id
        if kind == "delete" or kind == "entry.delete" then
            by_id[id] = nil
        elseif kind == "create" or kind == "update" or kind == "entry.create" or kind == "entry.update" then
            by_id[id] = entry
        else
            return nil, "registry preview contains an unknown operation"
        end
    end
    local result: {Entry} = {}
    for _, entry in pairs(by_id) do result[#result + 1] = entry end
    table.sort(result, function(left: Entry, right: Entry): boolean
        return (left.id) < (right.id)
    end)
    return result, nil
end

local function resolution_modules(raw: unknown): ({[string]: ResolvedModule}?, string?)
    local resolution = object(raw)
    local rows, rows_error = bounds.dense_list(resolution and resolution.modules, 256, "registry resolution modules")
    if not rows then return nil, rows_error end
    local result: {[string]: ResolvedModule} = {}
    for _, raw_module in ipairs(rows) do
        local item = object(raw_module)
        local name = item and bounds.text(item.name, 160) or nil
        local version = item and bounds.text(item.version, 128) or nil
        local digest = item and module_sha(item.digest) or nil
        if not item or not name or not version or not digest or result[name] then return nil, "registry resolution module is invalid" end
        result[name] = {name = name, version = version, digest = digest}
    end
    return result, nil
end

local function dependency_edges(entries: {Entry}): ({[string]: {[string]: boolean}}, string?)
    local result: {[string]: {[string]: boolean}} = {}
    for _, entry in ipairs(entries) do
        local package = owner(entry)
        if not package then return {}, "registry preview entry has no registry-owned module" end
        local registry_meta = object(entry.registry)
        if entry.kind == "ns.dependency" and entry.dependency_root ~= true
            and (not registry_meta or registry_meta.root ~= true) then
            local data = object(entry.data)
            local dependency = data and bounds.text(data.component, 160) or nil
            if not dependency then return {}, "dependency entry has no component" end
            local edges = result[package]
            if not edges then edges = {}; result[package] = edges end
            edges[dependency] = true
        end
    end
    return result, nil
end

local function closure(root: string, edges: {[string]: {[string]: boolean}}, modules: {[string]: ResolvedModule}): ({[string]: boolean}?, string?)
    local selected: {[string]: boolean} = {}
    local queue: {string} = {root}
    local index = 1
    while index <= #queue do
        local component = queue[index]
        index = index + 1
        if not selected[component] then
            if not modules[component] then return nil, "runtime resolution omitted " .. component end
            selected[component] = true
            local count = 0
            for dependency in pairs(edges[component] or {}) do
                count = count + 1
                if count > 64 or #queue >= 256 then return nil, "dependency closure exceeds its bound" end
                queue[#queue + 1] = dependency
            end
        end
    end
    return selected, nil
end


local function measured_entry(entry: Entry, package: string): (preflight.Entry?, string?)
    local clean: Entry = {}
    for field, value in pairs(entry) do if field ~= "registry" then clean[field] = value end end
    local id, kind = bounds.id(clean.id), bounds.id(clean.kind)
    if not id or not kind then return nil, "resolved entry identity is invalid" end
    local encoded, encode_error = canonical.encode(clean, artifact.MAX_BYTES)
    if not encoded then return nil, "encode resolved entry: " .. tostring(encode_error or "unknown error") end
    local digest, digest_error = hash.sha256(encoded)
    if not digest then return nil, tostring(digest_error or "measure resolved entry") end
    local refs, references_error = requirement.references(clean)
    if not refs then return nil, id .. ": " .. tostring(references_error) end
    local modules, modules_error = lists.strings(clean.modules, "entry modules", 32)
    if not modules then return nil, modules_error end
    local config_objects, config_lists, config_empty, shapes_error = artifact.config_shapes(clean)
    if not config_objects or not config_lists or not config_empty then return nil, tostring(shapes_error or "measure entry configuration shapes") end
    local security = object(clean.security)
    local grants, grants_error = lists.strings(security and security.policies or nil, "entry policies", 32)
    if not grants then return nil, grants_error end
    local lifecycle = object(clean.lifecycle)
    return {id = id, kind = kind, package = package, digest = digest,
        references = refs, auto_start = lifecycle ~= nil and lifecycle.auto_start == true,
        application_checkpoint_invalid = artifact.application_checkpoint_invalid(clean),
        application_unplaced = artifact.application_unplaced(clean),
        grants = grants, modules = modules, config_objects = config_objects, config_lists = config_lists,
        config_empty = config_empty}, nil
end

local function migration(entry: Entry): (preflight.Migration?, string?)
    local meta = object(entry.meta)
    local target = meta and bounds.id(meta.target_db) or nil
    local id = bounds.id(entry.id)
    if not target or not id then
        return nil, "migration has no target database or identity: " .. tostring(entry.id)
    end
    local ordinal = meta and bounds.count(meta.ordinal) or nil
    if ordinal == nil or ordinal < 1 then
        return nil, "migration has no target database or append-only ordinal: " .. tostring(entry.id)
    end
    local clean: Entry = {}
    for field, value in pairs(entry) do if field ~= "registry" then clean[field] = value end end
    local encoded, encode_error = canonical.encode(clean, artifact.MAX_BYTES)
    if not encoded then return nil, tostring(encode_error or "encode migration") end
    local checksum, checksum_error = hash.sha256(encoded)
    if not checksum then return nil, tostring(checksum_error or "measure migration") end
    return {id = id, target_db = target, checksum = checksum, ordinal = ordinal}, nil
end

local function policy_context(policy: Policy, captured: Captured, base_digest: string,
    current: {[string]: preflight.Entry}, protected: protected_kernel.Manifest,
    evidence: preflight.HostEvidence): (preflight.Context?, string?)
    if not bounds.id(policy.node_id) or not sha(policy.policy_digest) then return nil, "host policy identity is invalid" end
    for _, field in ipairs({"packages", "namespaces", "kinds", "databases", "grants", "modules", "applied"}) do
        if type((policy)[field]) ~= "table" then return nil, "host policy is missing " .. field end
    end
    local bindings: DatabaseBindings? = nil
    if policy.database_bindings ~= nil then
        if type(policy.database_bindings) ~= "table" then return nil, "host policy database bindings are malformed" end
        bindings = {}
        for target, raw in pairs(policy.database_bindings) do
            local item = object(raw)
            local database_id = item and bounds.id(item.database_id) or nil
            local prefix: string? = nil
            if item and item.table_prefix ~= nil then
                prefix = bounds.text(item.table_prefix, 64)
                if not prefix or not prefix:match("^[A-Za-z][A-Za-z0-9_]*$") then
                    return nil, "host policy database binding prefix is invalid"
                end
            end
            if not bounds.id(target) or not item or bounds.fields(item, {"database_id", "table_prefix"})
                or not database_id then return nil, "host policy database binding is malformed" end
            bindings[target] = {database_id = database_id, table_prefix = prefix}
        end
    end
    local generated: {[string]: string} = {}
    for _, raw in ipairs(policy.generated_databases or {}) do
        local id, target = bounds.id(raw.database_id), bounds.id(raw.target_db)
        if not id or not target then return nil, "host generated database is invalid" end
        generated[id] = target
    end
    local context: preflight.Context = {node_id = policy.node_id, registry_revision = captured.revision, registry_digest = base_digest,
        policy_digest = policy.policy_digest, packages = policy.packages, namespaces = policy.namespaces,
        kinds = policy.kinds, databases = policy.databases, grants = policy.grants, modules = policy.modules,
        database_bindings = bindings, generated_databases = generated, entries = current, applied = policy.applied,
        applied_databases = policy.applied_databases or {}, exact_expansion = true,
        migration_barrier = policy.migration_barrier == true, auto_start = policy.auto_start == true,
        protected = protected, host_evidence = evidence}
    return context, nil
end

function M.resolve_with(deps: Deps, spec_raw: unknown): (preflight.Candidate?, preflight.Context?, string?)
    local spec = object(spec_raw)
    local destination = spec and bounds.id(spec.owner_node) or nil
    local source = spec and bounds.id(spec.source_node) or nil
    if not spec or not destination or not source then return nil, nil, "selected plan identity is invalid" end
    local expected, artifact_error = artifact.decode(spec.artifact_bytes, spec.artifact_digest)
    if not expected then return nil, nil, artifact_error end
    local captured, capture_error = deps.capture()
    if not captured then return nil, nil, capture_error end
    if captured.revision < 0 then return nil, nil, "captured registry state is invalid" end
    local root, root_error = deps.root(spec)
    local component = root and bounds.text(root.component, 160) or nil
    local selected_version = root and bounds.text(root.version, 128) or nil
    if not root or not component or not selected_version then return nil, nil, root_error or "Hub root is invalid" end
    local root_digest, root_digest_error = hash.sha256(component)
    if not root_digest then return nil, nil, tostring(root_digest_error or "measure Hub root") end
    local dependency: Object = {component = component, version = selected_version}
    -- The registry transcoder cannot infer an array from an empty Lua table.
    -- Omit empty parameters; the native dependency decoder treats absence as
    -- the same empty list. Non-empty parameter rows remain an array.
    if next(root.parameters) ~= nil then dependency.parameters = root.parameters end
    local root_entry: Entry = {id = "bee.gov.deps:" .. root_digest, kind = "ns.dependency", dependency_root = true,
        data = dependency}
    local preview, preview_error = captured.preview(root_entry)
    if not preview then return nil, nil, preview_error or "preview Hub dependency" end
    if not sha(preview.digest) or not preview.resolution then return nil, nil, "registry preview is incomplete" end
    local final, final_error = apply_preview(captured.entries, preview)
    if not final then return nil, nil, final_error end
    local modules, modules_error = resolution_modules(preview.resolution)
    if not modules then return nil, nil, modules_error end
    local edges, edges_error = dependency_edges(final)
    if not edges then return nil, nil, edges_error end
    local selected, closure_error = closure(component, edges, modules)
    if not selected then return nil, nil, closure_error end
    for package in pairs(preview.retained or {}) do selected[package] = nil end

    local catalog: capability_model.Vocabulary? = nil
    for _, entry in ipairs(captured.entries) do
        if entry.id == "bee.capability:catalog" then
            local decoded, catalog_error = capability_model.decode(entry)
            if not decoded then return nil, nil, catalog_error end
            catalog = decoded
        end
    end
    local flattened: {Entry} = {}
    local package_entries: {[string]: {Entry}} = {}
    local final_by_id: {[string]: Entry} = {}
    for _, entry in ipairs(final) do
        local package = owner(entry)
        if not package then return nil, nil, "registry preview entry has no registry-owned module" end
        final_by_id[entry.id] = entry
        if selected[package] and entry.kind ~= "ns.dependency" then
            local clean: Entry = {}
            for field, value in pairs(entry) do if field ~= "registry" then clean[field] = value end end
            flattened[#flattened + 1] = clean
            local bucket: {Entry} = package_entries[package] or {}
            package_entries[package] = bucket
            bucket[#bucket + 1] = entry
        end
    end
    local exact = artifact.create(flattened)
    if not exact then return nil, nil, "resolved Hub closure is empty or invalid" end
    if exact.bytes ~= spec.artifact_bytes or exact.digest ~= spec.artifact_digest then
        return nil, nil, "reviewed artifact does not match the destination Hub expansion"
    end
    local artifacts: {preflight.Artifact} = {}
    local candidate_entries: {preflight.Entry} = {}
    local requirements: {preflight.Requirement} = {}
    local migrations: {preflight.Migration} = {}
    local owned_namespaces: {[string]: boolean} = {}
    local names: {string} = {}
    for package in pairs(selected) do names[#names + 1] = package end
    table.sort(names)
    for _, package in ipairs(names) do
        local module = modules[package]
        local namespaces: {string} = {}
        local namespace_set: {[string]: boolean} = {}
        local entries: {Entry} = package_entries[package] or {}
        local owned: {[string]: boolean} = {}
        for _, entry in ipairs(entries) do owned[entry.id] = true end
        for _, raw_entry in ipairs(entries) do
            local entry, entry_error = copy_entry(raw_entry)
            if not entry then return nil, nil, entry_error end
            local namespace = assert(bounds.id(entry.id)):match("^([^:]+):")
            if namespace and not namespace_set[namespace] then
                namespace_set[namespace], owned_namespaces[namespace] = true, true
                namespaces[#namespaces + 1] = namespace
            end
            local measured, measured_error = measured_entry(entry, package)
            if not measured then return nil, nil, measured_error end
            candidate_entries[#candidate_entries + 1] = measured
            if entry.kind == "ns.requirement" then
                local item, item_error = requirement.resolve(entry, package, final_by_id, owned, catalog)
                if not item then return nil, nil, item_error end
                requirements[#requirements + 1] = item
            end
            local meta = object(entry.meta)
            if meta and meta.type == "migration" then
                local item, item_error = migration(entry)
                if not item then return nil, nil, item_error end
                migrations[#migrations + 1] = item
            end
        end
        table.sort(namespaces)
        local dependencies: {string} = {}
        for dependency in pairs(edges[package] or {}) do if selected[dependency] then dependencies[#dependencies + 1] = dependency end end
        table.sort(dependencies)
        local module_digest = module_sha(module.digest)
        if not module_digest then return nil, nil, "resolved module has no immutable digest: " .. package end
        artifacts[#artifacts + 1] = {component = package, version = module.version, digest = module_digest,
            dependencies = dependencies, namespaces = namespaces}
    end
    table.sort(candidate_entries, function(left: preflight.Entry, right: preflight.Entry): boolean return left.id < right.id end)
    table.sort(requirements, function(left: preflight.Requirement, right: preflight.Requirement): boolean return left.id < right.id end)
    table.sort(migrations, function(left: preflight.Migration, right: preflight.Migration): boolean
        if left.target_db ~= right.target_db then return left.target_db < right.target_db end
        if left.ordinal ~= right.ordinal then return left.ordinal < right.ordinal end
        return left.id < right.id
    end)

    local current: {[string]: preflight.Entry} = {}
    for _, entry in ipairs(captured.entries) do
        if not (captured.overlay_ids and captured.overlay_ids[entry.id]) then
            local package = owner(entry)
            if package == nil then return nil, nil, "captured registry entry has no registry-owned module" end
            local measured, measured_error = measured_entry(entry, package)
            if not measured then return nil, nil, measured_error end
            current[entry.id] = measured
        end
    end

    local policy, policy_error = deps.policy(spec, captured, preview)
    if not policy then return nil, nil, policy_error or "read destination Hub policy" end
    if policy.node_id ~= destination then return nil, nil, "host policy belongs to another destination" end

    if policy.workspace_application and spec.source_workspace == "hub:" .. component then
        policy.namespaces = owned_namespaces
        policy.packages = selected
    end
    local current_raw: {[string]: Entry} = {}
    for _, entry in ipairs(captured.entries) do current_raw[entry.id] = entry end
    local prepared, capability_error = application_capabilities.prepare(policy, spec, flattened,
        requirements, current_raw, deps.folder)
    if not prepared then return nil, nil, capability_error end
    policy = prepared.policy
    -- Measure only the existing definitions that can affect this closure:
    -- owned namespaces, external references, and requirement targets. This
    -- excludes unrelated boot-local registry state while retaining every
    -- collision and binding input used by preflight.
    local relevant_ids: {[string]: boolean} = {}
    local kernel_raw: unknown = nil
    for _, entry in ipairs(captured.entries) do
        if entry.id == protected_kernel.ID then kernel_raw = entry end
    end
    local kernel, kernel_error = protected_kernel.decode(kernel_raw)
    if not kernel then return nil, nil, kernel_error end
    relevant_ids[protected_kernel.ID] = true
    for _, item in ipairs(candidate_entries) do
        for _, reference in ipairs(item.references) do relevant_ids[reference] = true end
    end
    for _, item in ipairs(requirements) do
        for _, target in ipairs(item.targets) do relevant_ids[target] = true end
        if item.capability_request then relevant_ids["bee.capability:catalog"] = true end
    end
    if policy.database_bindings ~= nil then
        if type(policy.database_bindings) ~= "table" then return nil, nil, "host policy database bindings are malformed" end
        for _, raw in pairs(policy.database_bindings) do
            local item = object(raw)
            local database_id = item and bounds.id(item.database_id) or nil
            if database_id then relevant_ids[database_id] = true end
        end
    end
    local relevant: {preflight.Entry} = {}
    for id, raw in pairs(current) do
        local namespace = id:match("^([^:]+):")
        if relevant_ids[id] or (namespace and owned_namespaces[namespace]) then relevant[#relevant + 1] = raw end
    end
    table.sort(relevant, function(left: preflight.Entry, right: preflight.Entry): boolean return left.id < right.id end)
    local base_bytes, base_error = canonical.encode({entries = relevant}, 1048576)
    if not base_bytes then return nil, nil, "measure relevant registry base: " .. tostring(base_error or "unknown error") end
    local base_digest, base_measure_error = hash.sha256(base_bytes)
    if not base_digest then return nil, nil, tostring(base_measure_error or "measure relevant registry base") end

    local evidence: preflight.HostEvidence = {application_admission = {kind = "absent"}, capability = application_capabilities.evidence(prepared)}
    if policy.applications then
        if policy.workspace_id ~= spec.workspace_id or policy.source_node ~= source
            or policy.source_workspace ~= spec.source_workspace or not bounds.id(policy.overlay_owner) then
            return nil, nil, "application admission policy does not match the selected activation profile"
        end
        local projection, projection_error = application_admission.project({identity_generation = "current", workspace_id = policy.workspace_id,
            overlay_owner = policy.overlay_owner, source_node = policy.source_node,
            source_workspace = policy.source_workspace, artifact_digest = spec.artifact_digest,
            bindings = policy.applications, artifact_entries = expected,
            registry_entries = captured.entries, overlay_ids = captured.overlay_ids,
            generated_policies = prepared.proposal and prepared.proposal.policies or nil})
        if not projection then return nil, nil, projection_error or "application admission projection is absent" end
        evidence.application_admission = {kind = "measured", value = projection}
    end
    local context, context_error = policy_context(policy, captured, base_digest, current, kernel, evidence)
    if not context then return nil, nil, context_error end
    context.module_capabilities = prepared.module_capabilities
    return {destination_node = destination, source_node = source, base_revision = captured.revision,
        base_digest = base_digest, artifacts = artifacts, entries = candidate_entries,
        requirements = requirements, migrations = migrations}, context, nil
end

type Config = {overlay_owner: string?, root: (unknown) -> (Root?, string?), policy: (unknown, unknown, unknown) -> (Policy?, string?), folder: (() -> (unknown?, string?))?}

function M.new(config: Config): Resolver
    local function capture(): (Captured?, string?)
        local snapshot, snapshot_error = registry.snapshot()
        if not snapshot then return nil, tostring(snapshot_error or "capture registry snapshot") end
        local state, state_error = snapshot:state()
        if not state then return nil, tostring(state_error or "read registry snapshot state") end
        local version = snapshot:version()
        local revision = version and version:id() or nil
        if type(revision) ~= "number" then return nil, "registry snapshot has no revision" end
        local overlay_ids: {[string]: boolean}? = nil
        if config.overlay_owner then
            local overlay, overlay_error = registry.overlay(config.overlay_owner)
            if not overlay then return nil, tostring(overlay_error or "open destination overlay") end
            local rows, rows_error = overlay:entries()
            if not rows then return nil, tostring(rows_error or "read destination overlay") end
            overlay_ids = {}
            for _, raw in ipairs(rows) do
                local entry = object(raw)
                local id = entry and bounds.id(entry.id) or nil
                if not id then return nil, "destination overlay contains an invalid entry" end
                overlay_ids[id] = true
            end
        end
        local captured: Captured = {revision = math.floor(revision), entries = state.entries,
            resolution = state.resolution, overlay_ids = overlay_ids, preview = function(root_entry: Entry): (RegistryPlan?, string?)
                local root, root_error = graph.edge(root_entry.data)
                if not root then return nil, root_error end
                local expanded, expand_error = hub_package.expand(state, math.floor(revision), root)
                if not expanded then return nil, expand_error end
                return {digest = expanded.digest, changes = expanded.changes,
                    resolution = expanded.resolution, retained = expanded.retained}, nil
            end}
        return captured, nil
    end
    local value: Instance
    value = {capture = capture, root = config.root, policy = config.policy, folder = config.folder,
        resolve = function(_: Resolver, spec: unknown): (preflight.Candidate?, preflight.Context?, string?)
            return M.resolve_with(value, spec)
        end}
    return value
end

return M
