-- MIT. Destination-owned composition for reviewed application delivery.
-- Replicas and Hub metadata supply bytes. This service selects host policy,
-- checks the local caller, owns approval consumption and applies one overlay.
local registry = require("registry")
local security = require("security")
local system = require("system")
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
local hub_package = require("hub_package")
local package_requirements = require("package_requirements")
local delivery = require("delivery")
local destination = require("destination")
local preflight = require("preflight")
local materializer = require("materializer")
local state_guard = require("state_guard")
local headless_revert = require("headless_revert")
local uninstall = require("activation_uninstall")
local artifact = require("artifact")
local activation_profiles = require("activation_profiles")
local capability_grants = require("capability_grants")
local capability_model = require("capability_model")
local capability_files = require("capability_files")
local workspace_applications = require("workspace_applications")

local follows = require("follow_store")
local follower = require("follow_source")
local follow_wake = require("follow_wake")

local M = {}
local part_destination_inspection = require("part_destination_inspection")
type Object = part_destination_inspection.Object
type Set = part_destination_inspection.Set
local load = part_destination_inspection.load
local selected = part_destination_inspection.selected
local destination_resolver = part_destination_inspection.destination_resolver
type Result = part_destination_inspection.Result
local failure = part_destination_inspection.failure
local plan_changes = part_destination_inspection.plan_changes
M.application_of = part_destination_inspection.application_of
local annotate = part_destination_inspection.annotate
local part_destination_policy = require("part_destination_policy")
type DatabaseBinding = part_destination_policy.DatabaseBinding
type DatabaseBindings = part_destination_policy.DatabaseBindings
type PolicyIds = part_destination_policy.PolicyIds
type Profile = part_destination_policy.Profile
type Configuration = part_destination_policy.Configuration
type ResolverRoot = part_destination_policy.ResolverRoot
type ResolverPolicy = part_destination_policy.ResolverPolicy
type OwnerConfigResult = part_destination_policy.OwnerConfigResult
local applied_database_evidence = part_destination_policy.applied_database_evidence
M.configuration = part_destination_policy.configuration
M.super_edit_admission = part_destination_policy.super_edit_admission
local approval_executor = part_destination_policy.approval_executor
M.driver_bindings = part_destination_policy.driver_bindings
M.driver_logins = part_destination_policy.driver_logins
local owner_config = part_destination_policy.owner_config
M.BACKEND = "bee.gov.binding:destination_backend_call"
M.EXECUTE = "bee.gov.delivery.execute"
M.SCOPE = "bee.gov.security:destination_execution_scope"
local ATTENTION = "bee.attention"
M.applied_database_evidence = applied_database_evidence

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

local OPERATIONS: Set = {available = true, preflight = true, stage = true, stage_hub = true, list = true, activations = true, get = true, changes = true, revert = true, uninstall = true,
    review = true, select = true, prepare = true, step = true, status = true, recover = true,
    follow = true, lease_propose = true, lease_grant = true, lease_list = true, lease_revoke = true}
local READS: Set = {available = true, list = true, activations = true, get = true, changes = true, status = true}
local MANAGES: Set = {preflight = true, stage = true, stage_hub = true, review = true, select = true}
local LEASES: Set = {lease_propose = true, lease_grant = true, lease_list = true, lease_revoke = true}

-- One delivery action per operation, so the public facade authenticates the
-- exact operation a caller asks for before any store opens.
function M.required_action(raw: unknown): string?
    local operation = bounds.id(raw)
    if not operation or not OPERATIONS[operation] then return nil end
    if operation == "follow" then return "bee.gov.delivery.follow" end
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

local RECOVERY_ATTEMPTS = 4

-- The overlay owner an application of this workspace runs under: the one
-- holding a desired version, else the application's own owner.
local function application_owner(activation_store: activations.Store, workspace_id: string, source_workspace: string): string?
    local identity = activation_profiles.hub_identity(workspace_id, source_workspace)
        or workspace_applications.identity(workspace_id, source_workspace, true)
    if not identity then return nil end
    for _, candidate in ipairs({workspace_applications.prior_owner(workspace_id, source_workspace), identity.overlay_owner}) do
        if activations.desired(activation_store, candidate).ok then return candidate end
    end
    return identity.overlay_owner
end

