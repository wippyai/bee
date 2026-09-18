-- MIT. Destination-local Hub resolution through the runtime registry planner.
-- Hub artifacts and remote plans are evidence. The destination host supplies
-- the root mapping, policy ceiling and migration ledger used by preflight.
local registry = require("registry")
local artifact = require("artifact")
local canonical = require("canonical")
local hash = require("hash")
local bounds = require("bounds")

local M = {}
type Object = {[string]: unknown}
type Entry = {[string]: unknown}
type Captured = {revision: integer, entries: {Entry}, resolution: Object?,
    overlay_ids: {[string]: boolean}?, preview: (Entry) -> (Object?, string?)}
type Root = {component: string, version: string, parameters: {unknown}}
type Policy = {node_id: string, policy_digest: string, packages: {[string]: boolean},
    namespaces: {[string]: boolean}, kinds: {[string]: boolean}, databases: {[string]: boolean},
    grants: {[string]: boolean}, modules: {[string]: boolean}, applied: {[string]: unknown},
    migration_barrier: boolean}
type Deps = {capture: () -> (Captured?, string?), root: (unknown) -> (Root?, string?),
    policy: (unknown, Captured, Object) -> (Policy?, string?)}

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

local function dense(value: unknown, label: string, maximum: integer): ({unknown}?, string?)
    if type(value) ~= "table" then return nil, label .. " must be a list" end
    local source = value :: table
    local count = 0
    for key in pairs(source) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, label .. " must be a dense list" end
        count = count + 1
    end
    if count > maximum then return nil, label .. " exceeds its bound" end
    local result: {unknown} = {}
    for index = 1, count do
        if source[index] == nil then return nil, label .. " must be a dense list" end
        result[index] = source[index]
    end
    return result, nil
end

local function copy_entry(raw: unknown): (Entry?, string?)
    local value = object(raw)
    local id = value and bounds.id(value.id) or nil
    local kind = value and bounds.id(value.kind) or nil
    if not value or not id or not kind then return nil, "registry state contains an invalid entry" end
    -- The resolver never mutates a retained entry. Copy its author-facing
    -- fields and ownership; the composed-state measurement below supplies the
    -- bounded canonical check for the whole capture.
    local result: Entry = {}
    for field, item in pairs(value) do result[field] = item end
    return result, nil
end

local function owner(entry: Entry): string?
    local metadata = object(entry.registry)
    return metadata and bounds.text(metadata.owner, 160) or nil
end

local function apply_preview(base: {Entry}, preview: Object): ({Entry}?, string?)
    local by_id: {[string]: Entry} = {}
    for _, raw in ipairs(base) do
        local entry, entry_error = copy_entry(raw)
        if not entry then return nil, entry_error end
        local id = entry.id :: string
        if by_id[id] then return nil, "registry state contains duplicate entry " .. id end
        by_id[id] = entry
    end
    local operations, operations_error = dense(preview.changes, "registry preview changes", 4096)
    if not operations then return nil, operations_error end
    for _, raw in ipairs(operations) do
        local operation = object(raw)
        local kind = operation and operation.kind or nil
        local entry: Entry? = nil
        local entry_error: string? = nil
        if operation then entry, entry_error = copy_entry(operation.entry) end
        if not entry then return nil, entry_error or "registry preview contains an invalid operation" end
        local id = entry.id :: string
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
        return (left.id :: string) < (right.id :: string)
    end)
    return result, nil
end

local function resolution_modules(raw: unknown): ({[string]: Object}?, string?)
    local resolution = object(raw)
    local rows, rows_error = dense(resolution and resolution.modules, "registry resolution modules", 256)
    if not rows then return nil, rows_error end
    local result: {[string]: Object} = {}
    for _, raw_module in ipairs(rows) do
        local item = object(raw_module)
        local name = item and bounds.text(item.name, 160) or nil
        local version = item and bounds.text(item.version, 128) or nil
        if not item or not name or not version or result[name] then return nil, "registry resolution module is invalid" end
        result[name] = item
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

local function closure(root: string, edges: {[string]: {[string]: boolean}}, modules: {[string]: Object}): ({[string]: boolean}?, string?)
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

