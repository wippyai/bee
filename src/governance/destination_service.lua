-- MIT. Destination-owned composition for reviewed application delivery.
-- Replicas and Hub metadata supply bytes. This service selects host policy,
-- checks the local caller, owns approval consumption and applies one overlay.
local registry = require("registry")
local security = require("security")
local system = require("system")
local funcs = require("funcs")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local transaction = require("transaction")
local resources = require("resources")
local sync_resources = require("sync_resources")
local replicas = require("replicas")
local plans = require("plan_store")
local activations = require("activation_store")
local owner = require("activation_owner")
local resolver = require("hub_resolver")
local overlay_resolver = require("overlay_resolver")
local delivery = require("delivery")
local destination = require("destination")
local preflight = require("preflight")
local materializer = require("materializer")
local migration_effect = require("migration_effect")
local migration_runner = require("migration_runner")

local M = {}
M.BACKEND = "bee.governance:destination_backend_call"
M.EXECUTE = "bee.governance.delivery.execute"
M.SCOPE = "bee:destination_execution_scope"
local CONFIG = "bee.governance:activation_profiles"
local ACTOR = "bee.governance.activation"
local MAX_PROFILES = 64
local MAX_DATABASE_BINDINGS = 256
type Object = {[string]: unknown}
type Set = {[string]: boolean}
type DatabaseBinding = {database_id: string, table_prefix: string?}
type DatabaseBindings = {[string]: DatabaseBinding}
type PolicyIds = {string}
type Profile = {workspace_id: string, source_node: string, source_workspace: string,
    component: string, overlay_owner: string, approval_policy: string, resolver: string, parameters: {unknown},
    packages: Set, namespaces: Set, kinds: Set, databases: Set, grants: Set, modules: Set,
    database_bindings: DatabaseBindings?, migration_policies: PolicyIds?, policy_digest: string}
type Configuration = {profiles: {Profile}}
type Result = transaction.Result
type ResolverRoot = {component: string, version: string, parameters: {unknown}}
type ResolverPolicy = {node_id: string, policy_digest: string, packages: Set,
    namespaces: Set, kinds: Set, databases: Set, grants: Set, modules: Set,
    applied: {[string]: unknown}, migration_barrier: boolean}
type Resolver = {resolve: (Resolver, unknown) -> (unknown?, unknown?, string?)}

local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end

local function list(raw: unknown, label: string): ({unknown}?, string?)
    if type(raw) ~= "table" then return nil, label .. " must be a list" end
    local source = raw :: table
    local count = 0
    for key in pairs(source) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, label .. " must be a dense list" end
        count = count + 1
    end
    if count > 256 then return nil, label .. " exceeds its bound" end
    local result: {unknown} = {}
    for index = 1, count do
        if source[index] == nil then return nil, label .. " must be a dense list" end
        result[index] = source[index]
    end
    return result, nil
end

local function set(raw: unknown, label: string): (Set?, string?)
    local rows, rows_error = list(raw, label)
    if not rows then return nil, rows_error end
    local result: Set = {}
    for _, raw_value in ipairs(rows) do
        local value = bounds.id(raw_value)
        if not value or result[value] then return nil, label .. " contains an invalid or duplicate value" end
        result[value] = true
    end
    return result, nil
end

local function database_bindings(raw: unknown, databases: Set): (DatabaseBindings?, {unknown}?, string?)
    if raw == nil then return nil, nil, nil end
    local rows, rows_error = list(raw, "database bindings")
    if not rows then return nil, nil, rows_error end
    if #rows > MAX_DATABASE_BINDINGS then return nil, nil, "database bindings exceed their bound" end
    local result: DatabaseBindings = {}
    local measured: {unknown} = {}
    for index, raw_binding in ipairs(rows) do
        local value = bounds.object(raw_binding)
        local extra = value and bounds.fields(value, {"target_db", "database_id", "table_prefix"}) or nil
        local target_db = value and bounds.id(value.target_db) or nil
        local database_id = value and bounds.id(value.database_id) or nil
        local table_prefix: string? = nil
        if value and value.table_prefix ~= nil then
            table_prefix = bounds.text(value.table_prefix, 64)
            if not table_prefix or not table_prefix:match("^[A-Za-z][A-Za-z0-9_]*$") then
                return nil, nil, "database binding table_prefix is invalid"
            end
        end
        if not value or extra or not target_db or not database_id or not databases[target_db]
            or result[target_db] then
            return nil, nil, extra and "database binding: " .. extra
                or "database binding is invalid or duplicated"
        end
        result[target_db] = {database_id = database_id, table_prefix = table_prefix}
        local item: Object = {target_db = target_db, database_id = database_id}
        if table_prefix then item.table_prefix = table_prefix end
        measured[index] = item
    end
    table.sort(measured, function(left: unknown, right: unknown): boolean
        local a, b = bounds.object(left), bounds.object(right)
        return tostring(a and a.target_db or "") < tostring(b and b.target_db or "")
    end)
    return result, measured, nil
