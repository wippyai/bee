-- SPDX-License-Identifier: MIT
-- Publish the frozen overlay the agent authored, stage it into the desktop's
-- own workspace and read the destination's preflight verdict. This probe
-- records no review, selection, approval or activation: the person does that in
-- the Overlays window and the activation owner applies it.
local funcs = require("funcs")
local registry = require("registry")
local system = require("system")
local json = require("json")
local logger = require("logger")
local bounds = require("bounds")
local preflight = require("preflight")

type Object = {[string]: unknown}

local INPUTS = "bee.agent_app_probe:inputs"
local COMPONENT = "bee.agent_app_demo/app"
local OVERLAY_OWNER = "bee.agent_app_probe:activation_overlay"
local APPROVAL_POLICY = "local-agent-app-delivery"
local NAMESPACE = "bee.agent_app_demo"

local function object(value: unknown): Object
    local decoded = bounds.object(value)
    if not decoded then error("expected an object value") end
    return decoded
end

local function call_api(target: string, request: unknown): Object
    local result, err = funcs.call(target, request)
    if err then error(target .. " call failed: " .. tostring(err)) end
    local answer = object(result)
    if answer.ok ~= true then
        local fault = bounds.object(answer.error)
        error(target .. " returned error: " .. tostring(fault and fault.code or answer.code)
            .. ": " .. tostring(fault and fault.message or answer.message))
    end
    local value = bounds.object(answer.value)
    if not value then error(target .. " returned no value") end
    return value
end

local function digest_of(value: unknown, label: string): string
    local measured = bounds.id(value)
    if not measured or #measured ~= 64 then error(label .. " is not a digest") end
    return measured
end

local function inputs(): Object
    local entry = registry.get(INPUTS)
    if not entry then error("acceptance inputs are unavailable") end
    return object(entry.data)
end

local function text_of(value: unknown, label: string): string
    local decoded = bounds.text(value, 4096)
    if not decoded or decoded == "" then error(label .. " is not bounded text") end
    return decoded
end