-- A person's removal of an application they installed: the activation owner
-- records it under the person and takes the application off its registry
-- overlay. Its databases stay registered, with no grant reaching them, so the
-- data and its migration ledger are there for the next install.
local function uninstall_application(request: Object, workspace_id: string, actor_id: string,
    activation_store: activations.Store): Result
    if exact(request, {"source_workspace", "receipt_key", "expected_intent_id"}) then return failure("INVALID", "uninstall has unknown fields") end
    local source_workspace, key = bounds.id(request.source_workspace), bounds.id(request.receipt_key)
    local overlay_owner = source_workspace and application_owner(activation_store, workspace_id, source_workspace) or nil
    if not source_workspace or not key or not overlay_owner then return failure("INVALID", "uninstall names no application") end
    local paused = follows.disable(activation_store, source_workspace, "off")
    if not paused.ok then return paused end
    return uninstall.uninstall({activations = activation_store, overlay_owner = overlay_owner, actor_id = actor_id,
        clear = function(): ({[string]: unknown}?, string?) return materializer.retain_data(overlay_owner) end,
        cleared = function(): (boolean?, string?) return materializer.retains_data(overlay_owner) end}, key, request.expected_intent_id)
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
    if exact(request, {"source_workspace", "receipt_key", "expected_intent_id"}) then return failure("INVALID", "revert has unknown fields") end
    local source_workspace, key = bounds.id(request.source_workspace), bounds.id(request.receipt_key)
    local identity = source_workspace and (activation_profiles.hub_identity(workspace_id, source_workspace)
        or workspace_applications.identity(workspace_id, source_workspace, true)) or nil
    if not source_workspace or not key or not identity then return failure("INVALID", "revert names no application") end
    local overlay_owner = application_owner(activation_store, workspace_id, source_workspace)
    if not overlay_owner or not activations.desired(activation_store, overlay_owner).ok then
        return failure("NOT_FOUND", "this application is not installed here")
    end
    local desired = activations.desired(activation_store, overlay_owner)
    local current = desired.ok and bounds.object(desired.value) or nil
    if request.expected_intent_id ~= nil and (not current or request.expected_intent_id ~= current.intent_id) then
        return failure("CONFLICT", "installed activation differs from the confirmed revert")
    end
    local baseline_result = activations.baseline(activation_store, overlay_owner)
    local baseline = baseline_result.ok and bounds.object(baseline_result.value) or nil
    if not current then return desired end
    if not baseline then return failure("BLOCKED", baseline_result.message or "there is no earlier version to go back to") end
    local config, config_error = load()
    if not config then return failure("BLOCKED", config_error or "activation configuration is unavailable") end
    local current_source = bounds.id(current.source_node)
    local chosen = current_source and selected(config, workspace_id, current_source, source_workspace, activation_store) or nil
    if not chosen then return failure("BLOCKED", "activation profile is unavailable") end
    local pinned = follows.disable(activation_store, source_workspace, "pinned")
    if not pinned.ok then return pinned end
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
    local identity = activation_profiles.hub_identity(profile_value.workspace_id, profile_value.source_workspace)
        or workspace_applications.identity(profile_value.workspace_id, profile_value.source_workspace, true)
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

