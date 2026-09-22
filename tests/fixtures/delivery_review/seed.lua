-- MIT. Stage three application versions into the desktop's own workspace
-- through the production publication and destination chain: one whose
-- candidate introduces a reference to an entry nothing supplies, one whose
-- function entry declares an empty modules field the destination's function
-- config cannot read, and one the destination preflight accepts. The review surface is exercised afterwards in the
-- Overlays window; this probe records no review, selection or approval.
local funcs = require("funcs")
local registry = require("registry")
local system = require("system")
local json = require("json")
local logger = require("logger")
local bounds = require("bounds")
local artifact = require("artifact")
local preflight = require("preflight")

type Object = {[string]: unknown}

local DESTINATION = "bee.delivery_review_probe:destination"
local APPROVAL_POLICY = "local-delivery-review"
local VERSION = "1.0.0"
local READY_COMPONENT = "bee.delivery_review_ready/app"
local READY_WORKSPACE = "delivery-review-ready"
local READY_ENTRY = "bee.delivery_review_ready:probe"
local READY_OVERLAY = "bee.delivery_review_probe:ready_overlay"
local BLOCKED_COMPONENT = "bee.delivery_review_blocked/app"
local BLOCKED_WORKSPACE = "delivery-review-blocked"
local BLOCKED_ENTRY = "bee.delivery_review_blocked:probe"
local BLOCKED_OVERLAY = "bee.delivery_review_probe:blocked_overlay"
local CONFIG_COMPONENT = "bee.delivery_review_config/app"
local CONFIG_WORKSPACE = "delivery-review-config"
local CONFIG_ENTRY = "bee.delivery_review_config:probe"
local CONFIG_OVERLAY = "bee.delivery_review_probe:config_overlay"
local ABSENT_TARGET = "bee.delivery_review_absent:target"

-- Executable, not a data descriptor: this is what the review surface's
-- "settled applied" and the standalone invoke command both prove ran.
local READY_SOURCE = [[local function handle(request)
    return {ok = true, ready_probe = "delivery-review-ready"}
end
return {handle = handle}
]]

local function object(value: unknown): Object
    local decoded = bounds.object(value)
    if not decoded then error("expected an object value") end
    return decoded
end

local function reply_of(target: string, request: unknown): Object
    local result, err = funcs.call(target, request)
    if err then error(target .. " call failed: " .. tostring(err)) end
    return object(result)
end

local function call_api(target: string, request: unknown): Object
    local reply = reply_of(target, request)
    if reply.ok ~= true then
        local fault = bounds.object(reply.error)
        error(target .. " returned error: " .. tostring(fault and fault.code or reply.code)
            .. ": " .. tostring(fault and fault.message or reply.message))
    end
    local value = bounds.object(reply.value)
    if not value then error(target .. " returned no value") end
    return value
end

local function digest_of(value: unknown, label: string): string
    local measured = bounds.id(value)
    if not measured or #measured ~= 64 then error(label .. " is not a digest") end
    return measured
end

local function destination_workspace(): string
    local entry, entry_error = registry.get(DESTINATION)
    if not entry then error(tostring(entry_error or "destination entry is unavailable")) end
    local data = object(entry.data)
    local workspace_id = bounds.id(data.workspace_id)
    if not workspace_id then error("the acceptance destination workspace is not configured") end
    return workspace_id
end

local function entries_for(id: string, absent: string?): {unknown}
    local data: Object = {value = "delivery review probe"}
    -- A reference this candidate itself introduces: the destination supplies no
    -- such entry and the candidate does not carry one, so its own preflight
    -- refuses it.
    if absent then data.depends_on = {absent} end
    local measured, measure_error = artifact.create({{id = id, kind = "registry.entry", data = data}})
    if not measured then error("measure probe entries: " .. tostring(measure_error)) end
    return measured.entries
end

-- A minimal function.lua entry with its executable source inline, the same
-- shape the native destination unpacks into a callable. An empty declared
-- field crosses into the destination as neither a list nor an object, so this
-- entry omits the optional ones and review answers for that.
local function ready_entries(): {unknown}
    local measured, measure_error = artifact.create({{id = READY_ENTRY, kind = "function.lua",
        data = {source = READY_SOURCE, method = "handle"}}})
    if not measured then error("measure ready entry: " .. tostring(measure_error)) end
    return measured.entries
end

