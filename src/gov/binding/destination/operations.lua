-- MIT. Destination operations over one installed application: removal, revert, lease requests and following consent.
local registry = require("registry")
local bounds = require("bounds")
local plans = require("plan_store")
local activations = require("activation_store")
local leases = require("lease_store")
local lease_grants = require("lease_grants")
local owner = require("activation_owner")
local materializer = require("materializer")
local headless_revert = require("headless_revert")
local uninstall = require("activation_uninstall")
local activation_profiles = require("activation_profiles")
local capability_grants = require("capability_grants")
local capability_model = require("capability_model")
local workspace_applications = require("workspace_applications")
local follows = require("follow_store")
local follow_wake = require("follow_wake")
local M = {}
local part_destination_inspection = require("part_destination_inspection")
type Object = part_destination_inspection.Object
type Result = part_destination_inspection.Result
local failure = part_destination_inspection.failure
local load = part_destination_inspection.load
local selected = part_destination_inspection.selected
local part_destination_policy = require("part_destination_policy")
type Configuration = part_destination_policy.Configuration
type Profile = part_destination_policy.Profile
local approval_executor = part_destination_policy.approval_executor
local owner_config = part_destination_policy.owner_config

local function exact(request: Object, fields: {string}): string?
    local allowed = {"operation", "workspace_id"}
    for _, field in ipairs(fields) do allowed[#allowed + 1] = field end
    return bounds.fields(request, allowed)
end

local RECOVERY_ATTEMPTS = 4

-- The overlay owner an application of this workspace runs under.
local function application_owner(workspace_id: string, source_workspace: string): string?
    local identity = activation_profiles.hub_identity(workspace_id, source_workspace)
        or workspace_applications.identity(workspace_id, source_workspace, true)
    return identity and identity.overlay_owner or nil
end

-- A person's removal of an application they installed: the activation owner
-- records it under the person and takes the application off its registry
-- overlay. Its databases stay registered, with no grant reaching them, so the
-- data and its migration ledger are there for the next install.
local function uninstall_application(request: Object, workspace_id: string, actor_id: string,
    activation_store: activations.Store): Result
    if exact(request, {"source_workspace", "receipt_key", "expected_intent_id"}) then return failure("INVALID", "uninstall has unknown fields") end
    local source_workspace, key = bounds.id(request.source_workspace), bounds.id(request.receipt_key)
    local overlay_owner = source_workspace and application_owner(workspace_id, source_workspace) or nil
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
    local overlay_owner = application_owner(workspace_id, source_workspace)
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
    if not identity or identity.overlay_owner ~= profile_value.overlay_owner
        or identity.component ~= profile_value.component then
        return nil, nil, "activation profile is not a workspace application"
    end
    local catalog_entry, catalog_lookup_error = registry.get("bee.capability:catalog")
    if not catalog_entry then return nil, nil, "host capability catalog lookup failed: " .. tostring(catalog_lookup_error) end
    local vocabulary, catalog_error = capability_model.decode(catalog_entry)
    if not vocabulary then return nil, nil, catalog_error end
    local record_id = capability_grants.record_id(profile_value.overlay_owner)
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


M.exact = exact
M.uninstall_application = uninstall_application
M.revert_application = revert_application
M.lease_request = lease_request
M.follow_consent = follow_consent
return M