local function follow_consent(request: Object, config: Configuration, workspace_id: string,
    activation_store: activations.Store, intent: Object?): Result
    local source_node = intent and bounds.id(intent.source_node) or bounds.id(request.source_node)
    local source_workspace = intent and bounds.id(intent.source_workspace) or bounds.id(request.source_workspace)
    local requested_mode = request.mode or (request.follow_source == true and "following" or "off")
    if not source_node or not source_workspace or source_node == config.node_id then return failure("INVALID", "Choose an application received from another hive bee") end
    local chosen, profile_error = selected(config, workspace_id, source_node, source_workspace, activation_store)
    if not chosen or (request.component ~= nil and request.component ~= chosen.component) then
        return failure("BLOCKED", profile_error or "Source application is not admitted")
    end
    if not intent then
        local desired = activations.desired(activation_store, chosen.overlay_owner)
        if not desired.ok then return desired end
        intent = bounds.object(desired.value)
        if not intent or intent.source_node ~= source_node or intent.source_workspace ~= source_workspace then return failure("CONFLICT", "Installed source identity changed") end
    end
    local version, artifact_digest = bounds.id(intent.version), bounds.text(intent.artifact_digest, 64)
    if not version or not artifact_digest then return failure("INTERNAL", "Installed application identity is missing") end
    local result = follows.consent(activation_store, {source_node = source_node, source_workspace = source_workspace,
        component = chosen.component}, requested_mode, version, artifact_digest)
    if result.ok then follow_wake.signal() end
    return result
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
    elseif operation == "stage_hub" then
        local component, version = bounds.id(request.component), bounds.id(request.version)
        local key, measured = bounds.id(request.idempotency_key), bounds.text(request.artifact_digest, 64)
        if exact(request, {"component", "version", "parameters", "artifact_digest", "idempotency_key"})
            or not component or not version or not key or not measured then
            result = failure("INVALID", "Hub stage requires an exact measured package")
        else
            local parameters, parameter_error = package_requirements.parameters(request.parameters or {})
            local expanded, expand_error
            if parameters then expanded, expand_error = hub_package.read({component = component, version = version, parameters = parameters}) end
            local config, config_error = load()
            local source_workspace = "hub:" .. component
            local chosen, profile_error = config and selected(config, workspace_id, node_id,
                source_workspace, activation_store) or nil
            if not expanded then result = failure("BLOCKED", parameter_error or expand_error or "Hub package is unavailable")
            elseif not expanded.governed then result = failure("INVALID", "library packages use Hub publication")
            elseif expanded.artifact.digest ~= measured then result = failure("BLOCKED", "Hub artifact differs from the measured package")
            elseif not chosen then result = failure("BLOCKED", profile_error or config_error or "Hub application is not admitted")
            else
                local resolved = destination_resolver(assert(config), chosen, node_id, workspace_id, activation_store)
                result = destination.stage_artifact(plan_store, actor_id, {source_node = node_id,
                    source_workspace = source_workspace, version = version, artifact = expanded.artifact,
                    idempotency_key = key}, resolved)
            end
        end
    elseif operation == "stage" or operation == "preflight" then
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
                                resolved, chosen.component, operation == "preflight")
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
    elseif operation == "follow" then
        local config, config_error = load()
        if exact(request, {"source_node", "source_workspace", "component", "mode"}) then result = failure("INVALID", "Following request is invalid")
        elseif not config then result = failure("UNAVAILABLE", config_error or "Following configuration is unavailable")
        else result = follow_consent(request, config, workspace_id, activation_store, nil) end
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
            prepare = {"source_node", "source_workspace", "version", "intent_id", "receipt_key", "follow_source"},
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
                composed.requesting_session = actor_id:match("^bs:") and actor_id or nil
                if request.follow_source ~= nil and type(request.follow_source) ~= "boolean" then
                    close(plan_store, activation_store, lease_handle); return failure("INVALID", "follow_source is a destination-local consent flag")
                end
                if request.follow_source == true and source_node == node_id then
                    close(plan_store, activation_store, lease_handle); return failure("INVALID", "Following requires another hive bee")
                end
                result = owner.prepare(composed, {source_node = request.source_node,
                    source_workspace = request.source_workspace, version = request.version,
                    intent_id = request.intent_id, receipt_key = request.receipt_key})
                if result.ok and request.follow_source ~= nil then
                    local consent = follow_consent(request, config, workspace_id, activation_store, bounds.object(result.value))
                    if not consent.ok then result = consent end
                end
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
-- close_ended settles the activation whose approval request ended without
-- approval, so its application is ready and can be installed
-- again; an approval no activation is bound to only leaves the queue.
function M.close_ended(raw: unknown): Result
    local ended = bounds.object(raw)
    local approval_id = ended and bounds.id(ended.approval_id) or nil
    local workspace_id = ended and bounds.id(ended.workspace_id) or nil
    local proposal_digest = ended and bounds.id(ended.proposal_digest) or nil
    local proposal = ended and bounds.object(ended.proposal) or nil
    local payload = proposal and bounds.object(proposal.payload) or nil
    local source_node = payload and bounds.id(payload.source_node) or nil
    local source_workspace = payload and bounds.id(payload.source_workspace) or nil
    if not approval_id or not workspace_id or not proposal_digest or not source_node or not source_workspace then
        return failure("INVALID", "ended activation is malformed")
    end
    local config, config_error = load()
    if not config then return failure("BLOCKED", config_error or "activation configuration is unavailable") end
    local plan_store, activation_store, lease_handle, open_error = stores(config.node_id, workspace_id)
    if not plan_store or not activation_store or not lease_handle then return failure("UNAVAILABLE", open_error or "open destination stores") end
    local result: Result
    local bound = activations.bound_to(activation_store, approval_id)
    local intent = bound.ok and bounds.object(bound.value) or nil
    local intent_id = intent and bounds.id(intent.intent_id) or nil
    if not bound.ok and bound.code == "NOT_FOUND" then
        local executor, executor_error = approval_executor()
        if not executor then
            result = failure("BLOCKED", executor_error or "approval executor is unavailable")
        else
            local closed, close_error = executor:call("bee.approvals.binding:effect",
                {operation = "complete", approval_id = approval_id, proposal_digest = proposal_digest, result = {closed = true}})
            local reply = bounds.object(closed)
            result = (reply and reply.ok == true) and transaction.success({approval_id = approval_id}, false)
                or failure("UNAVAILABLE", tostring(close_error or (reply and bounds.object(reply.error) or {}).message or "close ended activation"))
        end
    elseif not intent_id then
        result = bound.ok and failure("INTERNAL", "ended activation intent is malformed") or bound
    else
        local chosen, profile_error = selected(config, workspace_id, source_node, source_workspace, activation_store)
        if not chosen then
            result = failure("BLOCKED", profile_error or "activation profile is unavailable")
        else
            local configured = owner_config(config, chosen, plan_store, activation_store, lease_handle)
            if not configured.ok then result = failure("BLOCKED", configured.error or "activation configuration is unavailable")
            else result = owner.close(configured.config, intent_id, "ended-" .. approval_id) end
        end
    end
    close(plan_store, activation_store, lease_handle)
    return result