-- The same entry with an empty modules field. The destination's function
-- config reads that field as a list and an empty declared field reaches it as
-- neither, so review refuses the version.
local function config_entries(): {unknown}
    local measured, measure_error = artifact.create({{id = CONFIG_ENTRY, kind = "function.lua",
        data = {source = READY_SOURCE, method = "handle", modules = table.create(0, 1)}}})
    if not measured then error("measure config entry: " .. tostring(measure_error)) end
    return measured.entries
end

local function configure(workspace_id: string, local_node: string)
    local publication = assert(registry.get("bee.governance:publication_profiles"))
    local publication_data = object(publication.data)
    publication_data.profiles = {
        {workspace_id = workspace_id, source_workspace = READY_WORKSPACE,
            component = READY_COMPONENT, overlay_owner = READY_OVERLAY},
        {workspace_id = workspace_id, source_workspace = BLOCKED_WORKSPACE,
            component = BLOCKED_COMPONENT, overlay_owner = BLOCKED_OVERLAY},
        {workspace_id = workspace_id, source_workspace = CONFIG_WORKSPACE,
            component = CONFIG_COMPONENT, overlay_owner = CONFIG_OVERLAY}}
    publication.data = publication_data

    local activation = assert(registry.get("bee.governance:activation_profiles"))
    local activation_data = object(activation.data)
    activation_data.profiles = {
        {workspace_id = workspace_id, source_node = local_node, source_workspace = READY_WORKSPACE,
            component = READY_COMPONENT, resolver = "overlay", overlay_owner = READY_OVERLAY,
            approval_policy = APPROVAL_POLICY, parameters = {},
            allow = {packages = {READY_COMPONENT}, namespaces = {"bee.delivery_review_ready"},
                kinds = {"function.lua"}, databases = {}, grants = {}, modules = {}}},
        {workspace_id = workspace_id, source_node = local_node, source_workspace = BLOCKED_WORKSPACE,
            component = BLOCKED_COMPONENT, resolver = "overlay", overlay_owner = BLOCKED_OVERLAY,
            approval_policy = APPROVAL_POLICY, parameters = {},
            allow = {packages = {BLOCKED_COMPONENT}, namespaces = {"bee.delivery_review_blocked"},
                kinds = {"registry.entry"}, databases = {}, grants = {}, modules = {}}},
        {workspace_id = workspace_id, source_node = local_node, source_workspace = CONFIG_WORKSPACE,
            component = CONFIG_COMPONENT, resolver = "overlay", overlay_owner = CONFIG_OVERLAY,
            approval_policy = APPROVAL_POLICY, parameters = {},
            allow = {packages = {CONFIG_COMPONENT}, namespaces = {"bee.delivery_review_config"},
                kinds = {"function.lua"}, databases = {}, grants = {}, modules = {}}}}
    activation.data = activation_data

    local approvers = assert(registry.get("bee:approver_policies"))
    local approver_data = object(approvers.data)
    local policies = approver_data.policies :: {unknown}
    policies[#policies + 1] = {name = APPROVAL_POLICY,
        approvers = {{definition_id = "bee.inbox:app"}}, max_ttl_ms = 600000}
    approver_data.policies = policies
    approvers.data = approver_data

    local changes = registry.snapshot():changes()
    assert(changes:update(publication))
    assert(changes:update(activation))
    assert(changes:update(approvers))
    local applied, apply_error = changes:apply()
    if not applied then error("apply host delivery profiles: " .. tostring(apply_error)) end
end

local function author(source_workspace: string, entries: {unknown}): string
    call_api("bee.governance:overlay_call", {operation = "create", overlay_id = source_workspace,
        expected_revision = 0, idempotency_key = "create-" .. source_workspace})
    call_api("bee.governance:overlay_call", {operation = "put", overlay_id = source_workspace,
        expected_revision = 1, idempotency_key = "put-" .. source_workspace, path = "entries.json",
        content = json.encode(entries)})
    local frozen = call_api("bee.governance:overlay_call", {operation = "freeze",
        overlay_id = source_workspace, expected_revision = 2, idempotency_key = "freeze-" .. source_workspace})
    return digest_of(frozen.digest, source_workspace .. " frozen overlay digest")
end

