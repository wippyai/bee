-- MIT. Destination-owned composition for reviewed application delivery.
-- Replicas and Hub metadata supply bytes. This service selects host policy,
-- checks the local caller, owns approval consumption and applies one overlay.
local registry = require("registry")
local security = require("security")
local time = require("time")
local system = require("system")
local funcs = require("funcs")
local events = require("events")
local logger = require("logger")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local transaction = require("transaction")
local resources = require("resources")
local replicas = require("replicas")
local plans = require("plan_store")
local activations = require("activation_store")
local leases = require("lease_store")
local lease_grants = require("lease_grants")
local owner = require("activation_owner")
local resolver = require("hub_resolver")
local overlay_resolver = require("overlay_resolver")
local delivery = require("delivery")
local destination = require("destination")
local preflight = require("preflight")
local materializer = require("materializer")
local headless_revert = require("headless_revert")
local uninstall = require("activation_uninstall")
local artifact = require("artifact")
local driver_admission = require("driver_admission")
local migration_effect = require("migration_effect")
local migration_runner = require("migration_runner")
local activation_profiles = require("activation_profiles")
local capability_grants = require("capability_grants")
local capability_model = require("capability_model")
local capability_files = require("capability_files")
local workspace_applications = require("workspace_applications")

local M = {}
M.BACKEND = "bee.gov.binding:destination_backend_call"
M.EXECUTE = "bee.gov.delivery.execute"
M.SCOPE = "bee.gov.security:destination_execution_scope"
local ACTOR = "bee.gov.activation"
local ATTENTION = "bee.attention"
type Object = {[string]: unknown}
type Set = {[string]: boolean}
type DatabaseBinding = {database_id: string, table_prefix: string?}
type DatabaseBindings = {[string]: DatabaseBinding}
type PolicyIds = {string}
type Profile = {workspace_id: string, source_node: string, source_workspace: string,
    component: string, overlay_owner: string, approval_policy: string, resolver: string, parameters: {unknown},
    packages: Set, namespaces: Set, kinds: Set, databases: Set, grants: Set, modules: Set,
    database_bindings: DatabaseBindings?, migration_policies: PolicyIds?, applications: {Object}?,
    auto_start: boolean, super_edit: boolean, expires_at: string, policy_digest: string}
type Configuration = activation_profiles.Configuration
type Result = transaction.Result
type ResolverRoot = {component: string, version: string, parameters: {unknown}}
type ResolverPolicy = {node_id: string, policy_digest: string, packages: Set,
    namespaces: Set, kinds: Set, databases: Set, grants: Set, modules: Set,
    database_bindings: DatabaseBindings?, applied: {[string]: preflight.Migration},
    applied_databases: {[string]: preflight.DatabaseEvidence},
    migration_barrier: boolean, auto_start: boolean, super_edit: boolean, applications: {Object}?, workspace_id: string?, overlay_owner: string?,
    source_node: string?, source_workspace: string?, workspace_application: boolean?,
    base_policy_digest: string?}
type OwnerConfigResult = {ok: true, config: owner.Config} | {ok: false, error: string}

local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end

local function migration_database_owner(value: unknown): string?
    if type(value) ~= "string" or #value > 160 or value:find("%c") then return nil end
    return value
end

local function applied_database_evidence(raw: unknown): ({[string]: preflight.DatabaseEvidence}?, string?)
    local historical = bounds.object(raw)
    if not historical then return nil, "stored applied migration database evidence is malformed" end
    local result: {[string]: preflight.DatabaseEvidence} = {}
    for target_key, raw_database in pairs(historical) do
        local captured = bounds.object(raw_database)
        local target = bounds.id(target_key)
        local database_id = captured and bounds.id(captured.database_id) or nil
        local kind = captured and bounds.id(captured.kind) or nil
        local package = captured and migration_database_owner(captured.package) or nil
        local digest = captured and bounds.text(captured.digest, 64) or nil
        local table_prefix: string? = nil
        if captured and captured.table_prefix ~= nil then
            table_prefix = bounds.text(captured.table_prefix, 64)
            if not table_prefix or not table_prefix:match("^[A-Za-z][A-Za-z0-9_]*$") then
                return nil, "stored applied migration table prefix is malformed"
            end
        end
        if not target or not captured or captured.target_db ~= target then
            return nil, "stored applied migration database target is malformed"
        end
        if not database_id or not kind or not package then
            return nil, "stored applied migration database identity is malformed"
        end
        if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
            return nil, "stored applied migration database digest is malformed"
        end
        if type(captured.planned) ~= "boolean" then
            return nil, "stored applied migration planned-state evidence is malformed"
        end
        result[target] = {database_id = database_id, table_prefix = table_prefix,
            kind = kind, package = package, digest = digest}
    end
    return result, nil
end

M.applied_database_evidence = applied_database_evidence

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

-- The dedicated approver policy a super-edit row must name: it must exist,
-- list its approvers, and demand an explicit confirmation. The name is the
-- host's declaration of a person-confirmed, node-local decision; a policy
-- missing here or carrying any other confirmation is refused.
local function super_edit_approver_policy(name: string): (boolean, string?)
    local entry = registry.get("bee.security.approvals:approver_policies")
    local data = entry and bounds.object(entry.data) or nil
    local listed = data and data.policies or nil
    if type(listed) ~= "table" then return false, "approver policies are unavailable" end
    for _, raw in ipairs(listed) do
        local policy = bounds.object(raw)
        local declared = policy and bounds.id(policy.name) or nil
        if declared == name then
            local approvers = policy and policy.approvers or nil
            if type(approvers) ~= "table" or #(approvers) == 0 then
                return false, "super-edit approver policy " .. name .. " names no approvers"
            end
            if policy.confirm ~= "explicit" then
                return false, "super-edit approver policy " .. name .. " must confirm explicitly"
            end
            return true, nil
        end
    end
    return false, "super-edit approver policy " .. name .. " is not configured on this host"
end