end

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
    local applied_component: string? = nil
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
                local following = follows.get(activation_store, {source_node = source_node, source_workspace = source_workspace, component = chosen.component})
                local state = following.ok and bounds.object(following.value) or nil
                if not following.ok then close(plan_store, activation_store, lease_handle); return following end
                if state and state.intent_id == intent_id then
                    following = follower.observe_current(assert(configured.config), {source_node = source_node,
                        source_workspace = source_workspace, component = chosen.component})
                    if not following.ok then close(plan_store, activation_store, lease_handle); return following end
                    state = bounds.object(following.value)
                end
                if state and state.intent_id == intent_id and state.version ~= intent.version then
                    close(plan_store, activation_store, lease_handle); return failure("ROLLBACK", "A newer installed version supersedes this source update")
                end
                if state and state.pending ~= nil and state.intent_id == intent_id and state.mode ~= "following" then
                    close(plan_store, activation_store, lease_handle); return failure("PAUSED", "Following is paused or pinned")
                end
                result = owner.advance(configured.config, intent_id, "approved-" .. approval_id)
                local settled = result.ok and bounds.object(result.value) or nil
                if settled and settled.outcome == "applied" then
                    applied_component = chosen.component
                end
            end
        end
    end
    local settled = bounds.object(result.value)
    if settled and settled.phase == "settled" then
        local executor, executor_error = approval_executor()
        if not executor then result = failure("UNAVAILABLE", executor_error or "approval executor is unavailable")
        else
            local raw_complete, complete_error = executor:call("bee.approvals.binding:effect", {operation = "complete",
                approval_id = approval_id, proposal_digest = effect.proposal_digest,
                effect_key = settled.consumed_effect_key, result = {ok = settled.outcome == "applied", outcome = settled.outcome,
                    intent_id = settled.intent_id, error = settled.outcome ~= "applied" and settled.diagnostics or nil},
                state = settled.outcome == "uncertain" and "uncertain" or (settled.outcome == "applied" and "succeeded" or "failed")})
            local completed = bounds.object(raw_complete)
            if complete_error or not completed or completed.ok ~= true then result = failure("UNAVAILABLE", "complete activation effect receipt") end
            if completed and completed.ok == true and completed.replayed ~= true and settled.outcome ~= "uncertain" then
                if applied_component then
                    local sent, send_error = events.send(ATTENTION, "application.applied", workspace_id, {component = applied_component, approval_id = approval_id})
                    if not sent then logger:warn("Applied application not announced", {component = applied_component, error = tostring(send_error)}) end
                end
                follow_wake.signal()
            end
        end
    end
    close(plan_store, activation_store, lease_handle)
    return result
end

-- Boot recovery follows only already-authorized desired intents. It never
-- reviews, selects or creates an approval request. A slot whose source the
-- host does not select for that owner stays unrestored.
-- Governance refuses a restoration whose approval does not cover the host
-- state; that overlay stays unrestored and its intent stays for the person to
-- review again. Only such refusals let recovery continue.
local REFUSALS: {[string]: boolean} = {CONFLICT = true, DENIED = true}

