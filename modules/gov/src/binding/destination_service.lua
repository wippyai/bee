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
local activation_profiles = require("activation_profiles")
local capability_grants = require("capability_grants")
local capability_catalog = require("capability_catalog")
local capability_files = require("capability_files")
local workspace_applications = require("workspace_applications")

local M = {}
M.BACKEND = "bee.gov.binding:destination_backend_call"
M.EXECUTE = "bee.gov.delivery.execute"
M.SCOPE = "bee.gov.security:destination_execution_scope"
local ACTOR = "bee.gov.activation"
type Object = {[string]: unknown}
type Set = {[string]: boolean}
type DatabaseBinding = {database_id: string, table_prefix: string?}
type DatabaseBindings = {[string]: DatabaseBinding}
type PolicyIds = {string}
type Profile = {workspace_id: string, source_node: string, source_workspace: string,
    component: string, overlay_owner: string, approval_policy: string, resolver: string, parameters: {unknown},
    packages: Set, namespaces: Set, kinds: Set, databases: Set, grants: Set, modules: Set,
    database_bindings: DatabaseBindings?, migration_policies: PolicyIds?, applications: {Object}?,
    auto_start: boolean, policy_digest: string}
type Configuration = activation_profiles.Configuration
type Result = transaction.Result
type ResolverRoot = {component: string, version: string, parameters: {unknown}}
type ResolverPolicy = {node_id: string, policy_digest: string, packages: Set,
    namespaces: Set, kinds: Set, databases: Set, grants: Set, modules: Set,
    database_bindings: DatabaseBindings?, applied: {[string]: unknown}, applied_databases: {[string]: unknown},
    migration_barrier: boolean, auto_start: boolean, applications: {Object}?, workspace_id: string?, overlay_owner: string?,
    source_node: string?, source_workspace: string?, workspace_application: boolean?,
    base_policy_digest: string?}
type Resolver = {resolve: (Resolver, unknown) -> (unknown?, unknown?, string?)}

local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end

function M.configuration(raw: unknown, node_raw: unknown): (Configuration?, string?)
    return activation_profiles.configuration(raw, node_raw)
end

local function load(): (Configuration?, string?)
    local node_id, node_error = system.node.id()
    if not node_id or node_error then return nil, "native node identity is unavailable" end
    local entry, entry_error = resources.activation_profiles()
    if not entry then return nil, tostring(entry_error or "activation profiles are unavailable") end
    local data = bounds.object(entry.data)
    if not data then return nil, "activation profiles are malformed" end
    return M.configuration(data, node_id)
end

local function selected(config: Configuration, workspace_id: string, source_node: string,
    source_workspace: string, activation_store: activations.Store?): (Profile?, string?)
    local installed: unknown = nil
    local vocabulary: capability_catalog.Catalog? = nil
    local owner_hint: string? = nil
    local slot_source: string? = nil
    local workspace_identity = workspace_applications.identity(workspace_id, source_workspace)
    local prior_owner = workspace_applications.prior_owner(workspace_id, source_workspace)
    if prior_owner then
        local prior_id = capability_grants.prior_record_id(prior_owner)
        if (prior_id and registry.get(prior_id)) then owner_hint = prior_owner end
        if activation_store then
            local desired = activations.desired(activation_store, prior_owner)
            if desired.ok then owner_hint = prior_owner
            elseif desired.code ~= "NOT_FOUND" then return nil, desired.message end
        end
    end
    local owner = owner_hint or (workspace_identity and workspace_identity.overlay_owner)
    if owner and activation_store then
        local desired = activations.desired(activation_store, owner)
        if desired.ok then
            local held = bounds.object(desired.value)
            slot_source = held and bounds.id(held.source_node) or nil
            if not slot_source then return nil, "desired activation source is malformed" end
        elseif desired.code ~= "NOT_FOUND" then return nil, desired.message end
    end
    local id = owner and (owner_hint and capability_grants.prior_record_id(owner)
        or capability_grants.record_id(owner)) or nil
    if id then
        installed = registry.get(id)
        if installed then
            local raw_catalog = registry.get("bee:capability_catalog")
            local decoded, catalog_error = capability_catalog.decode(raw_catalog)
            if not decoded then return nil, catalog_error end
            vocabulary = decoded
            local record, record_error = capability_grants.decode(installed, owner,
                workspace_id, workspace_identity.definition_id, decoded)
            if not record then return nil, record_error end
            local live, live_error = capability_grants.live(record,
                function(entry_id: string): unknown return registry.get(entry_id) end)
            if not live then return nil, live_error end
        end
    end
    return activation_profiles.select(config, workspace_id, source_node, source_workspace,
        installed, vocabulary, owner_hint, slot_source)