-- A super-edit row is admitted only while unexpired and naming the dedicated
-- explicit-confirmation approver policy. The decoder already refused a row
-- that could grant security authority or start itself.
local FORMAT = "2006-01-02T15:04:05.000Z07:00"
function M.super_edit_admission(raw: unknown): (boolean, string?)
    local profile_value = bounds.object(raw)
    if not profile_value then return false, "super-edit admission needs a measured profile" end
    if profile_value.super_edit ~= true then return true, nil end
    local expires_at = bounds.text(profile_value.expires_at, 40)
    local approval_policy = bounds.id(profile_value.approval_policy)
    if not expires_at or not approval_policy then
        return false, "super-edit activation profile is malformed"
    end
    local expires = time.parse(FORMAT, expires_at)
    if not expires then return false, "super-edit activation profile has an invalid expiry" end
    if not expires:after(time.now()) then
        return false, "super-edit activation profile expired at " .. expires_at
    end
    if not approval_policy:match("^super%-edit") then
        return false, "a super-edit activation profile must name a super-edit approver policy"
    end
    return super_edit_approver_policy(approval_policy)
end

local function selected(config: Configuration, workspace_id: string, source_node: string,
    source_workspace: string, activation_store: activations.Store?): (Profile?, string?)
    local installed: unknown = nil
    local vocabulary: unknown = nil
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
            local raw_catalog = registry.get("bee.capability:catalog")
            local decoded, catalog_error = capability_model.decode(raw_catalog)
            if not decoded then return nil, catalog_error end
            vocabulary = decoded
            local record, record_error = capability_grants.decode(installed, owner,
                workspace_id, (bounds.object(installed) and bounds.object((bounds.object(installed)).data) or {}).application, decoded)
            if not record then return nil, record_error end
            local live, live_error = capability_grants.live(record,
                function(entry_id: string): unknown return registry.get(entry_id) end)
            if not live then return nil, live_error end
        end
        if installed == nil and workspace_identity == nil and config.packages then
            local entry = activation_profiles.find_package(config.packages, source_workspace)
            if entry then
                local package_owner = activation_profiles.package_owner(workspace_id, entry.component)
                local package_id = package_owner and capability_grants.record_id(package_owner) or nil
                local package_installed = package_id and registry.get(package_id) or nil
                if package_installed then
                    local raw_catalog = registry.get("bee.capability:catalog")
                    local decoded, catalog_error = capability_model.decode(raw_catalog)
                    if not decoded then return nil, catalog_error end
                    vocabulary = decoded
                    local record, record_error = capability_grants.decode(package_installed,
                        package_owner, workspace_id, entry.definition_id, decoded)
                    if not record then return nil, record_error end
                    local live, live_error = capability_grants.live(record,
                        function(entry_id: string): unknown return registry.get(entry_id) end)
                    if not live then return nil, live_error end
                    installed = package_installed
                end
            end
        end
    end
    local profile_value, profile_error = activation_profiles.select(config, workspace_id, source_node,
        source_workspace, installed, vocabulary, owner_hint, slot_source)
    if not profile_value then return nil, profile_error end
    local admitted, admission_error = M.super_edit_admission(profile_value)
    if not admitted then return nil, admission_error end
    return profile_value, nil
end

local function migration_binding(profile_value: Profile, target: string): (DatabaseBinding?, string?)
    if profile_value.database_bindings == nil then return nil, nil end
    local binding = profile_value.database_bindings[target]
    if not binding then return nil, "activation profile has no database binding for " .. target end
    return binding, nil
end

local function approval_executor(): (owner.Executor?, string?)
    local request_id, request_ref_error = resources.approval_request_policy()
    local consume_id, consume_ref_error = resources.approval_consume_policy()
    if not request_id or not consume_id then return nil, tostring(request_ref_error or consume_ref_error or "approval policies are unavailable") end
    local request, request_error = security.policy(request_id)
    local consume, consume_error = security.policy(consume_id)
    if not request or not consume then return nil, tostring(request_error or consume_error or "load approval policies") end
    local caller = funcs.new():with_actor(security.new_actor(ACTOR)):with_scope(security.new_scope({request, consume}))
    local executor: owner.Executor = {call = function(_self: owner.Executor, target: string, input: unknown): (unknown?, unknown?)
        local result, problem = caller:call(target, input)
        local value = bounds.object(result)
        return value, problem and tostring(problem) or nil
    end}
    return executor, nil
end