end

local function policy_ids(raw: unknown): (PolicyIds?, string?)
    if raw == nil then return nil, nil end
    local rows, rows_error = list(raw, "migration policies")
    if not rows then return nil, rows_error end
    if #rows > 64 then return nil, "migration policies exceed their bound" end
    local result: PolicyIds = {}
    local seen: Set = {}
    for index, raw_id in ipairs(rows) do
        local id = bounds.id(raw_id)
        if not id or seen[id] then return nil, "migration policies contain an invalid or duplicate value" end
        seen[id] = true
        result[index] = id
    end
    table.sort(result)
    return result, nil
end

local function profile(raw: unknown, node_id: string): (Profile?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "activation profile must be an object" end
    local extra = bounds.fields(value, {"workspace_id", "source_node", "source_workspace", "component",
        "overlay_owner", "approval_policy", "resolver", "parameters", "allow", "database_bindings",
        "migration_policies"})
    if extra then return nil, "activation profile: " .. extra end
    local workspace_id, source_node = bounds.id(value.workspace_id), bounds.id(value.source_node)
    local source_workspace, component = bounds.id(value.source_workspace), bounds.text(value.component, 160)
    local overlay_owner, approval_policy = bounds.id(value.overlay_owner), bounds.id(value.approval_policy)
    local resolver_kind = value.resolver == nil and "hub" or value.resolver
    local parameters, parameters_error = list(value.parameters or {}, "activation parameters")
    local allow = bounds.object(value.allow)
    if not workspace_id or not source_node or not source_workspace or not component or component == ""
        or not overlay_owner or not approval_policy or (resolver_kind ~= "hub" and resolver_kind ~= "overlay")
        or not parameters or not allow then
        return nil, parameters_error or "activation profile identity is invalid"
    end
    local allow_extra = bounds.fields(allow, {"packages", "namespaces", "kinds", "databases", "grants", "modules"})
    if allow_extra then return nil, "activation allowlist: " .. allow_extra end
    local packages, packages_error = set(allow.packages or {}, "allowed packages")
    local namespaces, namespaces_error = set(allow.namespaces or {}, "allowed namespaces")
    local kinds, kinds_error = set(allow.kinds or {}, "allowed kinds")
    local databases, databases_error = set(allow.databases or {}, "allowed databases")
    local grants, grants_error = set(allow.grants or {}, "allowed grants")
    local modules, modules_error = set(allow.modules or {}, "allowed modules")
    if not packages or not namespaces or not kinds or not databases or not grants or not modules then
        return nil, packages_error or namespaces_error or kinds_error or databases_error or grants_error or modules_error
    end
    local bindings, measured_bindings, bindings_error = database_bindings(value.database_bindings, databases)
    if bindings_error then return nil, bindings_error end
    local migration_policies, migration_policies_error = policy_ids(value.migration_policies)
    if migration_policies_error then return nil, migration_policies_error end
    local policy: Object = {schema_revision = "bee.governance-activation-policy@1",
        node_id = node_id, workspace_id = workspace_id, source_node = source_node,
        source_workspace = source_workspace, component = component, overlay_owner = overlay_owner,
        approval_policy = approval_policy, resolver = resolver_kind, parameters = parameters, allow = allow}
    if measured_bindings then policy.database_bindings = measured_bindings end
    if migration_policies then policy.migration_policies = migration_policies end
    local policy_bytes, encode_error = canonical.encode(policy)
    local policy_digest, digest_error = policy_bytes and hash.sha256(policy_bytes) or nil
    if not policy_digest then return nil, tostring(encode_error or digest_error or "measure activation policy") end
    return {workspace_id = workspace_id, source_node = source_node, source_workspace = source_workspace,
        component = component, overlay_owner = overlay_owner, approval_policy = approval_policy,
        resolver = resolver_kind :: string,
        parameters = parameters, packages = packages, namespaces = namespaces, kinds = kinds,
        databases = databases, grants = grants, modules = modules,
        database_bindings = bindings, migration_policies = migration_policies,
        policy_digest = policy_digest}, nil
end

function M.configuration(raw: unknown, node_raw: unknown): (Configuration?, string?)
    local node_id = bounds.id(node_raw)
    local value = bounds.object(raw)
    local rows, rows_error = list(value and value.profiles or nil, "activation profiles")
    if not node_id or not rows then return nil, rows_error or "activation configuration is invalid" end
    if #rows > MAX_PROFILES then return nil, "activation profile capacity is exceeded" end
    local result: {Profile} = {}
    local keys: Set = {}
    for _, raw_profile in ipairs(rows) do
        local item, item_error = profile(raw_profile, node_id)
        if not item then return nil, item_error end
        local key = item.workspace_id .. "\n" .. item.source_node .. "\n" .. item.source_workspace
        if keys[key] then return nil, "activation profile identity is duplicated" end
        keys[key] = true
        result[#result + 1] = item
    end
    return {profiles = result}, nil
end

local function load(): (Configuration?, string?)
    local node_id, node_error = system.node.id()
    if not node_id or node_error then return nil, "native node identity is unavailable" end
    local entry, entry_error = registry.get(CONFIG)
    if not entry then return nil, tostring(entry_error or "activation profiles are unavailable") end
    local data = bounds.object(entry.data)
    if not data then return nil, "activation profiles are malformed" end
    return M.configuration(data, node_id)
end

local function selected(config: Configuration, workspace_id: string, source_node: string,
    source_workspace: string): (Profile?, string?)
    local found: Profile? = nil
    for _, item in ipairs(config.profiles) do
        if item.workspace_id == workspace_id and item.source_node == source_node
            and item.source_workspace == source_workspace then
            if found then return nil, "activation profile identity is ambiguous" end
            found = item
        end
    end
    if not found then return nil, "destination host has no activation profile for this source" end
    return found, nil
end

local function migration_binding(profile_value: Profile, target: string): (DatabaseBinding?, string?)
    if profile_value.database_bindings == nil then return nil, nil end
    local binding = profile_value.database_bindings[target]
    if not binding then return nil, "activation profile has no database binding for " .. target end
    return binding, nil
end

local function approval_executor(): (unknown?, string?)
    local request, request_error = security.policy("bee:approval_request_policy")
    local consume, consume_error = security.policy("bee:approval_consume_policy")
    if not request or not consume then return nil, tostring(request_error or consume_error or "load approval policies") end
    return funcs.new():with_actor(security.new_actor(ACTOR)):with_scope(security.new_scope({request, consume})), nil
end

local function destination_resolver(profile_value: Profile, node_id: string, workspace_id: string,
    activation_store: activations.Store?): unknown
    local function selected_root(spec_raw: unknown): (ResolverRoot?, string?)
        local spec = bounds.object(spec_raw)
        if not spec or spec.owner_node ~= node_id or spec.workspace_id ~= workspace_id
            or spec.source_node ~= profile_value.source_node or spec.source_workspace ~= profile_value.source_workspace
            or not bounds.id(spec.version) then return nil, "selected plan does not match its activation profile" end
        local version = bounds.id(spec.version)
        if not version then return nil, "selected plan version is invalid" end
        return {component = profile_value.component, version = version, parameters = profile_value.parameters}, nil
    end
    local function selected_policy(spec_raw: unknown, _captured: unknown, _preview: Object): (ResolverPolicy?, string?)
        local spec = bounds.object(spec_raw)
        if not spec or spec.owner_node ~= node_id then return nil, "activation policy belongs to another node" end
        local applied: Object = {}
        if activation_store then
            local known = activations.applied(activation_store, profile_value.component)
            if not known.ok then return nil, tostring(known.message or "read applied migration facts") end
            applied = bounds.object(known.value) or {}
            for _, fact in pairs(applied) do
                local item = bounds.object(fact)
                local target = item and bounds.id(item.target_db) or nil
                local migration_id = item and bounds.id(item.id) or nil
                if not target or not migration_id then return nil, "stored applied migration fact is malformed" end
                local binding, binding_error = migration_binding(profile_value, target)
                if binding_error then return nil, binding_error end
                local present, ledger_error = migration_runner.is_applied(target, migration_id, binding)
                if present == nil then return nil, tostring(ledger_error or "read target migration ledger") end
                if not present then return nil, "target migration ledger differs from Governance facts: " .. migration_id end
            end
        end
        return {node_id = node_id, policy_digest = profile_value.policy_digest,
            packages = profile_value.packages, namespaces = profile_value.namespaces, kinds = profile_value.kinds,
            databases = profile_value.databases, grants = profile_value.grants, modules = profile_value.modules,
            applied = applied, migration_barrier = true}, nil
    end
    if profile_value.resolver == "overlay" then
        return overlay_resolver.new({overlay_owner = profile_value.overlay_owner,
            root = function(spec_raw: unknown): (overlay_resolver.Root?, string?)
                local root, root_error = selected_root(spec_raw)
                if not root then return nil, root_error end
                return {component = root.component, version = root.version}, nil
            end, policy = selected_policy})
    end
    return resolver.new({overlay_owner = profile_value.overlay_owner,
        root = selected_root, policy = selected_policy})
end

local function owner_config(config: Configuration, profile_value: Profile, plan_store: plans.Store,
    activation_store: activations.Store): (owner.Config?, string?)
    local executor, executor_error = approval_executor()
    if not executor then return nil, executor_error end
    local resolved = destination_resolver(profile_value, activation_store.node, profile_value.workspace_id, activation_store)
    local migration_adapter = {
        matches = migration_effect.matches, prepare = migration_effect.prepare,
        clear = migration_effect.clear, cleared = migration_effect.cleared,
        execute = function(work: unknown): ({bytes: string, digest: string}?, boolean, string?)
            local receipt, complete, execute_error = migration_effect.execute(work,
                profile_value.database_bindings, profile_value.migration_policies)
            return receipt, complete, execute_error
        end,
    }
    return {plans = plan_store, activations = activation_store, resolver = resolved :: owner.Resolver,
        approvals = executor :: owner.Executor, actor_id = ACTOR, consumer_id = ACTOR,
        overlay_owner = profile_value.overlay_owner, approval_policy = profile_value.approval_policy,
        apply = function(overlay_owner: string, entries: unknown): ({[string]: unknown}?, string?)
            return materializer.reconcile(overlay_owner, entries)
        end, matches = function(overlay_owner: string, entries: unknown): (boolean?, string?)
            return materializer.matches(overlay_owner, entries)
        end, migrations = migration_adapter}, nil
end

-- Read-only entry-set comparison for one staged plan. It decodes the exact
-- reviewed candidate from its own measured bytes and resolves the current
-- composed base through the host-selected resolver. It records no decision,
-- consumes no approval and writes no overlay.
local function entry_change(raw: unknown): Object?
    local item = bounds.object(raw)
    local id = item and bounds.id(item.id) or nil
    local kind = item and bounds.id(item.kind) or nil
    local measured = item and bounds.text(item.digest, 64) or nil
    if not item or not id or not kind or not measured then return nil end
    return {id = id, kind = kind, digest = measured}
end

local function by_id(rows: {Object})
    table.sort(rows, function(left: Object, right: Object): boolean
        return tostring(left.id) < tostring(right.id)
    end)
end

local function plan_changes(plan_store: plans.Store, activation_store: activations.Store, actor_id: string, workspace_id: string,
    source_node: string, source_workspace: string, version: string): Result
    local found = plans.call(plan_store, actor_id, {operation = "get", source_node = source_node,
        source_workspace = source_workspace, version = version})
    if not found.ok then return found end
    local plan = bounds.object(found.value)
    if not plan then return failure("INTERNAL", "plan store returned no plan") end
    local reviewed, candidate_error = preflight.decode_candidate(plan.candidate_bytes, plan.candidate_digest)
    if not reviewed then return failure("INTERNAL", tostring(candidate_error or "decode the reviewed candidate")) end
    local config, config_error = load()
    if not config then return failure("BLOCKED", config_error or "activation configuration is unavailable") end
    local chosen, profile_error = selected(config, workspace_id, source_node, source_workspace)
    if not chosen then return failure("BLOCKED", profile_error or "destination host has no activation profile for this source") end
    local owner_node = bounds.id(plan.owner_node)
    if not owner_node then return failure("INTERNAL", "plan store returned no owner") end
    local resolved = destination_resolver(chosen, owner_node, workspace_id, activation_store)
    local _, context, resolve_error = (resolved :: Resolver):resolve({owner_node = owner_node,
        workspace_id = workspace_id, source_node = source_node, source_workspace = source_workspace,
        version = version, artifact_bytes = plan.artifact_bytes, artifact_digest = plan.artifact_digest})
    local base = bounds.object(context)
    if not base then return failure("BLOCKED", tostring(resolve_error or "resolve the composed base")) end
    local base_entries = bounds.object(base.entries)
    local base_digest = bounds.text(base.registry_digest, 64)
    local base_revision = bounds.count(base.registry_revision)
    if not base_entries or not base_digest or base_revision == nil then
        return failure("INTERNAL", "resolved composed base is malformed")
    end
    local packages: Set = {}
    for _, item in ipairs(reviewed.artifacts) do packages[item.component] = true end
    local proposed: Set = {}
    local added: {Object} = {}
    local changed: {Object} = {}
    local removed: {Object} = {}
    for _, item in ipairs(reviewed.entries) do
        proposed[item.id] = true
        local existing = bounds.object(base_entries[item.id])
        local row = entry_change({id = item.id, kind = item.kind, digest = item.digest})
        if not row then return failure("INTERNAL", "reviewed candidate entry is malformed") end
        if not existing then added[#added + 1] = row
        elseif existing.digest ~= item.digest then changed[#changed + 1] = row end
    end
    -- An update replaces the complete owned set, so a base entry of an updated
    -- package that the candidate omits is removed by this plan.
    for id, raw in pairs(base_entries) do
        local existing = bounds.object(raw)
        local package = existing and bounds.id(existing.package) or nil
        if package and packages[package] and not proposed[id] then
            local row = entry_change(existing)
            if not row then return failure("INTERNAL", "composed base entry is malformed") end
            removed[#removed + 1] = row
        end
    end
    by_id(added)
    by_id(changed)
    by_id(removed)
    return transaction.success({owner_node = owner_node, workspace_id = workspace_id,
        source_node = source_node, source_workspace = source_workspace, version = version,
        plan_digest = plan.plan_digest, candidate_digest = plan.candidate_digest,
        artifact_digest = plan.artifact_digest, base_revision = reviewed.base_revision,
        base_digest = reviewed.base_digest, composed_base_revision = base_revision,
        composed_base_digest = base_digest, added = added, changed = changed, removed = removed}, false)
end

-- The public facade authenticates the caller's exact delivery operation and
-- then enters the private destination scope; this backend runs inside that
-- scope, where the caller's own actor is still the recorded one.
local function authorize(workspace_id: unknown): (string?, string?, Result?)
    local workspace = bounds.id(workspace_id)
    local actor = security.actor()
    if not workspace then return nil, nil, failure("INVALID", "destination workspace is invalid") end
    if not actor or not security.can(M.EXECUTE, M.BACKEND) then
        return nil, nil, failure("DENIED", "destination backend is not authorized")
    end
    local node_id, node_error = system.node.id()
    if not node_id or node_error then return nil, nil, failure("UNAVAILABLE", "native node identity is unavailable") end
    return node_id, actor:id(), nil
end

local function stores(node_id: string, workspace_id: string): (plans.Store?, activations.Store?, string?)
    local resource, resource_error = resources.database()
    if not resource then return nil, nil, resource_error end
    local plan_store, plan_error = plans.open(resource, node_id, workspace_id)
    if not plan_store then return nil, nil, plan_error end
    local activation_store, activation_error = activations.open(resource, node_id, workspace_id)
    if not activation_store then plans.close(plan_store); return nil, nil, activation_error end
    return plan_store, activation_store, nil
end

local function close(plan_store: plans.Store?, activation_store: activations.Store?)
    if activation_store then activations.close(activation_store) end
    if plan_store then plans.close(plan_store) end
end

local function identity(request: Object): (string?, string?, string?)
    return bounds.id(request.source_node), bounds.id(request.source_workspace), bounds.id(request.version)
end

local OPERATIONS: Set = {available = true, stage = true, list = true, get = true, changes = true,
    review = true, select = true, prepare = true, step = true, status = true, recover = true}
local READS: Set = {available = true, list = true, get = true, changes = true, status = true}
local MANAGES: Set = {stage = true, review = true, select = true}

-- One delivery action per operation, so the public facade authenticates the
-- exact operation a caller asks for before any store opens.
function M.required_action(raw: unknown): string?
    local operation = bounds.id(raw)
    if not operation or not OPERATIONS[operation] then return nil end
    if READS[operation] then return "bee.governance.delivery.read" end
    if MANAGES[operation] then return "bee.governance.delivery.manage" end
    return "bee.governance.delivery.activate"
end

local function exact(request: Object, fields: {string}): string?
    local allowed = {"operation", "workspace_id"}
    for _, field in ipairs(fields) do allowed[#allowed + 1] = field end
    return bounds.fields(request, allowed)
end

function M.call(raw: unknown): Result
    local request = bounds.object(raw)
    local operation = request and bounds.id(request.operation) or nil
    if not request or not operation or not OPERATIONS[operation] then
        return failure("INVALID", "destination request operation is invalid")
    end
    local node_id, actor_id, denied = authorize(request.workspace_id)
    if not node_id or not actor_id then return denied :: Result end
    local workspace_id = request.workspace_id :: string
    local plan_store, activation_store, open_error = stores(node_id, workspace_id)
    if not plan_store or not activation_store then return failure("UNAVAILABLE", open_error or "open destination stores") end
    local result: Result
    if operation == "available" then
        if exact(request, {}) then
            result = failure("INVALID", "available has unknown fields")
        else
            local config, config_error = load()
            local resource, resource_error = sync_resources.database()
            local replica_store, replica_error
            if resource then replica_store, replica_error = replicas.open(resource) end
            if not config or not replica_store then
                result = failure("UNAVAILABLE", config_error or resource_error or replica_error or "open replica store")
            else
                local items: {unknown} = {}
                for _, item in ipairs(config.profiles) do
                    if item.workspace_id == workspace_id then
                        local found = replicas.available(replica_store, item.source_node, delivery.FEED, 128)
                        if not found.ok then result = found; break end
                        local value = bounds.object(found.value)
                        local rows = value and value.items
                        if type(rows) ~= "table" then result = failure("INTERNAL", "available replica list is malformed"); break end
                        for _, raw_descriptor in ipairs(rows :: {unknown}) do
                            local descriptor = bounds.object(raw_descriptor)
                            local manifest = descriptor and bounds.object(descriptor.manifest) or nil
                            if descriptor and descriptor.object_id == item.component and manifest
                                and manifest.source_workspace == item.source_workspace then
                                items[#items + 1] = descriptor
                            end
                        end
                    end
                end
                if result == nil then result = transaction.success({workspace_id = workspace_id, versions = items}, false) end
                replicas.close(replica_store)
            end
        end
    elseif operation == "stage" then
        local fields = {"source_owner", "feed", "version_key", "descriptor_digest", "idempotency_key"}
        if exact(request, fields) then
            result = failure("INVALID", "stage has unknown fields")
        else
            local source_owner, feed = bounds.id(request.source_owner), bounds.id(request.feed)
            local version_key, idempotency_key = bounds.id(request.version_key), bounds.id(request.idempotency_key)
            local descriptor_digest = request.descriptor_digest
            if not source_owner or feed ~= delivery.FEED or not version_key or not idempotency_key
                or type(descriptor_digest) ~= "string" or #descriptor_digest ~= 64
                or not descriptor_digest:match("^[0-9a-f]+$") then
                result = failure("INVALID", "stage replica identity is invalid")
            else
                local admitted_source: string = source_owner :: string
                local admitted_feed: string = feed :: string
                local admitted_key: string = version_key :: string
                local admitted_digest: string = descriptor_digest :: string
                local admitted_receipt: string = idempotency_key :: string
                local config, config_error = load()
                local resource, resource_error = sync_resources.database()
                local replica_store, replica_error
                if resource then replica_store, replica_error = replicas.open(resource) end
                if not config or not replica_store then
                    result = failure("UNAVAILABLE", config_error or resource_error or replica_error or "open replica store")
                else
                    local replica_key = {source_owner = admitted_source, feed = admitted_feed,
                        version_key = admitted_key, descriptor_digest = admitted_digest}
                    local replicated = replicas.read(replica_store, replica_key)
                    local application: delivery.Delivery? = nil
                    if replicated.ok then
                        local value = bounds.object(replicated.value)
                        local descriptor = value and bounds.object(value.descriptor) or nil
                        if value and descriptor and type(value.content) == "string" and type(descriptor.content_digest) == "string" then
                            application = delivery.decode(value.content, descriptor.content_digest)
                        end
                    end
                    if not replicated.ok then result = replicated
                    elseif not application then result = failure("INVALID", "replica is not an application version")
                    else
                        local chosen, profile_error = selected(config, workspace_id, application.value.source_node,
                            application.value.source_workspace)
                        if not chosen then result = failure("BLOCKED", profile_error or "activation profile is unavailable")
                        else
                            local resolved = destination_resolver(chosen, node_id, workspace_id, activation_store)
                            result = destination.stage_replica(plan_store, replica_store, actor_id,
                                {source_owner = admitted_source, feed = admitted_feed, version_key = admitted_key,
                                    descriptor_digest = admitted_digest, idempotency_key = admitted_receipt},
                                resolved :: destination.Resolver, chosen.component)
                        end
                    end
                    replicas.close(replica_store)
                end
            end
        end
    elseif operation == "list" then
        if exact(request, {}) then result = failure("INVALID", "list has unknown fields")
        else result = plans.call(plan_store, actor_id, {operation = "list"}) end
    elseif operation == "get" then
        local source_node, source_workspace, version = identity(request)
        if exact(request, {"source_node", "source_workspace", "version"})
            or not source_node or not source_workspace or not version then result = failure("INVALID", "plan identity is invalid")
        else result = plans.call(plan_store, actor_id, {operation = "get", source_node = source_node,
            source_workspace = source_workspace, version = version}) end
    elseif operation == "changes" then
        local source_node, source_workspace, version = identity(request)
        if exact(request, {"source_node", "source_workspace", "version"}) then
            result = failure("INVALID", "plan identity is invalid")
        elseif not source_node or not source_workspace or not version then
            result = failure("INVALID", "plan identity is invalid")
        else
            result = plan_changes(plan_store, activation_store, actor_id, workspace_id, source_node, source_workspace, version)
        end
    elseif operation == "review" or operation == "select" then
        local source_node, source_workspace, version = identity(request)
        local fields = {"source_node", "source_workspace", "version", "expected_revision", "idempotency_key"}
        if operation == "review" then fields[#fields + 1] = "review_status"; fields[#fields + 1] = "review_reason" end
        if exact(request, fields) or not source_node or not source_workspace or not version then
            result = failure("INVALID", "plan mutation is invalid")
        else
            local forwarded: Object = {operation = operation == "review" and "record_review" or "select",
                source_node = source_node, source_workspace = source_workspace, version = version,
                expected_revision = request.expected_revision, idempotency_key = request.idempotency_key}
            if operation == "review" then
                forwarded.review_status, forwarded.review_reason = request.review_status, request.review_reason
            end
            result = plans.call(plan_store, actor_id, forwarded)
        end
    elseif operation == "status" then
        if exact(request, {"intent_id"}) then result = failure("INVALID", "activation status has unknown fields")
        else result = activations.get(activation_store, request.intent_id) end
    else
        local operation_fields: {[string]: {string}} = {
            prepare = {"source_node", "source_workspace", "version", "intent_id", "receipt_key"},
            step = {"intent_id", "receipt_key"},
            recover = {"source_node", "source_workspace", "receipt_key"}}
        if exact(request, operation_fields[operation]) then
            close(plan_store, activation_store)
            return failure("INVALID", "activation request has unknown fields")
        end
        local config, config_error = load()
        local source_node, source_workspace = identity(request)
        local intent: Object? = nil
        if operation == "step" then
            local current = activations.get(activation_store, request.intent_id)
            if current.ok then intent = bounds.object(current.value) end
            if not intent then result = current end
        end
        source_node = source_node or (intent and bounds.id(intent.source_node) or nil)
        source_workspace = source_workspace or (intent and bounds.id(intent.source_workspace) or nil)
        local chosen: Profile? = nil
        local profile_error: string? = nil
        if config and source_node and source_workspace then
            chosen, profile_error = selected(config, workspace_id, source_node, source_workspace)
        end
        local composed: any = nil
        local compose_error: string? = nil
        if chosen and config then
            composed, compose_error = owner_config(config, chosen, plan_store, activation_store)
        end
        if result == nil then
            if not config or not chosen or not composed then
                result = failure("BLOCKED", config_error or profile_error or compose_error or "activation configuration is unavailable")
            elseif operation == "prepare" then
                result = owner.prepare(composed :: owner.Config, {source_node = request.source_node,
                    source_workspace = request.source_workspace, version = request.version,
                    intent_id = request.intent_id, receipt_key = request.receipt_key})
            elseif operation == "step" then
                result = owner.step(composed :: owner.Config, request.intent_id, request.receipt_key)
            elseif operation == "recover" then
                result = owner.recover(composed :: owner.Config, request.receipt_key)
            else
                result = failure("INVALID", "unsupported destination operation")
            end
        end
    end
    close(plan_store, activation_store)
    return result
end

-- Boot recovery follows only already-authorized desired intents. It never
-- reviews, selects or creates an approval request.
function M.recover_all(): (boolean, string?)
    local config, config_error = load()
    if not config then return false, config_error end
    local node_id, node_error = system.node.id()
    if not node_id or node_error then return false, "native node identity is unavailable" end
    for _, item in ipairs(config.profiles) do
        local workspace_id = item.workspace_id
        local plan_store, activation_store, open_error = stores(node_id, workspace_id)
        if not plan_store or not activation_store then return false, open_error or "open destination stores" end
        for attempt = 1, 4 do
            local desired = activations.desired(activation_store, item.overlay_owner)
            if not desired.ok then
                close(plan_store, activation_store)
                if desired.code == "NOT_FOUND" then break end
                return false, desired.message
            end
            local intent = bounds.object(desired.value)
            local source_node = intent and bounds.id(intent.source_node) or nil
            local source_workspace = intent and bounds.id(intent.source_workspace) or nil
            local chosen: Profile? = item
            local profile_error: string? = nil
            if source_node ~= item.source_node or source_workspace ~= item.source_workspace then
                chosen, profile_error = nil, "desired activation does not match its host profile"
            end
            local composed: any = nil
            local compose_error: string? = nil
            if chosen then composed, compose_error = owner_config(config, chosen, plan_store, activation_store) end
            if not intent or not chosen or not composed then
                close(plan_store, activation_store)
                return false, profile_error or compose_error or "desired activation has no host profile"
            end
            local receipt_bytes = canonical.encode({schema_revision = "bee.governance-recovery@1",
                workspace_id = workspace_id, intent_id = intent.intent_id, revision = intent.revision, attempt = attempt})
            local receipt = receipt_bytes and hash.sha256(receipt_bytes) or nil
            if not receipt then close(plan_store, activation_store); return false, "measure activation recovery" end
            local recovered = owner.recover(composed :: owner.Config, receipt)
            if not recovered.ok then close(plan_store, activation_store); return false, recovered.message end
            local value = bounds.object(recovered.value)
            if value and value.phase == "settled" then break end
        end
        close(plan_store, activation_store)
    end
    return true, nil
end

return M