end

local function migration_binding(profile_value: Profile, target: string): (DatabaseBinding?, string?)
    if profile_value.database_bindings == nil then return nil, nil end
    local binding = profile_value.database_bindings[target]
    if not binding then return nil, "activation profile has no database binding for " .. target end
    return binding, nil
end

local function approval_executor(): (unknown?, string?)
    local request_id, request_ref_error = resources.approval_request_policy()
    local consume_id, consume_ref_error = resources.approval_consume_policy()
    if not request_id or not consume_id then return nil, tostring(request_ref_error or consume_ref_error or "approval policies are unavailable") end
    local request, request_error = security.policy(request_id)
    local consume, consume_error = security.policy(consume_id)
    if not request or not consume then return nil, tostring(request_error or consume_error or "load approval policies") end
    return funcs.new():with_actor(security.new_actor(ACTOR)):with_scope(security.new_scope({request, consume})), nil
end

-- The destination workspace's folder, read from the node workspace catalog
-- under the host-selected folder policy and resolved against its admitted
-- root, for rooting file grants. It is configuration only; the host installs
-- the volume after approval.
local function workspace_folder(workspace_id: string): (unknown?, string?)
    local read_id, read_error = resources.workspace_folder_read()
    local policy_id, policy_error = resources.workspace_folder_policy()
    if not read_id or not policy_id then return nil, read_error or policy_error end
    local policy, load_error = security.policy(policy_id)
    if not policy then return nil, tostring(load_error or "load workspace folder policy") end
    local executor = funcs.new():with_actor(security.new_actor(ACTOR)):with_scope(security.new_scope({policy}))
    local reply_raw, call_error = executor:call(read_id, {workspace_id = workspace_id})
    local reply = bounds.object(reply_raw)
    local value = reply and reply.ok == true and bounds.object(reply.value) or nil
    local row = value and bounds.object(value.workspace) or nil
    local root_ref = row and bounds.id(row.root_ref) or nil
    local subpath = row and row.subpath or nil
    if not root_ref or type(subpath) ~= "string" then
        local fault = reply and bounds.object(reply.error) or nil
        return nil, "workspace folder is unavailable: " .. tostring(call_error or (fault and fault.message)
            or "the workspace catalog returned no folder")
    end
    local root = registry.get(root_ref)
    local data = root and bounds.object(root.data) or nil
    if not root or root.kind ~= "fs.directory" or not data or type(data.directory) ~= "string" then
        return nil, "workspace root " .. root_ref .. " is not an fs.directory"
    end
    return {root_ref = root_ref, directory = data.directory, base = data.base, subpath = subpath}, nil
end

