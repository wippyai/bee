-- MIT. Public delivery facade for an authoring agent. It authenticates the
-- caller's exact delivery operation, then composes the existing owner facades
-- (publication, destination and preflight) as that same actor. It writes no
-- overlay: the agent publishes, stages and, once the destination's preflight
-- is clean, records its review and selection and prepares the activation.
-- That raises the one approval the person gives; the activation worker
-- applies the exact intent once the person approves it.
local funcs = require("funcs")
local security = require("security")
local resources = require("resources")
local bounds = require("bounds")
local json = require("json")
local preflight = require("preflight")
local guide = require("guide")
local transaction = require("transaction")
local protocol = require("protocol")
local publication_profiles = require("publication_profiles")
local activation_profiles = require("activation_profiles")
local system = require("system")

local M = {}
type Result = transaction.Result
type Object = {[string]: unknown}

local PUBLICATION = "bee.gov.binding:publication_call"
local DESTINATION = "bee.gov.binding:destination_call"
-- An authorized intent settles within the activation owner's own step bound.
local MAX_STEPS = 16
-- Requests for one version whose approval ended unanswered or denied.
local MAX_ATTEMPTS = 64
local ENDED: {[string]: boolean} = {denied = true, expired = true, withdrawn = true}

-- One delivery action per operation, checked against the caller's own actor
-- before any owner facade runs.
local ACTIONS: {[string]: string} = {
    request = "bee.gov.delivery.activate",
    status = "bee.gov.delivery.read",
    publish = "bee.gov.delivery.publish",
    preflight = "bee.gov.delivery.manage",
}

function M.required_action(raw: unknown): string?
    local operation = bounds.id(raw)
    if not operation then return nil end
    return ACTIONS[operation]
end

local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end

local function object(value: unknown): Object?
    return bounds.object(value)
end

-- The host profile names the component and source workspace for one
-- destination workspace; the agent names only the overlay it authored in. A
-- refusal carries what the author or the host changes to deliver it.
local function profile_for(workspace_id: string, source_workspace: string): (Object?, Result?)
    local entry, entry_error = resources.publication_profiles()
    if not entry then return nil, failure("UNAVAILABLE", tostring(entry_error or "publication profiles are unavailable")) end
    local activation_entry, activation_error = resources.activation_profiles()
    if not activation_entry then return nil, failure("UNAVAILABLE", tostring(activation_error)) end
    local activation, decode_error = activation_profiles.decode(activation_entry.data)
    if not activation then return nil, failure("UNAVAILABLE", tostring(decode_error)) end
    local node, node_error = system.node.id()
    if not node then return nil, failure("UNAVAILABLE", tostring(node_error)) end
    local configuration, configuration_error = publication_profiles.configuration(entry.data, activation, node)
    if not configuration then return nil, failure("UNAVAILABLE", configuration_error or "publication profiles are unavailable") end
    local profile, refused = publication_profiles.for_source(configuration, workspace_id, source_workspace)
    if not profile then
        local reason = refused or {message = "publication profile is unavailable", remedy = ""}
        return nil, transaction.failure("BLOCKED", reason.message, {remedy = reason.remedy})
    end
    return {workspace_id = profile.workspace_id, source_workspace = profile.source_workspace,
        component = profile.component, overlay_owner = profile.overlay_owner}, nil
end

local function forward(target: string, request: unknown): (Object?, Result?)
    local raw, call_error = funcs.call(target, request)
    if call_error then return nil, failure("UNAVAILABLE", target .. ": " .. tostring(call_error)) end
    local reply = object(raw)
    if not reply then return nil, failure("INTERNAL", target .. " returned a malformed reply") end
    if reply.ok ~= true then
        local fault = object(reply.error) or {}
        local code = bounds.id(fault.code) or bounds.id(reply.code) or "INTERNAL"
        local message = bounds.text(fault.message, 2048) or bounds.text(reply.message, 2048) or "delivery operation failed"
        -- The destination's own refusal value carries a remedy; keep it.
        local value = object(reply.value)
        return nil, transaction.failure(code, message,
            value and value.remedy ~= nil and {remedy = value.remedy} or value)
    end
    local value = object(reply.value)
    if not value then return nil, failure("INTERNAL", target .. " returned no value") end
    return value, nil