-- One component publishes from one source workspace at a time, so this round
-- replaces the publication profile. Every staged round keeps its own activation
-- profile: a plan the destination still lists resolves against the profile it
-- was staged under.
local function configure(workspace_id: string, local_node: string, source_workspace: string)
    local publication = registry.get("bee.governance:publication_profiles")
    if not publication then error("publication profiles are unavailable") end
    local publication_data = object(publication.data)
    local publication_profiles: {unknown} = {}
    for _, raw in ipairs(publication_data.profiles :: {unknown}) do
        local profile = object(raw)
        if profile.workspace_id ~= workspace_id or profile.component ~= COMPONENT then
            publication_profiles[#publication_profiles + 1] = profile
        end
    end
    publication_profiles[#publication_profiles + 1] = {workspace_id = workspace_id,
        source_workspace = source_workspace, component = COMPONENT, overlay_owner = OVERLAY_OWNER}
    publication_data.profiles = publication_profiles
    publication.data = publication_data

    local activation = registry.get("bee.governance:activation_profiles")
    if not activation then error("activation profiles are unavailable") end
    local activation_data = object(activation.data)
    local activation_profiles: {unknown} = {}
    for _, raw in ipairs(activation_data.profiles :: {unknown}) do
        local profile = object(raw)
        if profile.workspace_id ~= workspace_id or profile.source_node ~= local_node
            or profile.source_workspace ~= source_workspace then
            activation_profiles[#activation_profiles + 1] = profile
        end
    end
    activation_profiles[#activation_profiles + 1] = {workspace_id = workspace_id, source_node = local_node,
        source_workspace = source_workspace, component = COMPONENT, resolver = "overlay",
        overlay_owner = OVERLAY_OWNER, approval_policy = APPROVAL_POLICY,
        parameters = table.create(1, 0),
        applications = {{definition_id = "bee.agent_app_demo:app",
            policies = {"bee.security:ordinary_app_subsystem_boundary"}, thread_access = "observe_post"}},
        allow = {packages = {COMPONENT}, namespaces = {NAMESPACE}, kinds = {"process.lua"},
            databases = table.create(1, 0), grants = table.create(1, 0),
            modules = {"tty", "process", "channel", "json"}}}
    activation_data.profiles = activation_profiles
    activation.data = activation_data

    local approvers = registry.get("bee:approver_policies")
    if not approvers then error("approval policies are unavailable") end
    local approver_data = object(approvers.data)
    local policies = approver_data.policies :: {unknown}
    local declared = false
    for _, raw in ipairs(policies) do
        local policy = bounds.object(raw)
        if policy and policy.name == APPROVAL_POLICY then declared = true end
    end
    if not declared then
        policies[#policies + 1] = {name = APPROVAL_POLICY,
            approvers = {{definition_id = "bee.inbox:app"}}, max_ttl_ms = 600000}
    end
    approver_data.policies = policies
    approvers.data = approver_data

    local changes = registry.snapshot():changes()
    if not changes:update(publication) then error("stage the publication profiles") end
    if not changes:update(activation) then error("stage the activation profiles") end
    if not changes:update(approvers) then error("stage the approver policies") end
    local applied, apply_error = changes:apply()
    if not applied then error("apply host delivery profiles: " .. tostring(apply_error)) end
end

local function main()
    local values = inputs()
    local workspace_id = text_of(values.destination_workspace, "destination workspace")
    local source_workspace = text_of(values.source_workspace, "source workspace")
    local version = text_of(values.version, "version")
    local snapshot_digest = digest_of(values.snapshot_digest, "frozen snapshot digest")
    local artifact_digest = digest_of(values.artifact_digest, "authored artifact digest")
    local local_node = assert(system.node.id())
    configure(workspace_id, local_node, source_workspace)

    local prepared = call_api("bee.governance.binding:publication_call", {operation = "prepare", workspace_id = workspace_id,
        component = COMPONENT, version = version, snapshot_digest = snapshot_digest})
    local descriptor = object(prepared.descriptor)
    local manifest = object(descriptor.manifest)
    if manifest.artifact_digest ~= artifact_digest then
        error("the prepared descriptor carries another artifact than the one the agent froze")
    end

    local available = call_api("bee.governance.binding:destination_call", {operation = "available", workspace_id = workspace_id})
    local found = false
    for _, raw in ipairs(available.versions :: {unknown}) do
        local item = object(raw)
        if item.key == descriptor.key and item.digest == descriptor.digest then found = true end
    end
    if not found then error("the prepared descriptor was not discoverable by the destination") end

    local staged_reply = call_api("bee.governance.binding:destination_call", {operation = "stage", workspace_id = workspace_id,
        source_owner = descriptor.owner_id, feed = descriptor.feed, version_key = descriptor.key,
        descriptor_digest = descriptor.digest, idempotency_key = "stage-" .. source_workspace .. "-" .. version})
    if staged_reply.status ~= "staged" or staged_reply.selected == true then
        error("the agent's version did not stage as an unselected plan")
    end

    local staged = call_api("bee.governance.binding:destination_call", {operation = "get", workspace_id = workspace_id,
        source_node = descriptor.owner_id, source_workspace = source_workspace, version = version})
    if staged.artifact_digest ~= artifact_digest then error("the staged plan carries another artifact digest") end
    local report, report_error = preflight.decode_report(staged.preflight_bytes, staged.preflight_digest)
    if not report then error("staged preflight report: " .. tostring(report_error)) end

    local diagnostics: {unknown} = {}
    for _, diagnostic in ipairs(report.diagnostics) do
        diagnostics[#diagnostics + 1] = {code = diagnostic.code, target = diagnostic.target,
            message = diagnostic.message, remedy = diagnostic.remedy}
    end
    local added: {unknown} = table.create(1, 0)
    local modified: {unknown} = table.create(1, 0)
    if report.ready == true and #report.diagnostics == 0 then
        local changes = call_api("bee.governance.binding:destination_call", {operation = "changes", workspace_id = workspace_id,
            source_node = local_node, source_workspace = source_workspace, version = version})
        for _, raw in ipairs(changes.added :: {unknown}) do
            local item = object(raw)
            added[#added + 1] = {id = item.id, kind = item.kind}
        end
        for _, raw in ipairs(changes.changed :: {unknown}) do
            local item = object(raw)
            modified[#modified + 1] = {id = item.id, kind = item.kind}
        end
    end
    logger:info("AGENT_APP_STAGED", {ready = report.ready == true and #report.diagnostics == 0,
        pending_migrations = #report.pending_migrations, diagnostics = diagnostics, added = added, changed = modified,
        source_workspace = source_workspace, version = version,
        source_node = local_node,
        plan_digest = digest_of(staged.plan_digest, "staged plan digest"),
        artifact_digest = artifact_digest, overlay_owner = OVERLAY_OWNER})
end

return {main = function(...)
    local ok, err = pcall(main, ...)
    if not ok then
        logger:info("AGENT_APP_STAGE_FAILED", {error = tostring(err)})
        error(err)
    end
end}