local function destination_resolver(profile_value: Profile, node_id: string, workspace_id: string,
    activation_store: activations.Store?, base_policy_digest: string?): unknown
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
        local applied_databases: Object = {}
        if activation_store then
            local known = activations.applied(activation_store, profile_value.component)
            if not known.ok then return nil, tostring(known.message or "read applied migration facts") end
            local evidence = bounds.object(known.value)
            applied = evidence and bounds.object(evidence.migrations) or {}
            local historical = evidence and bounds.object(evidence.databases) or {}
            applied_databases = historical
            for _, fact in pairs(applied) do
                local item = bounds.object(fact)
                local target = item and bounds.id(item.target_db) or nil
                local migration_id = item and bounds.id(item.id) or nil
                if not target or not migration_id then return nil, "stored applied migration fact is malformed" end
                local captured = bounds.object(historical[target])
                if not captured then return nil, "stored applied migration has no database evidence" end
                local binding, binding_error = migration_binding(profile_value, target)
                if binding_error then return nil, binding_error end
                local current_database = binding and binding.database_id or target
                local current_prefix = binding and binding.table_prefix or nil
                if captured.database_id ~= current_database or captured.table_prefix ~= current_prefix then
                    return nil, "activation profile changes an applied migration database binding: " .. target
                end
                local frozen = {database_id = captured.database_id :: string,
                    table_prefix = captured.table_prefix :: string?}
                local present, ledger_error = migration_runner.is_applied(target, migration_id, frozen)
                if present == nil then return nil, tostring(ledger_error or "read target migration ledger") end
                if not present then return nil, "target migration ledger differs from Governance facts: " .. migration_id end
            end
        end
        return {node_id = node_id, policy_digest = profile_value.policy_digest,
            packages = profile_value.packages, namespaces = profile_value.namespaces, kinds = profile_value.kinds,
            databases = profile_value.databases, grants = profile_value.grants, modules = profile_value.modules,
            database_bindings = profile_value.database_bindings,
            applications = profile_value.applications, workspace_id = profile_value.workspace_id,
            overlay_owner = profile_value.overlay_owner, source_node = profile_value.source_node,
            source_workspace = profile_value.source_workspace,
            workspace_application = base_policy_digest ~= nil,
            base_policy_digest = base_policy_digest,
            applied = applied, applied_databases = applied_databases, migration_barrier = true,
            auto_start = profile_value.auto_start}, nil
    end
    if profile_value.resolver == "overlay" then
        return overlay_resolver.new({overlay_owner = profile_value.overlay_owner,
            root = function(spec_raw: unknown): (overlay_resolver.Root?, string?)
                local root, root_error = selected_root(spec_raw)
                if not root then return nil, root_error end
                return {component = root.component, version = root.version}, nil
            end, policy = selected_policy,
            folder = function(): (unknown?, string?) return workspace_folder(workspace_id) end})
    end
    return resolver.new({overlay_owner = profile_value.overlay_owner,
        root = selected_root, policy = selected_policy})
end