local function destination_resolver(config: Configuration, profile_value: Profile, node_id: string, workspace_id: string,
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
    local function selected_policy(spec_raw: unknown, _captured: unknown, _preview: unknown): (ResolverPolicy?, string?)
        local admitted, admission_error = M.super_edit_admission(profile_value)
        if not admitted then return nil, admission_error end
        local spec = bounds.object(spec_raw)
        if not spec or spec.owner_node ~= node_id then return nil, "activation policy belongs to another node" end
        local identity = workspace_applications.identity(profile_value.workspace_id, profile_value.source_workspace)
        local base_policy_digest: string? = nil
        if identity and identity.component == profile_value.component
            and (identity.overlay_owner == profile_value.overlay_owner
                or workspace_applications.prior_owner(profile_value.workspace_id,
                    profile_value.source_workspace) == profile_value.overlay_owner) then
            local base, base_error = activation_profiles.select(config, profile_value.workspace_id,
                profile_value.source_node, profile_value.source_workspace, nil, nil, profile_value.overlay_owner)
            if not base then return nil, base_error end
            base_policy_digest = base.policy_digest
        end
        local applied: {[string]: preflight.Migration} = {}
        local applied_databases: {[string]: preflight.DatabaseEvidence} = {}
        if activation_store then
            local known = activations.applied(activation_store, profile_value.component)
            if not known.ok then return nil, tostring(known.message or "read applied migration facts") end
            local evidence = bounds.object(known.value)
            local historical_migrations = evidence and bounds.object(evidence.migrations) or nil
            local historical_databases = evidence and bounds.object(evidence.databases) or nil
            if not evidence or not historical_migrations or not historical_databases then
                return nil, "stored applied migration evidence is malformed"
            end
            for key, raw in pairs(historical_migrations) do
                local item = bounds.object(raw)
                local target = item and bounds.id(item.target_db) or nil
                local migration_id = item and bounds.id(item.id) or nil
                local checksum = item and bounds.text(item.checksum, 64) or nil
                local ordinal = item and bounds.count(item.ordinal) or nil
                if type(key) ~= "string" or not target or not migration_id or key ~= target .. "\n" .. migration_id
                    or not checksum or #checksum ~= 64 or not checksum:match("^[0-9a-f]+$")
                    or ordinal == nil then return nil, "stored applied migration fact is malformed" end
                applied[key] = {id = migration_id, target_db = target, checksum = checksum, ordinal = ordinal}
            end
            local decoded_databases, database_error = applied_database_evidence(historical_databases)
            if not decoded_databases then return nil, database_error end
            applied_databases = decoded_databases
            for _, fact in pairs(applied) do
                local captured = applied_databases[fact.target_db]
                if not captured then return nil, "stored applied migration has no database evidence" end
                local binding, binding_error = migration_binding(profile_value, fact.target_db)
                if binding_error then return nil, binding_error end
                local current_database = binding and binding.database_id or fact.target_db
                local current_prefix = binding and binding.table_prefix or nil
                if captured.database_id ~= current_database or captured.table_prefix ~= current_prefix then
                    return nil, "activation profile changes an applied migration database binding: " .. fact.target_db
                end
                local frozen = {database_id = captured.database_id,
                    table_prefix = captured.table_prefix}
                local present, ledger_error = migration_runner.is_applied(fact.target_db, fact.id, frozen)
                if present == nil then return nil, tostring(ledger_error or "read target migration ledger") end
                if not present then return nil, "target migration ledger differs from Governance facts: " .. fact.id end
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
            auto_start = profile_value.auto_start, super_edit = profile_value.super_edit}, nil
    end
    if profile_value.resolver == "overlay" then
        return overlay_resolver.new({overlay_owner = profile_value.overlay_owner,
            root = function(spec_raw: unknown): (overlay_resolver.Root?, string?)
                local root, root_error = selected_root(spec_raw)
                if not root then return nil, root_error end
                return {component = root.component, version = root.version}, nil
            end, policy = selected_policy,
            folder = function(): (unknown?, string?) return resources.workspace_folder(workspace_id) end})
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
    local catalog_entry, catalog_lookup_error = registry.get("bee.capability:catalog")
    if not catalog_entry then return nil, "host capability catalog lookup failed: " .. tostring(catalog_lookup_error) end
    local vocabulary, catalog_error = capability_model.decode(catalog_entry)
    if not vocabulary then return nil, catalog_error end
    local requested: {Object} = {}
    for _, requirement in ipairs(candidate.requirements) do
        if requirement.capability_request then requested[#requested + 1] = requirement end
    end
    local folder: unknown = nil
    if capability_files.rooted(requested) then
        local resolved, folder_error = resources.workspace_folder(profile_value.workspace_id)
        if not resolved then return nil, folder_error end
        folder = resolved
    end
    local artifact_entries, artifact_error = artifact.decode(intent.artifact_bytes, intent.artifact_digest)
    if not artifact_entries then return nil, artifact_error end
    local application_id, application_error = workspace_applications.application(artifact_entries)
    if not application_id then return nil, application_error end
    local proposed, proposed_error = capability_grants.propose(vocabulary, profile_value.overlay_owner,
        application_id, requested, uses_prior, folder)
    if not proposed then return nil, proposed_error end
    local record_id = uses_prior and capability_grants.prior_record_id(profile_value.overlay_owner)
        or capability_grants.record_id(profile_value.overlay_owner)
    local prior_raw = record_id and registry.get(record_id) or nil
    local prior: Object? = nil
    if prior_raw then
        local decoded, decoded_error = capability_grants.decode(prior_raw, profile_value.overlay_owner,
            profile_value.workspace_id, application_id, vocabulary)
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
        revision = prior.revision
    elseif not (prior == nil and intent.phase == "settled" and intent.outcome == "applied"
        and intent.application_admission_digest ~= nil) then
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
        if prior then revision = (prior.revision) + 1 end
    end
    local record, record_error = capability_grants.record(profile_value.overlay_owner,
        profile_value.workspace_id, application_id, proposed, approval_id, revision,
        intent.artifact_digest, intent.version, uses_prior)
    if not record then return nil, record_error end
    return {policies = proposed.policies, bindings = proposed.bindings, record = record,
        volumes = proposed.volumes, databases = proposed.databases, executors = proposed.executors}, nil
end

-- approved_drivers visits every consumed driver artifact whose host-selected
-- owner matches its desired slot and whose exact code overlay is present.
local function approved_drivers(config: Configuration, visit: ({Object}) -> string?): string?
    local resource, resource_error = resources.database()
    if not resource then return resource_error end
    local listed = activations.desired_slots(resource, config.node_id)
    local value = listed.ok and bounds.object(listed.value) or nil
    local slots = value and bounds.dense_list(value.slots, 1024, "desired driver slots") or nil
    if not slots then return listed.message or "desired driver slots are unavailable" end
    for _, raw_slot in ipairs(slots) do
        local slot = bounds.object(raw_slot)
        local workspace = slot and bounds.id(slot.workspace_id) or nil
        local owner_id = slot and bounds.id(slot.overlay_owner) or nil
        if not workspace or not owner_id then return "desired driver slot is malformed" end
        local store, open_error = activations.open(resource, config.node_id, workspace)
        if not store then return open_error end
        local desired = activations.desired(store, owner_id)
        activations.close(store)
        if not desired.ok then return desired.message end
        local intent = desired.ok and bounds.object(desired.value) or nil
        local source = intent and bounds.id(intent.source_workspace) or nil
        if source then
            local source_node = intent and bounds.id(intent.source_node) or nil
            local profile = source_node and activation_profiles.select(config, workspace, source_node, source) or nil
            if profile and profile.overlay_owner == owner_id and intent and intent.consumed_consumer_id == ACTOR then
                local decoded, decode_error = artifact.decode(intent.artifact_bytes, intent.artifact_digest)
                if not decoded then return decode_error end
                local present, present_error = materializer.matches(owner_id, decoded)
                if present == nil then return present_error end
                if present then
                    local visit_error = visit(decoded)
                    if visit_error then return visit_error end
                end
            end
        end
    end
    return nil
end

local function approved_driver_bindings(config: Configuration): ({string}?, string?)
    local bindings: {string} = {}
    local seen: Set = {}
    local walk_error = approved_drivers(config, function(decoded: {Object}): string?
        local selected, selection_error = driver_admission.bindings(decoded)
        if not selected then return selection_error end
        for _, id in ipairs(selected) do
            if not seen[id] then
                if #bindings >= 64 then return "approved driver bindings exceed their bound" end
                bindings[#bindings + 1], seen[id] = id, true
            end
        end
        return nil
    end)
    if walk_error then return nil, walk_error end
    table.sort(bindings)
    return bindings, nil
end

function M.driver_bindings(): ({string}?, string?)
    local config, config_error = load()
    if not config then return nil, config_error end
    return approved_driver_bindings(config)
end

-- driver_logins reports the login format each approved driver declares for its
-- own provider; the credential host projects the machine login only for these.
function M.driver_logins(): ({Object}?, string?)
    local config, config_error = load()
    if not config then return nil, config_error end
    local logins: {Object} = {}
    local seen: Set = {}
    local walk_error = approved_drivers(config, function(decoded: {Object}): string?
        local declared, login_error = driver_admission.logins(decoded)
        if not declared then return login_error end
        for _, login in ipairs(declared) do
            if not seen[login.provider] then
                if #logins >= 64 then return "approved driver logins exceed their bound" end
                logins[#logins + 1], seen[login.provider] = {provider = login.provider, format = login.format, path = login.path}, true
            end
        end
        return nil
    end)
    if walk_error then return nil, walk_error end
    return logins, nil
end

local function owner_config(config: Configuration, profile_value: Profile, plan_store: plans.Store,
    activation_store: activations.Store, lease_handle: leases.Store): OwnerConfigResult
    local executor, executor_error = approval_executor()
    if not executor then return {ok = false, error = tostring(executor_error or "approval executor is unavailable")} end
    local resolved = destination_resolver(config, profile_value, activation_store.node,
        profile_value.workspace_id, activation_store)
    -- An application database the intent's grant provisions is staged with
    -- the grant that reaches it before its migrations run, and its migrations
    -- run with that grant; the application overlay installs both for good.
    local function database_grants(work: migration_work.Work, intent: unknown): ({unknown}?, {string}?, string?)
        local staged: {unknown} = {}
        local policies: {string} = {}
        local wanted: {[string]: migration_work.Database} = {}
        local any = false
        for _, item in ipairs(work.databases) do
            if item.database_id:sub(1, #capability_files.DATABASE_PREFIX) == capability_files.DATABASE_PREFIX then
                wanted[item.database_id], any = item, true
            end
        end
        if not any then return staged, policies, nil end
        local generated, generated_error = generated_install(profile_value, intent)
        if not generated then return nil, nil, generated_error or "the intent provisions no application database" end
        local granted: {[string]: boolean} = {}
        for _, raw_policy in ipairs(bounds.array(generated.policies, 64) or {}) do
            local policy = bounds.object(raw_policy)
            local data = policy and bounds.object(policy.data) or nil
            local inner = data and bounds.object(data.policy) or nil
            local resources = inner and bounds.array(inner.resources, 64) or nil
            local reaches: migration_work.Database? = nil
            for _, resource in ipairs(resources or {}) do
                if type(resource) == "string" and wanted[resource] then reaches = wanted[resource] end
            end
            if policy and reaches then
                policies[#policies + 1] = tostring(policy.id)
                granted[reaches.database_id] = true
                if reaches.planned then staged[#staged + 1] = policy end
            end
        end
        for id, item in pairs(wanted) do
            if not granted[id] then return nil, nil, "no approved grant reaches application database " .. id end
            if item.planned then staged[#staged + 1] = item.definition end
        end
        table.sort(policies)
        return staged, policies, nil
    end
    local migration_adapter = {
        matches = function(overlay_owner: string, work: migration_work.Work, intent: unknown): (boolean?, string?)
            local staged, _, staged_error = database_grants(work, intent)
            if not staged then return nil, staged_error end
            return migration_effect.matches(overlay_owner, work, staged)
        end,
        prepare = function(overlay_owner: string, work: migration_work.Work, intent: unknown): ({[string]: unknown}?, string?)
            local staged, _, staged_error = database_grants(work, intent)
            if not staged then return nil, staged_error end
            return migration_effect.prepare(overlay_owner, work, staged)
        end,
        clear = migration_effect.clear, cleared = migration_effect.cleared,
        execute = function(work: migration_work.Work, intent: unknown): ({bytes: string, digest: string}?, boolean, string?)
            local _, granted, grant_error = database_grants(work, intent)
            if not granted then return nil, false, grant_error end
            local execution: {string} = {}
            for _, id in ipairs(profile_value.migration_policies or {}) do execution[#execution + 1] = id end
            for _, id in ipairs(granted) do execution[#execution + 1] = id end
            local receipt, complete, execute_error = migration_effect.execute(work, execution)
            return receipt, complete, execute_error
        end,
    }
    local owner_configuration: owner.Config = {plans = plan_store, activations = activation_store, resolver = resolved,
        approvals = executor, actor_id = ACTOR, consumer_id = ACTOR, leases = lease_handle,
        overlay_owner = profile_value.overlay_owner, approval_policy = profile_value.approval_policy,
        apply = function(overlay_owner: string, entries: unknown, admission: unknown?, intent: unknown): ({[string]: unknown}?, string?)
            local generated, generated_error = generated_install(profile_value, intent)
            if generated_error then return nil, generated_error end
            return materializer.reconcile_composed(overlay_owner, entries, admission, generated)
        end, matches = function(overlay_owner: string, entries: unknown, admission: unknown?, intent: unknown): (boolean?, string?)
            local generated, generated_error = generated_install(profile_value, intent)
            if generated_error then return nil, generated_error end
            return materializer.matches_composed(overlay_owner, entries, admission, generated)
        end, migrations = migration_adapter}
    return {ok = true, config = owner_configuration}
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
    local resolved = destination_resolver(config, chosen, owner_node, workspace_id, activation_store)
    local _, context, resolve_error = (resolved):resolve({owner_node = owner_node,
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

local function stores(node_id: string, workspace_id: string): (plans.Store?, activations.Store?, leases.Store?, string?)
    local resource, resource_error = resources.database()
    if not resource then return nil, nil, nil, resource_error end
    local plan_store, plan_error = plans.open(resource, node_id, workspace_id)
    if not plan_store then return nil, nil, nil, plan_error end
    local activation_store, activation_error = activations.open(resource, node_id, workspace_id)
    if not activation_store then plans.close(plan_store); return nil, nil, nil, activation_error end
    local lease_handle, lease_error = leases.open(resource, node_id, workspace_id)
    if not lease_handle then
        activations.close(activation_store)
        plans.close(plan_store)
        return nil, nil, nil, lease_error
    end
    return plan_store, activation_store, lease_handle, nil
end

local function close(plan_store: plans.Store?, activation_store: activations.Store?, lease_handle: leases.Store?)
    if lease_handle then leases.close(lease_handle) end
    if activation_store then activations.close(activation_store) end
    if plan_store then plans.close(plan_store) end
end

local function request_identity(request: Object): (string?, string?, string?)
    return bounds.id(request.source_node), bounds.id(request.source_workspace), bounds.id(request.version)
end

local OPERATIONS: Set = {available = true, stage = true, list = true, activations = true, get = true, changes = true, revert = true, uninstall = true,
    review = true, select = true, prepare = true, step = true, status = true, recover = true,
    lease_propose = true, lease_grant = true, lease_list = true, lease_revoke = true}
local READS: Set = {available = true, list = true, activations = true, get = true, changes = true, status = true}
local MANAGES: Set = {stage = true, review = true, select = true}
local LEASES: Set = {lease_propose = true, lease_grant = true, lease_list = true, lease_revoke = true}

-- One delivery action per operation, so the public facade authenticates the
-- exact operation a caller asks for before any store opens.
function M.required_action(raw: unknown): string?
    local operation = bounds.id(raw)
    if not operation or not OPERATIONS[operation] then return nil end
    if LEASES[operation] then return "bee.gov.delivery.lease" end
    if READS[operation] then return "bee.gov.delivery.read" end
    if MANAGES[operation] then return "bee.gov.delivery.manage" end
    return "bee.gov.delivery.activate"
end

local function exact(request: Object, fields: {string}): string?
    local allowed = {"operation", "workspace_id"}
    for _, field in ipairs(fields) do allowed[#allowed + 1] = field end
    return bounds.fields(request, allowed)
end

-- The bee.app definition an activation's artifact declares, which is what a
-- person opens to use the installed application.
function M.application_of(bytes: unknown, digest: unknown): string?
    local entries = artifact.decode(bytes, digest)
    if not entries then return nil end
    return (workspace_applications.application(entries))
end

-- Each applied activation says which application it runs; one that cannot be
-- read says nothing.
local function annotate(store: activations.Store, listing: Result): Result
    local value = listing.ok and bounds.object(listing.value) or nil
    local rows = value and value.activations
    if type(rows) ~= "table" then return listing end
    for _, raw in ipairs(rows) do
        local row = bounds.object(raw)
        if row and row.intent_id ~= nil and row.intent_id == row.observed_intent_id then
            local read = activations.get(store, row.intent_id)
            local intent = read.ok and bounds.object(read.value) or nil
            if intent then row.application = M.application_of(intent.artifact_bytes, intent.artifact_digest) end
        end
    end
    return listing
end

local RECOVERY_ATTEMPTS = 4

-- The overlay owner an application of this workspace runs under: the one
-- holding a desired version, else the application's own owner.
local function application_owner(activation_store: activations.Store, workspace_id: string, source_workspace: string): string?
    local identity = workspace_applications.identity(workspace_id, source_workspace)
    if not identity then return nil end
    for _, candidate in ipairs({workspace_applications.prior_owner(workspace_id, source_workspace), identity.overlay_owner}) do
        if activations.desired(activation_store, candidate).ok then return candidate end
    end
    return identity.overlay_owner
end

-- A person's removal of an application they installed: the activation owner
-- records it under the person and empties the owner's registry overlay. The
-- saved data of its granted databases is left as it is.
local function uninstall_application(request: Object, workspace_id: string, actor_id: string,
    activation_store: activations.Store): Result
    if exact(request, {"source_workspace", "receipt_key"}) then return failure("INVALID", "uninstall has unknown fields") end
    local source_workspace, key = bounds.id(request.source_workspace), bounds.id(request.receipt_key)
    local overlay_owner = source_workspace and application_owner(activation_store, workspace_id, source_workspace) or nil
    if not source_workspace or not key or not overlay_owner then return failure("INVALID", "uninstall names no application") end
    return uninstall.uninstall({activations = activation_store, overlay_owner = overlay_owner, actor_id = actor_id,
        clear = function(): ({[string]: unknown}?, string?) return materializer.reconcile(overlay_owner, {}) end,
        cleared = function(): (boolean?, string?) return materializer.matches(overlay_owner, {}) end}, key)
end

type RevertMethods = {
    applied: (activations.Store, string) -> Result,
    revert_activation: (activations.Store, string, activations.Request) -> Result,
}

-- A person's own revert of an application to the version before it: the
-- activation store records it under the person, and the owner applies the
-- earlier version's definitions. Applied migrations stay; a revert that would
-- need a compensation plan is refused.
local function revert_application(request: Object, workspace_id: string, actor_id: string?,
    plan_store: plans.Store, activation_store: activations.Store, lease_handle: leases.Store): Result
    if exact(request, {"source_workspace", "receipt_key"}) then return failure("INVALID", "revert has unknown fields") end
    local source_workspace, key = bounds.id(request.source_workspace), bounds.id(request.receipt_key)
    local identity = source_workspace and workspace_applications.identity(workspace_id, source_workspace) or nil
    if not source_workspace or not key or not identity then return failure("INVALID", "revert names no application") end
    local overlay_owner = application_owner(activation_store, workspace_id, source_workspace)
    if not overlay_owner or not activations.desired(activation_store, overlay_owner).ok then
        return failure("NOT_FOUND", "this application is not installed here")
    end
    local desired = activations.desired(activation_store, overlay_owner)
    local current = desired.ok and bounds.object(desired.value) or nil
    local baseline_result = activations.baseline(activation_store, overlay_owner)
    local baseline = baseline_result.ok and bounds.object(baseline_result.value) or nil
    if not current then return desired end
    if not baseline then return failure("BLOCKED", baseline_result.message or "there is no earlier version to go back to") end
    local config, config_error = load()
    if not config then return failure("BLOCKED", config_error or "activation configuration is unavailable") end
    local current_source = bounds.id(current.source_node)
    local chosen = current_source and selected(config, workspace_id, current_source, source_workspace, activation_store) or nil
    if not chosen then return failure("BLOCKED", "activation profile is unavailable") end
    current.component, baseline.component = chosen.component, chosen.component
    local adapter: RevertMethods = {
        applied = function(store: activations.Store, component: string): Result return activations.applied(store, component) end,
        revert_activation = function(store: activations.Store, actor: string, input: activations.Request): Result
            return activations.revert_activation(store, actor, input)
        end,
    }
    local reverted = headless_revert.revert(adapter, activation_store, overlay_owner, current, baseline, key, actor_id)
    if not reverted.ok then return reverted end
    local restored = bounds.object(reverted.value)
    local restored_source = restored and bounds.id(restored.source_node) or nil
    local earlier = restored_source and selected(config, workspace_id, restored_source, source_workspace, activation_store) or nil
    if not earlier then return failure("BLOCKED", "activation profile for the earlier version is unavailable") end
    local configured = owner_config(config, earlier, plan_store, activation_store, lease_handle)
    if not configured.ok then return failure("BLOCKED", configured.error or "activation configuration is unavailable") end
    local result: Result = reverted
    for attempt = 1, RECOVERY_ATTEMPTS do
        result = owner.recover(configured.config, key .. "-recover-" .. tostring(attempt))
        local value = result.ok and bounds.object(result.value) or nil
        if not result.ok or (value and value.phase == "settled") then break end
    end
    return result
end

-- The host-selected vocabulary and the installed grant record of the profile's
-- application: a lease can only be proposed over something already installed.
local function installed_envelope(profile_value: Profile): (capability_model.Vocabulary?, {capability_model.Grant}?, string?)
    local identity = workspace_applications.identity(profile_value.workspace_id, profile_value.source_workspace)
    local prior_owner = workspace_applications.prior_owner(profile_value.workspace_id, profile_value.source_workspace)
    local uses_prior = prior_owner ~= nil and prior_owner == profile_value.overlay_owner
    if not identity or (identity.overlay_owner ~= profile_value.overlay_owner and not uses_prior)
        or identity.component ~= profile_value.component then
        return nil, nil, "activation profile is not a workspace application"
    end
    local catalog_entry, catalog_lookup_error = registry.get("bee.capability:catalog")
    if not catalog_entry then return nil, nil, "host capability catalog lookup failed: " .. tostring(catalog_lookup_error) end
    local vocabulary, catalog_error = capability_model.decode(catalog_entry)
    if not vocabulary then return nil, nil, catalog_error end
    local record_id = uses_prior and capability_grants.prior_record_id(profile_value.overlay_owner)
        or capability_grants.record_id(profile_value.overlay_owner)
    local raw = record_id and registry.get(record_id) or nil
    if not raw then return nil, nil, "no installed grant record to lease over" end
    local decoded, decode_error = capability_grants.decode(raw, profile_value.overlay_owner,
        profile_value.workspace_id, (bounds.object(raw) and bounds.object((bounds.object(raw)).data) or {}).application, vocabulary)
    if not decoded then return nil, nil, decode_error end
    local live, live_error = capability_grants.live(decoded, function(id: string): unknown return registry.get(id) end)
    if not live then return nil, nil, live_error end
    return vocabulary, decoded.capabilities, nil
end

local function lease_request(operation: string, request: Object, node_id: string, workspace_id: string,
    actor_id: string, activation_store: activations.Store, lease_handle: leases.Store): Result
    local source_node, source_workspace = bounds.id(request.source_node), bounds.id(request.source_workspace)
    local fields = operation == "lease_propose"
        and {"source_node", "source_workspace", "extras", "ttl_seconds", "max_applies", "idempotency_key"}
        or {"source_node", "source_workspace", "approval_id", "idempotency_key"}
    if exact(request, fields) then return failure("INVALID", operation .. " request is invalid") end
    if not source_node or not source_workspace then return failure("INVALID", operation .. " identity is invalid") end
    local config, config_error = load()
    if not config then return failure("BLOCKED", config_error or "activation configuration is unavailable") end
    local chosen, profile_error = selected(config, workspace_id, source_node, source_workspace, activation_store)
    if not chosen then return failure("BLOCKED", profile_error or "activation profile is unavailable") end
    local vocabulary, installed, installed_error = installed_envelope(chosen)
    if not vocabulary or not installed then return failure("BLOCKED", installed_error or "installed grants are unavailable") end
    local executor, executor_error = approval_executor()
    if not executor then return failure("UNAVAILABLE", executor_error or "approval executor is unavailable") end
    local key = bounds.id(request.idempotency_key)
    if not key then return failure("INVALID", "idempotency_key is required") end
    if operation == "lease_propose" then
        return lease_grants.propose(executor, vocabulary, installed, chosen, workspace_id, request, key)
    end
    return lease_grants.grant(executor, lease_handle, vocabulary, chosen, workspace_id, actor_id, request, key)
end

function M.call(raw: unknown): Result
    local request = bounds.object(raw)
    local operation = request and bounds.id(request.operation) or nil
    if not request or not operation or not OPERATIONS[operation] then
        return failure("INVALID", "destination request operation is invalid")
    end
    local node_id, actor_id, denied = authorize(request.workspace_id)
    if not node_id or not actor_id then return assert(denied) end
    local workspace_id = bounds.id(request.workspace_id)
    if not workspace_id then return failure("INVALID", "workspace_id is invalid") end
    local plan_store, activation_store, lease_handle, open_error = stores(node_id, workspace_id)
    if not plan_store or not activation_store or not lease_handle then return failure("UNAVAILABLE", open_error or "open destination stores") end
    local result: Result
    if operation == "available" then
        if exact(request, {}) then
            result = failure("INVALID", "available has unknown fields")
        else
            local config, config_error = load()
            local replica_store, replica_error = replicas.open()
            if not config or not replica_store then
                result = failure("UNAVAILABLE", config_error or replica_error or "open replica store")
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
                        for _, owner_raw in ipairs(names) do
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
                    for _, raw_descriptor in ipairs(rows) do
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
                local admitted_source: string = source_owner
                local admitted_feed: string = assert(feed)
                local admitted_key: string = version_key
                local admitted_digest: string = descriptor_digest
                local admitted_receipt: string = idempotency_key
                local config, config_error = load()
                local replica_store, replica_error = replicas.open()
                if not config or not replica_store then
                    result = failure("UNAVAILABLE", config_error or replica_error or "open replica store")
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
                            local resolved = destination_resolver(config, chosen, node_id, workspace_id, activation_store)
                            result = destination.stage_replica(plan_store, replica_store, actor_id,
                                {source_owner = admitted_source, feed = admitted_feed, version_key = admitted_key,
                                    descriptor_digest = admitted_digest, idempotency_key = admitted_receipt},
                                resolved, chosen.component)
                        end
                    end
                    replicas.close(replica_store)
                end
            end
        end
    elseif operation == "list" then
        if exact(request, {}) then result = failure("INVALID", "list has unknown fields")
        else result = plans.call(plan_store, actor_id, {operation = "list"}) end
    elseif operation == "activations" then
        if exact(request, {}) then result = failure("INVALID", "activations has unknown fields")
        else result = annotate(activation_store, activations.listing(activation_store)) end
    elseif operation == "uninstall" then
        result = uninstall_application(request, workspace_id, actor_id, activation_store)
    elseif operation == "revert" then
        result = revert_application(request, workspace_id, actor_id, plan_store, activation_store, lease_handle)
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
    elseif operation == "lease_list" then
        if exact(request, {"history"}) or (request.history ~= nil and type(request.history) ~= "boolean") then
            result = failure("INVALID", "lease_list takes only a history flag")
        else result = leases.list(lease_handle, nil, request.history == true) end
    elseif operation == "lease_revoke" then
        if exact(request, {"lease_id", "expected_revision", "idempotency_key"}) then
            result = failure("INVALID", "lease_revoke has unknown fields")
        else
            result = leases.call(lease_handle, actor_id, {operation = "revoke", lease_id = request.lease_id,
                expected_revision = request.expected_revision, idempotency_key = request.idempotency_key,
                revoked_by = actor_id})
        end
    elseif operation == "lease_propose" or operation == "lease_grant" then
        result = lease_request(operation, request, node_id, workspace_id, actor_id, activation_store, lease_handle)
    elseif operation == "status" then
        if exact(request, {"intent_id"}) then result = failure("INVALID", "activation status has unknown fields")
        else result = activations.get(activation_store, request.intent_id) end
    else
        local operation_fields: {[string]: {string}} = {
            prepare = {"source_node", "source_workspace", "version", "intent_id", "receipt_key"},
            step = {"intent_id", "receipt_key"},
            recover = {"source_node", "source_workspace", "receipt_key"}}
        if exact(request, operation_fields[operation]) then
            close(plan_store, activation_store, lease_handle)
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
        local composed: owner.Config? = nil
        local compose_error: string? = nil
        if chosen and config then
            local configured = owner_config(config, chosen, plan_store, activation_store, lease_handle)
            if configured.ok then composed = configured.config else compose_error = configured.error end
        end
        if result == nil then
            if not config or not chosen or not composed then
                result = failure("BLOCKED", config_error or profile_error or compose_error or "activation configuration is unavailable")
            elseif operation == "prepare" then
                result = owner.prepare(composed, {source_node = request.source_node,
                    source_workspace = request.source_workspace, version = request.version,
                    intent_id = request.intent_id, receipt_key = request.receipt_key})
            elseif operation == "step" then
                result = owner.step(composed, request.intent_id, request.receipt_key)
            elseif operation == "recover" then
                result = owner.recover(composed, request.receipt_key)
            else
                result = failure("INVALID", "unsupported destination operation")
            end
        end
    end
    close(plan_store, activation_store, lease_handle)
    return result
end

-- revert goes back to the version before the one an application runs, as the
-- named person, or as the recovery actor when none is named. It opens the
-- node's own stores for the workspace.
function M.revert(workspace_id: string, source_workspace: string, receipt_key: string, actor_id: string?): Result
    local config, config_error = load()
    if not config then return failure("BLOCKED", config_error or "activation configuration is unavailable") end
    local plan_store, activation_store, lease_handle, open_error = stores(config.node_id, workspace_id)
    if not plan_store or not activation_store or not lease_handle then return failure("UNAVAILABLE", open_error or "open destination stores") end
    local result = revert_application({operation = "revert", workspace_id = workspace_id,
        source_workspace = source_workspace, receipt_key = receipt_key}, workspace_id, actor_id,
        plan_store, activation_store, lease_handle)
    close(plan_store, activation_store, lease_handle)
    return result
end

-- Apply one approved activation: the approval names the workspace and the
-- source it activates, the activation owner consumes it and carries the intent
-- bound to it until it settles. The approval is the person's; this only
-- executes it.
function M.apply_approved(raw: unknown): Result
    local effect = bounds.object(raw)
    local approval_id = effect and bounds.id(effect.approval_id) or nil
    local workspace_id = effect and bounds.id(effect.workspace_id) or nil
    local proposal = effect and bounds.object(effect.proposal) or nil
    local payload = proposal and bounds.object(proposal.payload) or nil
    local source_node = payload and bounds.id(payload.source_node) or nil
    local source_workspace = payload and bounds.id(payload.source_workspace) or nil
    if not approval_id or not workspace_id or not source_node or not source_workspace then
        return failure("INVALID", "approved activation is malformed")
    end
    local config, config_error = load()
    if not config then return failure("BLOCKED", config_error or "activation configuration is unavailable") end
    local plan_store, activation_store, lease_handle, open_error = stores(config.node_id, workspace_id)
    if not plan_store or not activation_store or not lease_handle then return failure("UNAVAILABLE", open_error or "open destination stores") end
    local result: Result
    local bound = activations.bound_to(activation_store, approval_id)
    local intent = bound.ok and bounds.object(bound.value) or nil
    local intent_id = intent and bounds.id(intent.intent_id) or nil
    if not intent_id then
        result = bound.ok and failure("INTERNAL", "approved activation intent is malformed") or bound
    else
        local chosen, profile_error = selected(config, workspace_id, source_node, source_workspace, activation_store)
        if not chosen then
            result = failure("BLOCKED", profile_error or "activation profile is unavailable")
        else
            local configured = owner_config(config, chosen, plan_store, activation_store, lease_handle)
            if not configured.ok then result = failure("BLOCKED", configured.error or "activation configuration is unavailable")
            else
                result = owner.advance(configured.config, intent_id, "approved-" .. approval_id)
                local settled = result.ok and bounds.object(result.value) or nil
                if settled and settled.outcome == "applied" then
                    local sent, send_error = events.send(ATTENTION, "application.applied", workspace_id, {component = chosen.component})
                    if not sent then logger:warn("Applied application not announced", {component = chosen.component, error = tostring(send_error)}) end
                end
            end
        end
    end
    close(plan_store, activation_store, lease_handle)
    return result
end

-- Boot recovery follows only already-authorized desired intents. It never
-- reviews, selects or creates an approval request. A slot whose source the
-- host no longer selects for that owner stays unrestored.
-- Governance refuses a restoration whose approval no longer covers the host
-- state; that overlay stays unrestored and its intent stays for the person to
-- review again. Only such refusals let recovery continue.
local REFUSALS: {[string]: boolean} = {CONFLICT = true, DENIED = true}

function M.recover_all(): (boolean, string?, {string}?)
    local config, config_error = load()
    if not config then return false, config_error end
    local node_id = config.node_id
    local resource, resource_error = resources.database()
    if not resource then return false, resource_error end
    local listed = activations.desired_slots(resource, node_id)
    if not listed.ok then return false, listed.message end
    local value = bounds.object(listed.value)
    local slots = value and value.slots
    local refused: {string} = {}
    if type(slots) ~= "table" then return false, "desired activation slots are malformed" end
    for _, raw_slot in ipairs(slots) do
        local slot = bounds.object(raw_slot)
        local workspace_id = slot and bounds.id(slot.workspace_id) or nil
        local overlay_owner = slot and bounds.id(slot.overlay_owner) or nil
        if not workspace_id or not overlay_owner then return false, "desired activation slot is malformed" end
        local plan_store, activation_store, lease_handle, open_error = stores(node_id, workspace_id)
        if not plan_store or not activation_store or not lease_handle then return false, open_error or "open destination stores" end
        for attempt = 1, 4 do
            local desired = activations.desired(activation_store, overlay_owner)
            if not desired.ok then
                close(plan_store, activation_store, lease_handle)
                if desired.code == "NOT_FOUND" then break end
                return false, desired.message
            end
            local intent = bounds.object(desired.value)
            local source_node = intent and bounds.id(intent.source_node) or nil
            local source_workspace = intent and bounds.id(intent.source_workspace) or nil
            if not intent or not source_node or not source_workspace then
                close(plan_store, activation_store, lease_handle)
                return false, "desired activation intent is malformed"
            end
            local chosen = selected(config, workspace_id, source_node, source_workspace, activation_store)
            if not chosen or chosen.overlay_owner ~= overlay_owner then break end
            local configured = owner_config(config, chosen, plan_store, activation_store, lease_handle)
            if not configured.ok then
                close(plan_store, activation_store, lease_handle)
                return false, configured.error
            end
            local receipt_bytes = canonical.encode({schema_revision = "bee.governance-recovery@1",
                workspace_id = workspace_id, intent_id = intent.intent_id, revision = intent.revision, attempt = attempt})
            local receipt = receipt_bytes and hash.sha256(receipt_bytes) or nil
            if not receipt then close(plan_store, activation_store, lease_handle); return false, "measure activation recovery" end
            local recovered = owner.recover(configured.config, receipt)
            if not recovered.ok and REFUSALS[recovered.code] then
                refused[#refused + 1] = overlay_owner .. ": " .. tostring(recovered.message)
                break
            end
            if not recovered.ok then close(plan_store, activation_store, lease_handle); return false, recovered.message end
            local recovered_value = bounds.object(recovered.value)
            if recovered_value and recovered_value.phase == "settled" then break end
        end
        close(plan_store, activation_store, lease_handle)
    end
    return true, nil, refused
end

return M