local function list_strings(raw: unknown, label: string, maximum: integer): ({string}?, string?)
    if raw == nil then return {}, nil end
    local rows, rows_error = dense(raw, label, maximum)
    if not rows then return nil, rows_error end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, value in ipairs(rows) do
        local item = bounds.id(value)
        if not item or seen[item] then return nil, label .. " contains an invalid or duplicate value" end
        seen[item], result[#result + 1] = true, item
    end
    table.sort(result)
    return result, nil
end

local function references(entry: Entry): ({string}?, string?)
    local found: {[string]: boolean} = {}
    -- These are the registry dependency fields understood by the runtime's
    -- component handlers. Values still have to be full registry IDs; plain
    -- labels, actions and package coordinates are ignored.
    local scalar: {[string]: boolean} = {parent = true, config = true, fs = true, func = true,
        env = true, set = true, store = true, storage = true, bucket = true, host = true,
        process = true, driver = true, queue = true, client = true, server = true,
        router = true, network = true, token_store = true, contract = true}
    local collection: {[string]: boolean} = {depends_on = true, requires = true, groups = true,
        imports = true, middleware = true, post_middleware = true, policies = true, methods = true}
    local function add(raw: unknown)
        if type(raw) ~= "string" then return end
        local reference = bounds.id(raw)
        if reference and reference:match("^[A-Za-z0-9][A-Za-z0-9_.-]*:[A-Za-z0-9][A-Za-z0-9_.-]*$") then
            found[reference] = true
        end
    end
    local function add_all(value: unknown, depth: integer): string?
        if depth > 12 then return "entry reference structure nests too deeply" end
        if type(value) ~= "table" then add(value); return nil end
        for key, child in pairs(value :: table) do
            if type(key) ~= "string" and type(key) ~= "number" then return "entry reference structure is not encodable" end
            local problem = add_all(child, depth + 1)
            if problem then return problem end
        end
        return nil
    end
    local function scan(value: unknown, depth: integer, key: string?): string?
        if depth > 12 then return "entry reference structure nests too deeply" end
        if type(value) ~= "table" then
            if key and (scalar[key] or key:match("_ref$") or key:match("_env$")) then add(value) end
            return nil
        end
        for child_key, child in pairs(value :: table) do
            if type(child_key) == "string" then
                local problem: string? = nil
                if collection[child_key] then problem = add_all(child, depth + 1)
                else problem = scan(child, depth + 1, child_key) end
                if problem then return problem end
            elseif type(child_key) == "number" then
                local problem = scan(child, depth + 1, key)
                if problem then return problem end
            else return "entry reference structure is not encodable" end
        end
        return nil
    end
    local problem = scan(entry, 0, nil)
    if problem then return nil, problem end
    local result: {string} = {}
    for reference in pairs(found) do result[#result + 1] = reference end
    table.sort(result)
    if #result > 64 then return nil, "entry references exceed their bound" end
    return result, nil
end

local function measured_entry(entry: Entry, package: string): (unknown?, string?)
    local clean: Entry = {}
    for field, value in pairs(entry) do if field ~= "registry" then clean[field] = value end end
    local encoded, encode_error = canonical.encode(clean, artifact.MAX_BYTES)
    if not encoded then return nil, "encode resolved entry: " .. tostring(encode_error or "unknown error") end
    local digest, digest_error = hash.sha256(encoded)
    if not digest then return nil, tostring(digest_error or "measure resolved entry") end
    local refs, references_error = references(clean)
    if not refs then return nil, references_error end
    local modules, modules_error = list_strings(clean.modules, "entry modules", 32)
    if not modules then return nil, modules_error end
    local config_objects, config_lists, shapes_error = artifact.config_shapes(clean)
    if not config_objects or not config_lists then return nil, tostring(shapes_error or "measure entry configuration shapes") end
    local security = object(clean.security)
    local grants, grants_error = list_strings(security and security.policies or nil, "entry policies", 32)
    if not grants then return nil, grants_error end
    local lifecycle = object(clean.lifecycle)
    return {id = clean.id, kind = clean.kind, package = package, digest = digest,
        references = refs, auto_start = lifecycle ~= nil and lifecycle.auto_start == true,
        grants = grants, modules = modules, config_objects = config_objects, config_lists = config_lists}, nil
end

local function path_value(entry: Entry, path: unknown): (unknown?, string?)
    if type(path) ~= "string" or not path:match("^%.[A-Za-z_][A-Za-z0-9_%.]*$") then
        return nil, "requirement target path is invalid"
    end
    local value: unknown = entry
    for name in path:gmatch("[A-Za-z_][A-Za-z0-9_]*") do
        local parent = object(value)
        if not parent then return nil, "requirement target path does not resolve" end
        value = parent[name]
    end
    return value, nil
end

local function requirement(entry: Entry, package: string, final: {[string]: Entry}): (unknown?, string?)
    local data = object(entry.data) or entry
    local targets, targets_error = dense(data.targets, "requirement targets", 64)
    if not targets then return nil, targets_error end
    local result_targets: {string} = {}
    local selected: string? = nil
    for _, raw in ipairs(targets) do
        local target = object(raw)
        local target_entry = target and bounds.id(target.entry) or nil
        if not target_entry then return nil, "requirement target is invalid" end
        result_targets[#result_targets + 1] = target_entry
        local destination = object(final[target_entry])
        if not destination then return nil, "requirement target entry is absent: " .. target_entry end
        local bound, bound_error = path_value(destination :: Entry, target.path)
        local value = bounds.id(bound)
        if not value then return nil, bound_error or "requirement target has no selected binding" end
        if selected and selected ~= value then return nil, "requirement targets disagree on the selected binding" end
        selected = value
    end
    table.sort(result_targets)
    local meta = object(entry.meta)
    local expected: string? = meta and bounds.id(meta.value_kind) or nil
    return {id = entry.id, package = package, value = selected,
        expected_kind = expected, targets = result_targets}, nil
end

local function migration(entry: Entry): (unknown?, string?)
    local meta = object(entry.meta)
    local target = meta and bounds.id(meta.target_db) or nil
    local ordinal = meta and bounds.count(meta.ordinal) or nil
    if not target or not ordinal or ordinal < 1 then
        return nil, "migration has no target database or append-only ordinal: " .. tostring(entry.id)
    end
    local clean: Entry = {}
    for field, value in pairs(entry) do if field ~= "registry" then clean[field] = value end end
    local encoded, encode_error = canonical.encode(clean, artifact.MAX_BYTES)
    if not encoded then return nil, tostring(encode_error or "encode migration") end
    local checksum, checksum_error = hash.sha256(encoded)
    if not checksum then return nil, tostring(checksum_error or "measure migration") end
    return {id = entry.id, target_db = target, checksum = checksum, ordinal = ordinal}, nil
end

local function policy_context(policy: Policy, captured: Captured, base_digest: string,
    current: {[string]: unknown}): (unknown?, string?)
    if not bounds.id(policy.node_id) or not sha(policy.policy_digest) then return nil, "host policy identity is invalid" end
    for _, field in ipairs({"packages", "namespaces", "kinds", "databases", "grants", "modules", "applied"}) do
        if type((policy :: Object)[field]) ~= "table" then return nil, "host policy is missing " .. field end
    end
    return {node_id = policy.node_id, registry_revision = captured.revision, registry_digest = base_digest,
        policy_digest = policy.policy_digest, packages = policy.packages, namespaces = policy.namespaces,
        kinds = policy.kinds, databases = policy.databases, grants = policy.grants, modules = policy.modules,
        entries = current, applied = policy.applied, exact_expansion = true,
        migration_barrier = policy.migration_barrier == true}, nil
end

function M.resolve_with(deps_raw: unknown, spec_raw: unknown): (unknown?, unknown?, string?)
    if type(deps_raw) ~= "table" then return nil, nil, "Hub resolver dependencies are invalid" end
    local deps = deps_raw :: Deps
    if type(deps.capture) ~= "function" or type(deps.root) ~= "function"
        or type(deps.policy) ~= "function" then return nil, nil, "Hub resolver dependencies are invalid" end
    local spec = object(spec_raw)
    local destination = spec and bounds.id(spec.owner_node) or nil
    local source = spec and bounds.id(spec.source_node) or nil
    if not spec or not destination or not source then return nil, nil, "selected plan identity is invalid" end
    local expected, artifact_error = artifact.decode(spec.artifact_bytes, spec.artifact_digest)
    if not expected then return nil, nil, artifact_error end
    local captured, capture_error = deps.capture()
    if not captured then return nil, nil, capture_error end
    if type(captured.revision) ~= "number" or captured.revision < 0 or captured.revision ~= math.floor(captured.revision)
        or type(captured.entries) ~= "table" or type(captured.preview) ~= "function" then
        return nil, nil, "captured registry state is invalid"
    end
    local root, root_error = deps.root(spec)
    local component = root and bounds.text(root.component, 160) or nil
    local selected_version = root and bounds.text(root.version, 128) or nil
    if not root or not component or not selected_version
        or type(root.parameters) ~= "table" then return nil, nil, root_error or "Hub root is invalid" end
    local root_digest, root_digest_error = hash.sha256(component)
    if not root_digest then return nil, nil, tostring(root_digest_error or "measure Hub root") end
    local dependency: Object = {component = component, version = selected_version}
    -- The registry transcoder cannot infer an array from an empty Lua table.
    -- Omit empty parameters; the native dependency decoder treats absence as
    -- the same empty list. Non-empty parameter rows remain an array.
    if next(root.parameters) ~= nil then dependency.parameters = root.parameters end
    local root_entry: Entry = {id = "bee.governance.deps:" .. root_digest, kind = "ns.dependency", dependency_root = true,
        data = dependency}
    local preview, preview_error = captured.preview(root_entry)
    if not preview then return nil, nil, preview_error or "preview Hub dependency" end
    if not sha(preview.digest) or type(preview.resolution) ~= "table" then return nil, nil, "registry preview is incomplete" end
    local final, final_error = apply_preview(captured.entries, preview)
    if not final then return nil, nil, final_error end
    local modules, modules_error = resolution_modules(preview.resolution)
    if not modules then return nil, nil, modules_error end
    local edges, edges_error = dependency_edges(final)
    if not edges then return nil, nil, edges_error end
    local selected, closure_error = closure(component, edges, modules)
    if not selected then return nil, nil, closure_error end

    local flattened: {Entry} = {}
    local package_entries: {[string]: {Entry}} = {}
    local final_by_id: {[string]: Entry} = {}
    for _, entry in ipairs(final) do
        local package = owner(entry)
        if not package then return nil, nil, "registry preview entry has no registry-owned module" end
        final_by_id[entry.id :: string] = entry
        if selected[package] and entry.kind ~= "ns.dependency" then
            local clean: Entry = {}
            for field, value in pairs(entry) do if field ~= "registry" then clean[field] = value end end
            flattened[#flattened + 1] = clean
            local bucket = package_entries[package]
            if not bucket then bucket = {}; package_entries[package] = bucket end
            bucket[#bucket + 1] = entry
        end
    end
    local exact = artifact.create(flattened)
    if not exact then return nil, nil, "resolved Hub closure is empty or invalid" end
    if exact.bytes ~= spec.artifact_bytes or exact.digest ~= spec.artifact_digest then
        return nil, nil, "reviewed artifact does not match the destination Hub expansion"
    end
    local artifacts: {unknown} = {}
    local candidate_entries: {unknown} = {}
    local requirements: {unknown} = {}
    local migrations: {unknown} = {}
    local owned_namespaces: {[string]: boolean} = {}
    local names: {string} = {}
    for package in pairs(selected) do names[#names + 1] = package end
    table.sort(names)
    for _, package in ipairs(names) do
        local module = modules[package]
        local namespaces: {string} = {}
        local namespace_set: {[string]: boolean} = {}
        for _, entry in ipairs(package_entries[package] or {}) do
            local namespace = (entry.id :: string):match("^([^:]+):")
            if namespace and not namespace_set[namespace] then
                namespace_set[namespace], owned_namespaces[namespace] = true, true
                namespaces[#namespaces + 1] = namespace
            end
            local measured, measured_error = measured_entry(entry, package)
            if not measured then return nil, nil, measured_error end
            candidate_entries[#candidate_entries + 1] = measured
            if entry.kind == "ns.requirement" then
                local item, item_error = requirement(entry, package, final_by_id)
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
    table.sort(candidate_entries, function(left: any, right: any): boolean return left.id < right.id end)
    table.sort(requirements, function(left: any, right: any): boolean return left.id < right.id end)
    table.sort(migrations, function(left: any, right: any): boolean
        if left.target_db ~= right.target_db then return left.target_db < right.target_db end
        if left.ordinal ~= right.ordinal then return left.ordinal < right.ordinal end
        return left.id < right.id
    end)

    local current: {[string]: unknown} = {}
    for _, entry in ipairs(captured.entries) do
        if not (captured.overlay_ids and captured.overlay_ids[entry.id :: string]) then
            local package = owner(entry)
            if package == nil then return nil, nil, "captured registry entry has no registry-owned module" end
            local measured, measured_error = measured_entry(entry, package)
            if not measured then return nil, nil, measured_error end
            current[entry.id :: string] = measured
        end
    end

    -- Measure only the existing definitions that can affect this closure:
    -- owned namespaces, external references, and requirement targets. This
    -- excludes unrelated boot-local registry state while retaining every
    -- collision and binding input used by preflight.
    local relevant_ids: {[string]: boolean} = {}
    for _, raw in ipairs(candidate_entries) do
        local item = raw :: Object
        for _, reference in ipairs(item.references :: {string}) do relevant_ids[reference] = true end
    end
    for _, raw in ipairs(requirements) do
        local item = raw :: Object
        for _, target in ipairs(item.targets :: {string}) do relevant_ids[target] = true end
    end
    local relevant: {unknown} = {}
    for id, raw in pairs(current) do
        local namespace = id:match("^([^:]+):")
        if relevant_ids[id] or (namespace and owned_namespaces[namespace]) then relevant[#relevant + 1] = raw end
    end
    table.sort(relevant, function(left: any, right: any): boolean return left.id < right.id end)
    local base_bytes, base_error = canonical.encode({entries = relevant}, 1048576)
    if not base_bytes then return nil, nil, "measure relevant registry base: " .. tostring(base_error or "unknown error") end
    local base_digest, base_measure_error = hash.sha256(base_bytes)
    if not base_digest then return nil, nil, tostring(base_measure_error or "measure relevant registry base") end

    local policy, policy_error = deps.policy(spec, captured, preview)
    if not policy then return nil, nil, policy_error or "read destination Hub policy" end
    if policy.node_id ~= destination then return nil, nil, "host policy belongs to another destination" end
    local context, context_error = policy_context(policy, captured, base_digest :: string, current)
    if not context then return nil, nil, context_error end
    return {destination_node = destination, source_node = source, base_revision = captured.revision,
        base_digest = base_digest, artifacts = artifacts, entries = candidate_entries,
        requirements = requirements, migrations = migrations}, context, nil
end

type Config = {overlay_owner: string?, root: (unknown) -> (Root?, string?), policy: (unknown, Captured, Object) -> (Policy?, string?)}

function M.new(config: Config): unknown
    local value = {root = config.root, policy = config.policy}
    function value.capture(): (Captured?, string?)
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
            resolution = state.resolution, overlay_ids = overlay_ids, preview = function(root_entry: Entry): (Object?, string?)
                local changes = snapshot:changes()
                local existing = snapshot:get(root_entry.id :: string)
                local created, create_error
                if existing then created, create_error = changes:update(root_entry)
                else created, create_error = changes:create(root_entry) end
                if not created then return nil, tostring(create_error or "stage Hub dependency root") end
                -- The checked runtime gate supplies preview(); keeping the
                -- native call at this single dynamic seam lets older binaries
                -- load the pure resolver tests without pretending they can
                -- execute production resolution.
                local previewer = changes :: any
                local preview, preview_error = previewer:preview()
                if not preview then return nil, tostring(preview_error or "preview Hub dependency root") end
                return preview :: Object, nil
            end}
        return captured, nil
    end
    function value:resolve(spec: unknown): (unknown?, unknown?, string?)
        return M.resolve_with(self :: Deps, spec)
    end
    return value
end

return M