end

local function diagnostic_rows(report: Object): {unknown}
    local rows: {unknown} = {}
    local reported = report.diagnostics
    if type(reported) ~= "table" then return rows end
    for _, raw in ipairs(reported) do
        local item = object(raw)
        if item then
            rows[#rows + 1] = {code = item.code, target = item.target, message = item.message, remedy = item.remedy}
        end
    end
    return rows
end

-- A ready plan is reviewed and selected by its requester and its activation
-- prepared under keys derived from the plan digest, so a repeated request
-- replays each step. Preparing raises the person's approval; nothing reaches
-- the registry before it. An intent the destination authorized without a new
-- decision, such as a contained upgrade of approved grants, is carried on to
-- settled here, so no request is left waiting for an approval that never comes.
local function activate(workspace_id: string, source_node: string, source_workspace: string,
    version: string, plan: Object): (Object?, Result?)
    local digest = bounds.text(plan.plan_digest, 64)
    if not digest or #digest ~= 64 then return nil, failure("INTERNAL", "staged plan has no digest") end
    local function key(step: string): string return "deliver-" .. step .. "-" .. digest:sub(1, 32) end
    local identity: Object = {workspace_id = workspace_id, source_node = source_node,
        source_workspace = source_workspace, version = version}
    local function with(fields: Object): Object
        local request: Object = {}
        for name, item in pairs(identity) do request[name] = item end
        for name, item in pairs(fields) do request[name] = item end
        return request
    end
    local current: Object = plan
    if current.status == "staged" then
        local reviewed, review_error = forward(DESTINATION, with({operation = "review", expected_revision = current.revision,
            idempotency_key = key("review"), review_status = "accepted",
            review_reason = "Preflight ready; the person's approval applies it"}))
        if not reviewed then return nil, review_error end
        current = reviewed
    end
    if current.selected ~= true then
        local chosen, select_error = forward(DESTINATION, with({operation = "select", expected_revision = current.revision,
            idempotency_key = key("select")}))
        if not chosen then return nil, select_error end
    end
    -- An earlier request whose approval was denied, expired or withdrawn has
    -- ended; the next attempt prepares under its own keys and asks the person anew.
    local intent: Object? = nil
    local attempt_id, attempt_receipt = key("intent"), key("receipt")
    for attempt = 0, MAX_ATTEMPTS do
        if attempt > 0 then
            attempt_id, attempt_receipt = key("intent") .. "-" .. tostring(attempt), key("receipt") .. "-" .. tostring(attempt)
        end
        local prepared, prepare_error = forward(DESTINATION, with({operation = "prepare", intent_id = attempt_id,
            receipt_key = attempt_receipt}))
        if not prepared then return nil, prepare_error end
        intent = prepared
        if not (prepared.phase == "settled" and ENDED[tostring(prepared.outcome)]) then break end
        intent = nil
    end
    if not intent then return nil, failure("BLOCKED", "this version was requested " .. tostring(MAX_ATTEMPTS)
        .. " times without approval; the person installs it from Library") end
    for _ = 1, MAX_STEPS do
        local phase = intent.phase
        if phase ~= "authorized" and phase ~= "consuming" and phase ~= "applying" then break end
        local stepped, step_error = forward(DESTINATION, {operation = "step", workspace_id = workspace_id,
            intent_id = attempt_id, receipt_key = attempt_receipt})
        if not stepped then return nil, step_error end
        intent = stepped
    end
    return intent, nil
end

-- Publication prepare, then a destination stage, then the destination's own
-- preflight verdict. The agent learns ready or the exact diagnostics, and the
-- human steps that follow are stated here because the agent cannot take them.
local function request_operation(workspace_id: string, source_workspace: string,
    version: string, snapshot_digest: string): Result
    local profile, profile_error = profile_for(workspace_id, source_workspace)
    if not profile then return profile_error end
    local component = bounds.text(profile.component, 160)
    if not component or component == "" then return failure("BLOCKED", "publication profile names no component") end

    local prepared, prepare_error = forward(PUBLICATION, {operation = "prepare", workspace_id = workspace_id,
        component = component, version = version, snapshot_digest = snapshot_digest})
    if not prepared then return prepare_error end
    local descriptor = object(prepared.descriptor)
    if not descriptor then return failure("INTERNAL", "publication returned no descriptor") end

    local available, available_error = forward(DESTINATION, {operation = "available", workspace_id = workspace_id})
    if not available then return available_error end
    local found = false
    for _, raw in ipairs((available.versions or {})) do
        local item = object(raw)
        if item and item.key == descriptor.key and item.digest == descriptor.digest then found = true end
    end
    if not found then return failure("BLOCKED", "the prepared version is not discoverable at this destination") end

    -- A version requested again was staged and accepted before; its request
    -- carries on from that plan, and activation measures it afresh.
    local identity = {operation = "get", workspace_id = workspace_id,
        source_node = descriptor.owner_id, source_workspace = source_workspace, version = version}
    local plan = forward(DESTINATION, identity)
    if not (plan and plan.status == "reviewed" and plan.review_status == "accepted") then
        local staged, stage_error = forward(DESTINATION, {operation = "stage", workspace_id = workspace_id,
            source_owner = descriptor.owner_id, feed = descriptor.feed, version_key = descriptor.key,
            descriptor_digest = descriptor.digest, idempotency_key = "deliver-" .. source_workspace .. "-" .. version})
        if not staged then return stage_error end
        if staged.status ~= "staged" then return failure("BLOCKED", "the version did not stage at this destination") end
        local read, plan_error = forward(DESTINATION, identity)
        if not read then return plan_error end
        plan = read
    end
    local report, report_error = preflight.decode_report(plan.preflight_bytes, plan.preflight_digest)
    if not report then return failure("INTERNAL", "staged preflight report: " .. tostring(report_error)) end
    local ready = report.ready == true and #report.diagnostics == 0
    local steps, opening = guide.delivery_steps(source_workspace)
    local value: Object = {ready = ready, plan_digest = plan.plan_digest,
        artifact_digest = plan.artifact_digest, version = version, source_overlay_id = source_workspace,
        component = component, diagnostics = diagnostic_rows(report),
        pending_migrations = #report.pending_migrations,
        human_steps = steps,
        human_steps_where = {approve = "Needs you", open = opening}}
    if ready then
        local intent, refused = activate(workspace_id, tostring(descriptor.owner_id), source_workspace, version, plan)
        if intent then
            value.intent_id, value.approval_id, value.activation_phase = intent.intent_id, intent.approval_id, intent.phase
            value.activation_outcome = intent.outcome
        else
            value.activation_refusal = refused and refused.message or "activation was not prepared"
        end
    end
    return transaction.success(value, false)
end

-- Check a frozen candidate without staging a version: resolve the host
-- profile, parse the exact snapshot into its canonical artifact and report
-- its measure. A candidate that fails here fails request the same way; a
-- candidate that passes still needs request to stage it and read the
-- destination's own preflight verdict.
local function preflight_operation(workspace_id: string, source_workspace: string,
    version: string, snapshot_digest: string): Result
    local profile, profile_error = profile_for(workspace_id, source_workspace)
    if not profile then return profile_error end
    local component = bounds.text(profile.component, 160)
    if not component or component == "" then return failure("BLOCKED", "publication profile names no component") end
    local prepared, prepare_error = forward(PUBLICATION, {operation = "prepare", workspace_id = workspace_id,
        component = component, version = version, snapshot_digest = snapshot_digest})
    if not prepared then return prepare_error end
    local descriptor = object(prepared.descriptor)
    if not descriptor then return failure("INTERNAL", "publication returned no descriptor") end
    local steps, opening = guide.delivery_steps(source_workspace)
    table.insert(steps, 1, "request delivery to stage this version and read its preflight verdict")
    return transaction.success({staged = false, version = version, source_overlay_id = source_workspace,
        component = component, artifact_digest = descriptor.digest, descriptor = descriptor,
        snapshot_digest = snapshot_digest,
        human_steps = steps,
        human_steps_where = {approve = "Needs you", open = opening}}, false)
end
-- Read the staged plan and, when an intent is named, its activation status.
local function status_operation(workspace_id: string, source_workspace: string, version: string,
    source_node: string?, intent_id: string?): Result
    local node = source_node
    if not node then
        local profile, profile_error = profile_for(workspace_id, source_workspace)
        if not profile then return profile_error end
        node = system.node.id()
    end
    local plan, plan_error = forward(DESTINATION, {operation = "get", workspace_id = workspace_id,
        source_node = node, source_workspace = source_workspace, version = version})
    if not plan then return plan_error end
    local value: Object = {version = version, source_overlay_id = source_workspace, plan_digest = plan.plan_digest,
        artifact_digest = plan.artifact_digest, plan_status = plan.status,
        review_status = plan.review_status, selected = plan.selected}
    -- The activation reported is the named one, else this version's latest,
    -- so an install that ended without the person's approval reads as ended.
    local intent: Object? = nil
    if intent_id then
        local named, intent_error = forward(DESTINATION, {operation = "status", workspace_id = workspace_id,
            intent_id = intent_id})
        if not named then return intent_error end
        intent = named
    else
        local listed, list_error = forward(DESTINATION, {operation = "activations", workspace_id = workspace_id})
        if not listed then return list_error end
        for _, raw in ipairs(bounds.dense_list(listed.activations, 1024, "activations") or {}) do
            local item = bounds.object(raw)
            if item and item.source_node == node and item.source_workspace == source_workspace and item.version == version then
                intent = item
                break
            end
        end
    end
    if intent then
        value.activation = {intent_id = intent.intent_id, phase = intent.phase, outcome = intent.outcome,
            plan_digest = intent.plan_digest, diagnostics = intent.diagnostics}
    end
    return transaction.success(value, false)
end

-- Publish is the exact locally reviewed and applied version; publication
-- refuses anything else, so the agent cannot publish around the person.
local function publish_operation(workspace_id: string, source_workspace: string, version: string): Result
    local profile, profile_error = profile_for(workspace_id, source_workspace)
    if not profile then return profile_error end
    local component = bounds.text(profile.component, 160)
    if not component or component == "" then return failure("BLOCKED", "publication profile names no component") end
    local published, publish_error = forward(PUBLICATION, {operation = "publish", workspace_id = workspace_id,
        component = component, version = version})
    if not published then return publish_error end
    return transaction.success({version = version, component = component, published = true,
        sequence = published.sequence, descriptor = published.descriptor,
        human_steps = guide.delivery_steps()}, false)
end

function M.call(raw: unknown): Result
    local request, decode_error = protocol.decode(raw)
    if not request then return failure("INVALID", decode_error or "invalid delivery request") end
    local operation = request.operation
    local workspace_id, source_workspace, version = request.workspace_id, request.source_workspace, request.version
    local actor = security.actor()
    local action = ACTIONS[operation]
    if not actor or not security.can(action, workspace_id) then
        return failure("DENIED", "delivery operation is not authorized")
    end
    if operation == "request" then
        return request_operation(workspace_id, source_workspace, version, assert(request.snapshot_digest))
    end
    if operation == "preflight" then
        return preflight_operation(workspace_id, source_workspace, version, assert(request.snapshot_digest))
    end
    if operation == "status" then
        return status_operation(workspace_id, source_workspace, version,
            bounds.id(request.source_node), bounds.id(request.intent_id))
    end
    return publish_operation(workspace_id, source_workspace, version)
end

return {handle = M.call}