local function stage(workspace_id: string, component: string, source_workspace: string, snapshot_digest: string): Object
    local prepared = call_api("bee.governance:publication_call", {operation = "prepare",
        workspace_id = workspace_id, component = component, version = VERSION,
        snapshot_digest = snapshot_digest})
    local descriptor = object(prepared.descriptor)
    local available = call_api("bee.governance:destination_call", {operation = "available", workspace_id = workspace_id})
    local found = false
    for _, raw in ipairs(available.versions :: {unknown}) do
        local item = object(raw)
        if item.key == descriptor.key and item.digest == descriptor.digest then found = true end
    end
    if not found then error(component .. " was not discoverable by the destination") end
    local staged = call_api("bee.governance:destination_call", {operation = "stage", workspace_id = workspace_id,
        source_owner = descriptor.owner_id, feed = descriptor.feed, version_key = descriptor.key,
        descriptor_digest = descriptor.digest, idempotency_key = "stage-" .. source_workspace})
    if staged.status ~= "staged" or staged.selected == true then
        error(component .. " did not stage as an unselected plan")
    end
    return call_api("bee.governance:destination_call", {operation = "get", workspace_id = workspace_id,
        source_node = descriptor.owner_id, source_workspace = source_workspace, version = VERSION})
end

local function verdict(plan: Object, label: string): preflight.Report
    local report, report_error = preflight.decode_report(plan.preflight_bytes, plan.preflight_digest)
    if not report then error(label .. " preflight report: " .. tostring(report_error)) end
    return report
end

local function main()
    local workspace_id = destination_workspace()
    local local_node = assert(system.node.id())
    configure(workspace_id, local_node)

    local ready_snapshot = author(READY_WORKSPACE, ready_entries())
    local blocked_snapshot = author(BLOCKED_WORKSPACE, entries_for(BLOCKED_ENTRY, ABSENT_TARGET))
    local config_snapshot = author(CONFIG_WORKSPACE, config_entries())

    local ready = stage(workspace_id, READY_COMPONENT, READY_WORKSPACE, ready_snapshot)
    local blocked = stage(workspace_id, BLOCKED_COMPONENT, BLOCKED_WORKSPACE, blocked_snapshot)
    local config = stage(workspace_id, CONFIG_COMPONENT, CONFIG_WORKSPACE, config_snapshot)

    local ready_report = verdict(ready, READY_COMPONENT)
    if ready_report.ready ~= true or #ready_report.diagnostics > 0 then
        error("the ready plan is not ready: " .. json.encode(ready_report.diagnostics))
    end
    if #ready_report.pending_migrations > 0 then error("the ready plan reports pending migrations") end

    local blocked_report = verdict(blocked, BLOCKED_COMPONENT)
    if blocked_report.ready ~= false then error("the blocked plan preflight did not refuse it") end
    local dangling = false
    for _, diagnostic in ipairs(blocked_report.diagnostics) do
        if diagnostic.code == "DANGLING_REFERENCE" and diagnostic.target == BLOCKED_ENTRY then dangling = true end
    end
    if not dangling then error("the blocked plan carries no DANGLING_REFERENCE: " .. json.encode(blocked_report.diagnostics)) end

    local config_report = verdict(config, CONFIG_COMPONENT)
    if config_report.ready ~= false then error("the map-shaped modules plan preflight did not refuse it") end
    local shaped = false
    for _, diagnostic in ipairs(config_report.diagnostics) do
        if diagnostic.code == "CONFIG_SHAPE" and diagnostic.target == CONFIG_ENTRY then shaped = true end
    end
    if not shaped then error("the map-shaped modules plan carries no CONFIG_SHAPE: " .. json.encode(config_report.diagnostics)) end

    -- The entry set a reviewer sees comes from the destination's read-only
    -- comparison of the reviewed candidate against the composed base.
    local changes = call_api("bee.governance:destination_call", {operation = "changes",
        workspace_id = workspace_id, source_node = local_node, source_workspace = READY_WORKSPACE,
        version = VERSION})
    local added = changes.added :: {unknown}
    if #added ~= 1 or object(added[1]).id ~= READY_ENTRY then
        error("the ready plan does not add its single entry: " .. json.encode(changes.added))
    end
    if object(added[1]).kind ~= "function.lua" then
        error("the ready plan entry is not function.lua: " .. tostring(object(added[1]).kind))
    end

    logger:info("DELIVERY_REVIEW_SEEDED", {workspace_id = workspace_id,
        ready_plan_digest = digest_of(ready.plan_digest, "ready plan digest"),
        ready_artifact_digest = digest_of(ready.artifact_digest, "ready artifact digest"),
        blocked_plan_digest = digest_of(blocked.plan_digest, "blocked plan digest"),
        blocked_diagnostics = #blocked_report.diagnostics,
        config_plan_digest = digest_of(config.plan_digest, "config plan digest"),
        config_diagnostics = #config_report.diagnostics})
end

return {main = function(...)
    local ok, err = pcall(main, ...)
    if not ok then
        logger:info("DELIVERY_REVIEW_FAILED", {error = tostring(err)})
        error(err)
    end
end}
