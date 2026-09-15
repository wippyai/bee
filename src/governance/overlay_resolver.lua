-- MIT. Destination-local resolution for exact immutable private-overlay
-- artifacts. Sync bytes supply definitions only; the host selects their
-- package identity, overlay owner and capability ceiling.
local registry = require("registry")
local artifact = require("artifact")
local canonical = require("canonical")
local hash = require("hash")
local bounds = require("bounds")

local M = {}
type Object = {[string]: unknown}
type Entry = {[string]: unknown}
type Captured = {revision: integer, entries: {Entry}, overlay_ids: {[string]: boolean}?,
    owner: (Entry) -> (string?, string?)}
type Root = {component: string, version: string}
type Policy = {node_id: string, policy_digest: string, packages: {[string]: boolean},
    namespaces: {[string]: boolean}, kinds: {[string]: boolean}, databases: {[string]: boolean},
    grants: {[string]: boolean}, modules: {[string]: boolean}, applied: {[string]: unknown},
    migration_barrier: boolean}
type Deps = {capture: () -> (Captured?, string?), root: (unknown) -> (Root?, string?),
    policy: (unknown, Captured, Root) -> (Policy?, string?)}

local function object(value: unknown): Object?
    return bounds.object(value)
end

local function sha(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
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

local function measured_entry(entry: Entry, package: string): (Object?, string?)
    local clean: Entry = {}
    -- `registry` is runtime provenance. It is not part of an incoming private
    -- artifact's authority or materialized definition.
    for field, value in pairs(entry) do if field ~= "registry" then clean[field] = value end end
    local encoded, encode_error = canonical.encode(clean, artifact.MAX_BYTES)
    if not encoded then return nil, "encode private overlay entry: " .. tostring(encode_error or "unknown error") end
    local digest, digest_error = hash.sha256(encoded)
    if not digest then return nil, tostring(digest_error or "measure private overlay entry") end
    local refs, refs_error = references(clean)
    if not refs then return nil, refs_error end
    local modules, modules_error = list_strings(clean.modules, "entry modules", 32)
    if not modules then return nil, modules_error end
    local security = object(clean.security)
    local grants, grants_error = list_strings(security and security.policies or nil, "entry policies", 32)
    if not grants then return nil, grants_error end
    local lifecycle = object(clean.lifecycle)
    return {id = clean.id, kind = clean.kind, package = package, digest = digest,
        references = refs, auto_start = lifecycle ~= nil and lifecycle.auto_start == true,
        grants = grants, modules = modules}, nil
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

local function requirement(entry: Entry, package: string, final: {[string]: Entry}): (Object?, string?)
    local data = object(entry.data) or entry
    local targets, targets_error = dense(data.targets, "requirement targets", 64)
    if not targets then return nil, targets_error end
    local result_targets: {string} = {}
    local selected: string? = nil
    for _, raw in ipairs(targets) do
        local target = object(raw)
        local target_id = target and bounds.id(target.entry) or nil
        if not target_id then return nil, "requirement target is invalid" end
        result_targets[#result_targets + 1] = target_id
        local destination = object(final[target_id])
        if not destination then return nil, "requirement target entry is absent: " .. target_id end
        local binding, binding_error = path_value(destination :: Entry, target.path)
        local value = bounds.id(binding)
        if not value then return nil, binding_error or "requirement target has no selected binding" end
        if selected and selected ~= value then return nil, "requirement targets disagree on the selected binding" end
        selected = value
    end
    table.sort(result_targets)
    local meta = object(entry.meta)
    local expected = meta and bounds.id(meta.value_kind) or nil
    return {id = entry.id, package = package, value = selected, expected_kind = expected,
        targets = result_targets}, nil
end

local function policy_context(policy: Policy, captured: Captured, base_digest: string,
    current: {[string]: Object}): (Object?, string?)
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

function M.resolve_with(deps_raw: unknown, spec_raw: unknown): (Object?, Object?, string?)
    if type(deps_raw) ~= "table" then return nil, nil, "private overlay resolver dependencies are invalid" end
    local deps = deps_raw :: Deps
    if type(deps.capture) ~= "function" or type(deps.root) ~= "function"
        or type(deps.policy) ~= "function" then return nil, nil, "private overlay resolver dependencies are invalid" end
    local spec = object(spec_raw)
    local destination = spec and bounds.id(spec.owner_node) or nil
    local source = spec and bounds.id(spec.source_node) or nil
    local source_workspace = spec and bounds.id(spec.source_workspace) or nil
    local version = spec and bounds.id(spec.version) or nil
    if not spec or not destination or not source or not source_workspace or not version then
        return nil, nil, "selected private artifact identity is invalid"
    end
    local expected, artifact_error = artifact.decode(spec.artifact_bytes, spec.artifact_digest)
    if not expected then return nil, nil, artifact_error end
    local captured, capture_error = deps.capture()
    if not captured then return nil, nil, capture_error end
    if type(captured.revision) ~= "number" or captured.revision < 0
        or captured.revision ~= math.floor(captured.revision) or type(captured.entries) ~= "table" then
        return nil, nil, "captured registry state is invalid"
    end
    local root, root_error = deps.root(spec)
    local component = root and bounds.text(root.component, 160) or nil
    if not root or not component or component == "" or root.version ~= version then
        return nil, nil, root_error or "host-selected private application profile is invalid"
    end

    local incoming: {Entry} = {}
    local incoming_by_id: {[string]: Entry} = {}
    local namespace_set: {[string]: boolean} = {}
    local namespace_count = 0
    for _, raw in ipairs(expected) do
        local entry = object(raw)
        local id = entry and bounds.text(entry.id, artifact.MAX_ID_BYTES) or nil
        local kind = entry and bounds.id(entry.kind) or nil
        if not entry or not id or not kind then return nil, nil, "private artifact contains an invalid definition" end
        if entry.registry ~= nil then return nil, nil, "private artifact contains reserved registry metadata" end
        if entry.kind == "ns.dependency" then return nil, nil, "private overlay artifacts cannot introduce Hub dependency directives" end
        local meta = object(entry.meta)
        if meta and meta.type == "migration" then return nil, nil, "private overlay activation currently requires a migration-free artifact" end
        local namespace = id:match("^([^:]+):")
        if not namespace then return nil, nil, "private artifact definition has no namespace" end
        if not namespace_set[namespace] then namespace_set[namespace], namespace_count = true, namespace_count + 1 end
        if incoming_by_id[id] then return nil, nil, "private artifact defines duplicate entry " .. id end
        incoming_by_id[id] = entry
        incoming[#incoming + 1] = entry
    end
    if namespace_count == 0 or namespace_count > 64 then return nil, nil, "private artifact namespace count exceeds its bound" end

    local current: {[string]: Object} = {}
    local current_raw: {[string]: Entry} = {}
    local current_namespace: {[string]: string} = {}
    for _, raw in ipairs(captured.entries) do
        local entry = object(raw)
        local id = entry and bounds.id(entry.id) or nil
        if not entry or not id then return nil, nil, "captured registry contains an invalid entry" end
        if current_raw[id] then return nil, nil, "captured registry contains duplicate entry " .. id end
        current_raw[id] = entry
        if not (captured.overlay_ids and captured.overlay_ids[id]) then
            local package, package_error = captured.owner(entry)
            if not package then return nil, nil, package_error or "captured registry entry has no trusted local owner" end
            local measured, measured_error = measured_entry(entry, package)
            if not measured then return nil, nil, measured_error end
            current[id] = measured
            local namespace = id:match("^([^:]+):")
            if namespace then current_namespace[namespace] = id end
        end
    end
    for id in pairs(incoming_by_id) do
        if current[id] then return nil, nil, "private artifact entry collides with destination definition " .. id end
    end
    for namespace in pairs(namespace_set) do
        local conflict = current_namespace[namespace]
        if conflict then return nil, nil, "private artifact namespace collides with destination definition " .. conflict end
    end

    local names: {string} = {}
    for namespace in pairs(namespace_set) do names[#names + 1] = namespace end
    table.sort(names)
    table.sort(incoming, function(left: Entry, right: Entry): boolean return (left.id :: string) < (right.id :: string) end)
    local candidate_entries: {Object} = {}
    local requirements: {Object} = {}
    local final: {[string]: Entry} = {}
    for id, entry in pairs(current_raw) do
        if not (captured.overlay_ids and captured.overlay_ids[id]) then final[id] = entry end
    end
    for _, entry in ipairs(incoming) do
        -- Incoming registry metadata is neither ownership evidence nor an
        -- overlay instruction. Keep the exact public definition ID and body.
        local clean: Entry = {}
        for field, value in pairs(entry) do if field ~= "registry" then clean[field] = value end end
        final[clean.id :: string] = clean
        local measured, measured_error = measured_entry(clean, component :: string)
        if not measured then return nil, nil, measured_error end
        candidate_entries[#candidate_entries + 1] = measured
    end
    for _, entry in ipairs(incoming) do
        if entry.kind == "ns.requirement" then
            local item, item_error = requirement(entry, component :: string, final)
            if not item then return nil, nil, item_error end
            requirements[#requirements + 1] = item
        end
    end
    local base_entries: {Object} = {}
    for _, entry in pairs(current) do base_entries[#base_entries + 1] = entry end
    table.sort(base_entries, function(left: any, right: any): boolean return left.id < right.id end)
    local base_bytes, base_error = canonical.encode({entries = base_entries}, 1048576)
    if not base_bytes then return nil, nil, "measure destination registry base: " .. tostring(base_error or "unknown error") end
    local base_digest, base_measure_error = hash.sha256(base_bytes)
    if not base_digest then return nil, nil, tostring(base_measure_error or "measure destination registry base") end
    local policy, policy_error = deps.policy(spec, captured, root)
    if not policy then return nil, nil, policy_error or "read destination private-overlay policy" end
    if policy.node_id ~= destination then return nil, nil, "host policy belongs to another destination" end
    local context, context_error = policy_context(policy, captured, base_digest :: string, current)
    if not context then return nil, nil, context_error end
    return {destination_node = destination, source_node = source,
        base_revision = captured.revision, base_digest = base_digest,
        artifacts = {{component = component, version = version, digest = spec.artifact_digest,
            dependencies = {}, namespaces = names}},
        entries = candidate_entries, requirements = requirements, migrations = {}}, context, nil
end

type Config = {overlay_owner: string?, root: (unknown) -> (Root?, string?),
    policy: (unknown, Captured, Root) -> (Policy?, string?)}

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
            overlay_ids = overlay_ids, owner = function(entry: Entry): (string?, string?)
                local metadata = object(entry.registry)
                local owner = metadata and bounds.text(metadata.owner, 160) or nil
                if not owner then return nil, "captured registry entry has no registry-owned module" end
                return owner, nil
            end}
        return captured, nil
    end
    function value:resolve(spec: unknown): (unknown?, unknown?, string?)
        return M.resolve_with(self :: Deps, spec)
    end
    return value
end

return M
