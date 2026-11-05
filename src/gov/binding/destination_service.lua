-- MIT. Destination-owned composition for reviewed application delivery.
-- Replicas and Hub metadata supply bytes. This service selects host policy,
-- checks the local caller, owns approval consumption and applies one overlay.
local security = require("security")
local system = require("system")
local events = require("events")
local logger = require("logger")
local bounds = require("bounds")
local transaction = require("transaction")
local replicas = require("replicas")
local plans = require("plan_store")
local activations = require("activation_store")
local leases = require("lease_store")
local owner = require("activation_owner")
local hub_package = require("hub_package")
local package_requirements = require("package_requirements")
local delivery = require("delivery")
local destination = require("destination")
local preflight = require("preflight")
local uninstall = require("activation_uninstall")
local artifact = require("artifact")

local follows = require("follow_store")
local follower = require("follow_source")
local follow_wake = require("follow_wake")

local M = {}
local part_destination_stores = require("part_destination_stores")
local stores = part_destination_stores.stores
local close = part_destination_stores.close
local part_destination_operations = require("part_destination_operations")
local exact = part_destination_operations.exact
local uninstall_application = part_destination_operations.uninstall_application
local revert_application = part_destination_operations.revert_application
local lease_request = part_destination_operations.lease_request
local follow_consent = part_destination_operations.follow_consent
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

return M