-- An application database the host provisioned is registered only in its
-- owner's process-local overlay, while its data and migration ledger outlive
-- the process. Boot registers every such database applied migrations wrote
-- again before anything reads its ledger, whether its application is
-- installed, went back, or was removed.
local function restore_databases(resource: string, node_id: string): string?
    local listed = activations.applied_databases(resource, node_id)
    local value = listed.ok and bounds.object(listed.value) or nil
    local rows = value and bounds.dense_list(value.databases, 1024, "applied migration databases") or nil
    if not rows then return listed.message or "applied migration databases are malformed" end
    local by_owner: {[string]: {Object}} = {}
    local schemas: {[string]: {string}} = {}
    local owners: {string} = {}
    for _, raw in ipairs(rows) do
        local row = assert(bounds.object(raw))
        local owner_id, target, database_id = tostring(row.overlay_owner), tostring(row.target_db), tostring(row.database_id)
        if database_id:sub(1, #capability_files.DATABASE_PREFIX) == capability_files.DATABASE_PREFIX then
            local database, database_error = capability_files.database(owner_id, target)
            if not database then return database_error end
            if database.id ~= database_id then
                return "applied database " .. database_id .. " is not the one its owner provisions for " .. target
            end
            local ids = assert(bounds.dense_list(row.migrations, 10000, "application migrations"))
            schemas[database_id] = schemas[database_id] or {}
            for _, migration_id in ipairs(ids) do schemas[database_id][#schemas[database_id] + 1] = assert(bounds.id(migration_id)) end
            if not by_owner[owner_id] then by_owner[owner_id], owners[#owners + 1] = {}, owner_id end
            local list = by_owner[owner_id]
            list[#list + 1] = database
        end
    end
    for _, owner_id in ipairs(owners) do
        local provisioned = {databases = by_owner[owner_id], policies = {}}
        local present, present_error = materializer.provides(owner_id, provisioned)
        if present == nil then return present_error end
        if not present then
            local provided, provide_error = materializer.provide(owner_id, provisioned)
            if not provided then return "restore application databases of " .. owner_id .. ": " .. tostring(provide_error) end
        end
        for _, database in ipairs(provisioned.databases) do
            local prepared, prepare_error = state_guard.prepare(assert(bounds.id(database.id)), schemas[assert(bounds.id(database.id))])
            if not prepared then return tostring(prepare_error) end
        end
    end
    return nil
end

function M.recover_all(): (boolean, string?, {string}?)
    local config, config_error = load()
    if not config then return false, config_error end
    local node_id = config.node_id
    local resource, resource_error = resources.database()
    if not resource then return false, resource_error end
    local databases_error = restore_databases(resource, node_id)
    if databases_error then return false, databases_error end
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

function M.following_pending(): boolean
    local config, config_error = load()
    local resource, resource_error = resources.database()
    if not config or not resource then error(config_error or resource_error or "Following configuration is unavailable") end
    local listing = follows.list(resource, config.node_id)
    if not listing.ok then error(listing.message) end
    local listed = assert(bounds.object(listing.value))
    for _, raw in ipairs(assert(bounds.array(listed.items, 1024))) do
        local item = bounds.object(raw)
        local state = item and bounds.object(item.state)
        if state and state.mode == "following" then return true end
    end
    return false
end

function M.follow_all(): Result
    local config, config_error = load()
    local resource, resource_error = resources.database()
    if not config or not resource then return failure("UNAVAILABLE", config_error or resource_error or "Following configuration is unavailable") end
    local listing = follows.list(resource, config.node_id)
    if not listing.ok then return listing end
    local listed = bounds.object(listing.value)
    local items = listed and bounds.array(listed.items, 1024) or nil
    if not items then return failure("INTERNAL", "Following ledger is malformed") end
    local replica_store, open_error = replicas.open()
    if not replica_store then return failure("UNAVAILABLE", open_error or "Open source replicas") end
    local outcomes: {Object} = {}
    local retry = false
    for _, raw in ipairs(items) do
        local item = bounds.object(raw)
        local state = item and bounds.object(item.state) or nil
        local workspace_id = item and bounds.id(item.workspace_id) or nil
        local source_node = state and bounds.id(state.source_node) or nil
        local source_workspace = state and bounds.id(state.source_workspace) or nil
        local component = state and bounds.id(state.component) or nil
        local cursor = state and bounds.count(state.cursor) or nil
        if state and workspace_id and source_node and source_workspace and component and cursor and state.mode == "following" then
            local plan_store, activation_store, lease_handle, store_error = stores(config.node_id, workspace_id)
            if not plan_store or not activation_store or not lease_handle then replicas.close(replica_store); return failure("UNAVAILABLE", store_error or "Open following stores") end
            local chosen, profile_error = selected(config, workspace_id, source_node, source_workspace, activation_store)
            local configured = chosen and owner_config(config, chosen, plan_store, activation_store, lease_handle) or nil
            if not chosen or chosen.component ~= component or not configured or not configured.ok then
                outcomes[#outcomes + 1] = {workspace_id = workspace_id, source_node = source_node, component = component,
                    ok = false, message = profile_error or "Source application is no longer admitted"}
            else
                local composed = assert(configured.config)
                local publications: {Object} = {}
                local desired = owner.desired(composed)
                local working = desired.ok and bounds.object(desired.value) or nil
                local observed_id = working and bounds.id(working.observed_intent_id) or nil
                local observed = observed_id and activations.get(activation_store, observed_id) or nil
                local installed_intent = observed and observed.ok and bounds.object(observed.value) or nil
                local installed = working and working.observed_outcome == "applied" and installed_intent ~= nil
                if installed then
                    local advanced = follower.observe_current(composed, {source_node = source_node,
                        source_workspace = source_workspace, component = component})
                    if not advanced.ok then close(plan_store, activation_store, lease_handle); replicas.close(replica_store); return advanced end
                end
                local available_slot = state.pending ~= nil or (working and working.phase == "settled" and working.outcome == "applied")
                local pending = bounds.object(state.pending)
                if pending then publications[1] = {descriptor = pending, cursor = cursor}
                elseif installed and available_slot then
                    local available = replicas.publications(replica_store, source_node, delivery.FEED, cursor, component, source_workspace)
                    local value = available.ok and bounds.object(available.value) or nil
                    local rows = value and bounds.array(value.items, 128) or nil
                    if not rows then close(plan_store, activation_store, lease_handle); replicas.close(replica_store); return available.ok and failure("INTERNAL", "Source publications are malformed") or available end
                    if #rows == 128 then follow_wake.signal() end
                    for _, raw_publication in ipairs(rows) do
                        local publication = bounds.object(raw_publication)
                        local descriptor = publication and bounds.object(publication.descriptor) or nil
                        local manifest = descriptor and bounds.object(descriptor.manifest) or nil
                        if publication and descriptor and manifest and descriptor.object_id == component and manifest.source_workspace == source_workspace then
                            publications[#publications + 1] = publication
                        end
                    end
                end
                for _, publication in ipairs(publications) do
                    local descriptor = bounds.object(publication.descriptor)
                    local key = descriptor and bounds.id(descriptor.key) or nil
                    local measured = descriptor and bounds.text(descriptor.digest, 64) or nil
                    local sequence = bounds.count(publication.cursor)
                    if not descriptor or not key or not measured or not sequence then break end
                    local replicated = replicas.read(replica_store, {source_owner = source_node, feed = delivery.FEED,
                        version_key = key, descriptor_digest = measured})
                    local value = replicated.ok and bounds.object(replicated.value) or nil
                    local content = value and value.content
                    local result: Result
                    if type(content) ~= "string" then result = replicated.ok and failure("INTERNAL", "Source bytes are missing") or replicated
                    else
                        result = follower.reconcile(composed, {source_node = source_node, source_workspace = source_workspace,
                            component = component}, descriptor, content, sequence)
                    end
                    if not result.ok and (result.code == "BUSY" or result.code == "UNAVAILABLE" or result.code == "UNCERTAIN" or result.code == "APPROVAL") then retry = true end
                    local intent = result.ok and bounds.object(result.value) or nil
                    outcomes[#outcomes + 1] = {workspace_id = workspace_id, source_node = source_node, component = component,
                        ok = result.ok, code = result.code, message = result.message, phase = intent and intent.phase, outcome = intent and intent.outcome}
                    if (not result.ok and (result.code == "BUSY" or result.code == "UNAVAILABLE" or result.code == "UNCERTAIN"
                        or result.code == "APPROVAL" or result.code == "PAUSED"))
                        or (intent and intent.phase ~= nil and intent.phase ~= "settled") then break end
                end
            end
            close(plan_store, activation_store, lease_handle)
        end
    end
    replicas.close(replica_store)
    return transaction.success({outcomes = outcomes, retry = retry}, false)
end

return M