local function generated_install(profile_value: Profile, intent_raw: unknown): (Object?, string?)
    local identity = workspace_applications.identity(profile_value.workspace_id, profile_value.source_workspace)
    local prior_owner = workspace_applications.prior_owner(profile_value.workspace_id, profile_value.source_workspace)
    local uses_prior = prior_owner ~= nil and prior_owner == profile_value.overlay_owner
    if not identity or (identity.overlay_owner ~= profile_value.overlay_owner and not uses_prior)
        or identity.component ~= profile_value.component then return nil, nil end
    local intent = bounds.object(intent_raw)
    if not intent or intent.overlay_owner ~= profile_value.overlay_owner
        or intent.workspace_id ~= profile_value.workspace_id
        or not bounds.id(intent.approval_id) or not bounds.id(intent.version) then
        return nil, "capability activation identity is invalid"
    end
    local candidate, candidate_error = preflight.decode_candidate(intent.resolution_bytes,
        intent.resolution_digest)
    if not candidate then return nil, candidate_error end
    local vocabulary, catalog_error = capability_catalog.decode(registry.get("bee:capability_catalog"))
    if not vocabulary then return nil, catalog_error end
    local requested: {Object} = {}
    for _, requirement in ipairs(candidate.requirements) do
        if requirement.capability_request then requested[#requested + 1] = requirement end
    end
    local folder: unknown = nil
    if capability_files.rooted(requested) then
        local resolved, folder_error = workspace_folder(profile_value.workspace_id)
        if not resolved then return nil, folder_error end
        folder = resolved
    end
    local proposed, proposed_error = capability_grants.propose(vocabulary, profile_value.overlay_owner,
        identity.definition_id, requested, uses_prior, folder)
    if not proposed then return nil, proposed_error end
    local record_id = uses_prior and capability_grants.prior_record_id(profile_value.overlay_owner)
        or capability_grants.record_id(profile_value.overlay_owner)
    local prior_raw = record_id and registry.get(record_id) or nil
    local prior: Object? = nil
    if prior_raw then
        local decoded, decoded_error = capability_grants.decode(prior_raw, profile_value.overlay_owner,
            profile_value.workspace_id, identity.definition_id, vocabulary)
        if not decoded then return nil, decoded_error end
        local live, live_error = capability_grants.live(decoded,
            function(id: string): unknown return registry.get(id) end)
        if not live then return nil, live_error end
        prior = decoded
    end
    local approval_id = bounds.id(intent.approval_id)
    local revision: integer = 1
    local installed_same = prior and prior.artifact_digest == intent.artifact_digest
        and prior.version == intent.version
    if installed_same then
        if prior.digest ~= proposed.digest or prior.approval_id ~= approval_id then
            return nil, "installed grant differs from the activated intent"
        end
        revision = prior.revision :: integer
    else
        if (prior and prior.record_digest or nil) ~= intent.grant_predecessor_digest then
            return nil, "installed grant changed since permission review"
        end
        local compared, compare_error = capability_grants.diff(vocabulary, prior, proposed)
        if not compared then return nil, compare_error end
        if prior and not compared.requires_approval then
            if intent.grant_reuse_digest ~= prior.record_digest or approval_id ~= prior.approval_id then
                return nil, "contained upgrade has no matching installed grant reuse"
            end
        elseif intent.grant_reuse_digest ~= nil then
            return nil, "widening cannot reuse an installed grant"
        end
        if prior then revision = (prior.revision :: integer) + 1 end
    end
    local record, record_error = capability_grants.record(profile_value.overlay_owner,
        profile_value.workspace_id, identity.definition_id, proposed, approval_id, revision,
        intent.artifact_digest, intent.version, uses_prior)
    if not record then return nil, record_error end
    return {policies = proposed.policies, bindings = proposed.bindings, record = record,
        volumes = proposed.volumes, databases = proposed.databases}, nil
end

local function owner_config(config: Configuration, profile_value: Profile, plan_store: plans.Store,
    activation_store: activations.Store): (owner.Config?, string?)
    local executor, executor_error = approval_executor()
    if not executor then return nil, executor_error end
    local workspace_identity = workspace_applications.identity(profile_value.workspace_id,
        profile_value.source_workspace)
    local base_digest: string? = nil
    if workspace_identity and (workspace_identity.overlay_owner == profile_value.overlay_owner
        or workspace_applications.prior_owner(profile_value.workspace_id,
            profile_value.source_workspace) == profile_value.overlay_owner)
        and workspace_identity.component == profile_value.component then
        local base, base_error = activation_profiles.select(config, profile_value.workspace_id,
            profile_value.source_node, profile_value.source_workspace, nil, nil, profile_value.overlay_owner)
        if not base then return nil, base_error end
        base_digest = base.policy_digest
    end
    local resolved = destination_resolver(profile_value, activation_store.node,
        profile_value.workspace_id, activation_store, base_digest)
    local migration_adapter = {
        matches = migration_effect.matches, prepare = migration_effect.prepare,
        clear = migration_effect.clear, cleared = migration_effect.cleared,
        execute = function(work: unknown): ({bytes: string, digest: string}?, boolean, string?)
            local receipt, complete, execute_error = migration_effect.execute(work, profile_value.migration_policies)
            return receipt, complete, execute_error
        end,
    }
    return {plans = plan_store, activations = activation_store, resolver = resolved :: owner.Resolver,
        approvals = executor :: owner.Executor, actor_id = ACTOR, consumer_id = ACTOR,
        overlay_owner = profile_value.overlay_owner, approval_policy = profile_value.approval_policy,
        apply = function(overlay_owner: string, entries: unknown, admission: unknown?, intent: unknown): ({[string]: unknown}?, string?)
            local generated, generated_error = generated_install(profile_value, intent)
            if generated_error then return nil, generated_error end
            return materializer.reconcile_composed(overlay_owner, entries, admission, generated)
        end, matches = function(overlay_owner: string, entries: unknown, admission: unknown?, intent: unknown): (boolean?, string?)
            local generated, generated_error = generated_install(profile_value, intent)
            if generated_error then return nil, generated_error end
            return materializer.matches_composed(overlay_owner, entries, admission, generated)
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
    local chosen, profile_error = selected(config, workspace_id, source_node, source_workspace, activation_store)
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
    local installed_entries = base.installed_entries == nil and {} or bounds.object(base.installed_entries)
    local base_digest = bounds.text(base.registry_digest, 64)
    local base_revision = bounds.count(base.registry_revision)
    if not base_entries or not installed_entries or not base_digest or base_revision == nil then
        return failure("INTERNAL", "resolved composed base is malformed")
    end
    -- Approval measures the external composition and deliberately excludes
    -- the selected overlay, since applying that overlay must not invalidate
    -- its own evidence. Change review compares against the separately
    -- measured installed state as well: this update replaces that complete
    -- owner-local set.
    local comparison: Object = {}
    for id, item in pairs(base_entries) do comparison[id] = item end
    for id, item in pairs(installed_entries) do comparison[id] = item end
    local packages: Set = {}
    for _, item in ipairs(reviewed.artifacts) do packages[item.component] = true end
    local proposed: Set = {}
    local added: {Object} = {}
    local changed: {Object} = {}
    local removed: {Object} = {}
    for _, item in ipairs(reviewed.entries) do
        proposed[item.id] = true
        local existing = bounds.object(comparison[item.id])
        local row = entry_change({id = item.id, kind = item.kind, digest = item.digest})
        if not row then return failure("INTERNAL", "reviewed candidate entry is malformed") end
        if not existing then added[#added + 1] = row
        elseif existing.digest ~= item.digest then changed[#changed + 1] = row end
    end
    -- An update replaces the complete owned set, so a base entry of an updated
    -- package that the candidate omits is removed by this plan.
    for id, raw in pairs(comparison) do
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

local function request_identity(request: Object): (string?, string?, string?)
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
    if READS[operation] then return "bee.gov.delivery.read" end
    if MANAGES[operation] then return "bee.gov.delivery.manage" end
    return "bee.gov.delivery.activate"
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
                -- A version is available here when the host profile selected for
                -- its source overlay publishes exactly that component. With Hive
                -- admission the workspace-applications rule selects for every
                -- source node that made a version of the feed available.
                local sources: {string} = {}
                local listed: Set = {}
                local function add(source_node: string)
                    if not listed[source_node] then
                        listed[source_node] = true
                        sources[#sources + 1] = source_node
                    end
                end
                for _, item in ipairs(config.profiles) do
                    if item.workspace_id == workspace_id then add(item.source_node) end
                end
                local rule = config.workspace_applications
                if rule then add(node_id) end
                if rule and rule.hive then
                    local owners = replicas.sources(replica_store, delivery.FEED, 128)
                    local owners_value = owners.ok and bounds.object(owners.value) or nil
                    local names = owners_value and owners_value.sources or nil
                    if type(names) ~= "table" then
                        result = owners.ok and failure("INTERNAL", "replica source list is malformed") or owners
                    else
                        for _, owner_raw in ipairs(names :: {unknown}) do
                            local owner = bounds.id(owner_raw)
                            if not owner then result = failure("INTERNAL", "replica source is malformed"); break end
                            add(owner)
                        end
                    end
                end
                local items: {unknown} = {}
                for _, source_node in ipairs(result == nil and sources or {}) do
                    local found = replicas.available(replica_store, source_node, delivery.FEED, 128)
                    if not found.ok then result = found; break end
                    local value = bounds.object(found.value)
                    local rows = value and value.items
                    if type(rows) ~= "table" then result = failure("INTERNAL", "available replica list is malformed"); break end
                    for _, raw_descriptor in ipairs(rows :: {unknown}) do
                        local descriptor = bounds.object(raw_descriptor)
                        local manifest = descriptor and bounds.object(descriptor.manifest) or nil
                        local source_workspace = manifest and bounds.id(manifest.source_workspace) or nil
                        local chosen = descriptor and source_workspace
                            and selected(config, workspace_id, source_node, source_workspace) or nil
                        if descriptor and chosen and descriptor.object_id == chosen.component then
                            items[#items + 1] = descriptor
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
                            application.value.source_workspace, activation_store)
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
        local source_node, source_workspace, version = request_identity(request)
        if exact(request, {"source_node", "source_workspace", "version"})
            or not source_node or not source_workspace or not version then result = failure("INVALID", "plan identity is invalid")
        else result = plans.call(plan_store, actor_id, {operation = "get", source_node = source_node,
            source_workspace = source_workspace, version = version}) end
    elseif operation == "changes" then
        local source_node, source_workspace, version = request_identity(request)
        if exact(request, {"source_node", "source_workspace", "version"}) then
            result = failure("INVALID", "plan identity is invalid")
        elseif not source_node or not source_workspace or not version then
            result = failure("INVALID", "plan identity is invalid")
        else
            result = plan_changes(plan_store, activation_store, actor_id, workspace_id, source_node, source_workspace, version)
        end
    elseif operation == "review" or operation == "select" then
        local source_node, source_workspace, version = request_identity(request)
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
        local source_node, source_workspace = request_identity(request)
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
            chosen, profile_error = selected(config, workspace_id, source_node, source_workspace, activation_store)
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
-- reviews, selects or creates an approval request. A slot whose source the
-- host no longer selects for that owner stays unrestored.
function M.recover_all(): (boolean, string?)
    local config, config_error = load()
    if not config then return false, config_error end
    local node_id = config.node_id
    local resource, resource_error = resources.database()
    if not resource then return false, resource_error end
    local listed = activations.desired_slots(resource, node_id)
    if not listed.ok then return false, listed.message end
    local value = bounds.object(listed.value)
    local slots = value and value.slots
    if type(slots) ~= "table" then return false, "desired activation slots are malformed" end
    for _, raw_slot in ipairs(slots :: {unknown}) do
        local slot = bounds.object(raw_slot)
        local workspace_id = slot and bounds.id(slot.workspace_id) or nil
        local overlay_owner = slot and bounds.id(slot.overlay_owner) or nil
        if not workspace_id or not overlay_owner then return false, "desired activation slot is malformed" end
        local plan_store, activation_store, open_error = stores(node_id, workspace_id)
        if not plan_store or not activation_store then return false, open_error or "open destination stores" end
        for attempt = 1, 4 do
            local desired = activations.desired(activation_store, overlay_owner)
            if not desired.ok then
                close(plan_store, activation_store)
                if desired.code == "NOT_FOUND" then break end
                return false, desired.message
            end
            local intent = bounds.object(desired.value)
            local source_node = intent and bounds.id(intent.source_node) or nil
            local source_workspace = intent and bounds.id(intent.source_workspace) or nil
            if not intent or not source_node or not source_workspace then
                close(plan_store, activation_store)
                return false, "desired activation intent is malformed"
            end
            local chosen = selected(config, workspace_id, source_node, source_workspace, activation_store)
            if not chosen or chosen.overlay_owner ~= overlay_owner then break end
            local composed, compose_error = owner_config(config, chosen, plan_store, activation_store)
            if not composed then
                close(plan_store, activation_store)
                return false, compose_error or "desired activation has no host profile"
            end
            local receipt_bytes = canonical.encode({schema_revision = "bee.governance-recovery@1",
                workspace_id = workspace_id, intent_id = intent.intent_id, revision = intent.revision, attempt = attempt})
            local receipt = receipt_bytes and hash.sha256(receipt_bytes) or nil
            if not receipt then close(plan_store, activation_store); return false, "measure activation recovery" end
            local recovered = owner.recover(composed :: owner.Config, receipt)
            if not recovered.ok then close(plan_store, activation_store); return false, recovered.message end
            local recovered_value = bounds.object(recovered.value)
            if recovered_value and recovered_value.phase == "settled" then break end
        end
        close(plan_store, activation_store)
    end
    return true, nil
end

return M
