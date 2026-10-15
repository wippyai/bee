-- MIT. Destination plan changes and installed application inspection.
local bounds = require("bounds")
local transaction = require("transaction")
local plans = require("plan_store")
local activations = require("activation_store")
local preflight = require("preflight")
local artifact = require("artifact")
local workspace_applications = require("workspace_applications")

local follows = require("follow_store")
local part_destination_policy = require("part_destination_policy")
local M = {}
type Object = part_destination_policy.Object
type Set = part_destination_policy.Set
local load = part_destination_policy.load
local selected = part_destination_policy.selected
local destination_resolver = part_destination_policy.destination_resolver
type Result = transaction.Result
local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
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

-- The bee.app definition an activation's artifact declares, which is what a
-- person opens to use the installed application.
function M.application_of(bytes: unknown, digest: unknown): (string?, string?)
    local entries = artifact.decode(bytes, digest)
    if not entries then return nil, nil end
    local id = workspace_applications.application(entries)
    if not id then return nil, nil end
    for _, raw in ipairs(entries) do
        local entry = bounds.object(raw)
        local meta = entry and entry.id == id and bounds.object(entry.meta) or nil
        local declared = meta and bounds.object(meta.application)
        local title = declared and bounds.line(declared.title, 80)
        if title then return id, title end
    end
    return id, nil
end

-- Each applied activation says which application it runs; one that cannot be
-- read says nothing.
local function annotate(store: activations.Store, listing: Result): Result
    local value = listing.ok and bounds.object(listing.value) or nil
    local rows = value and value.activations
    if type(rows) ~= "table" then return listing end
    local config = load()
    for _, raw in ipairs(rows) do
        local row = bounds.object(raw)
        if row and row.intent_id ~= nil and row.intent_id == row.observed_intent_id then
            local read = activations.get(store, row.intent_id)
            local intent = read.ok and bounds.object(read.value) or nil
            if intent then row.application, row.title = M.application_of(intent.artifact_bytes, intent.artifact_digest) end
        end
        local source_node = row and bounds.id(row.source_node) or nil
        local source_workspace = row and bounds.id(row.source_workspace) or nil
        local chosen = config and source_node and source_workspace and selected(config, store.workspace, source_node, source_workspace, store) or nil
        if row and chosen and source_node and source_workspace then
            row.component = chosen.component
            local following = follows.get(store, {source_node = source_node, source_workspace = source_workspace, component = chosen.component})
            if not following.ok then return following end
            local state = bounds.object(following.value)
            if state then row.follow_state, row.follow_outcome, row.follow_message = state.mode, state.last_outcome, state.last_message end
        end
    end
    return listing
end

M.load = load
M.selected = selected
M.destination_resolver = destination_resolver
M.failure = failure
M.entry_change = entry_change
M.by_id = by_id
M.plan_changes = plan_changes
M.annotate = annotate
return M
