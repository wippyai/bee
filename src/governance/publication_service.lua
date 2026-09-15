-- MIT. Host-selected overlay publication. Callers name a configured
-- application and version; the host profile chooses the source workspace and
-- overlay. Remote identities and destination policy never enter publication.
local registry = require("registry")
local security = require("security")
local system = require("system")
local base64 = require("base64")
local bounds = require("bounds")
local artifact = require("artifact")
local publisher = require("publisher")
local staging = require("staging")
local activations = require("activation_store")
local resources = require("resources")
local sync_resources = require("sync_resources")
local transaction = require("transaction")

local M = {}
local CONFIG = "bee.governance:publication_profiles"
local MAX_PROFILES = 64
type Object = {[string]: unknown}
type Profile = {workspace_id: string, source_workspace: string, component: string, overlay_owner: string}
type Configuration = {profiles: {Profile}}
type Result = transaction.Result

local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end

function M.configuration(raw: unknown): (Configuration?, string?)
    local value = bounds.object(raw)
    local rows = value and value.profiles
    if not value or bounds.fields(value, {"profiles"}) or type(rows) ~= "table" then
        return nil, "publication profiles must be an object with a profile list"
    end
    local source = rows :: table
    local count = 0
    for key in pairs(source) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, "publication profiles must be a dense list" end
        count = count + 1
    end
    if count > MAX_PROFILES then return nil, "publication profile capacity is exceeded" end
    local profiles: {Profile} = {}
    local seen: {[string]: boolean} = {}
    for index = 1, count do
        local item = bounds.object(source[index])
        if not item or bounds.fields(item, {"workspace_id", "source_workspace", "component", "overlay_owner"}) then
            return nil, "publication profile is malformed"
        end
        local workspace_id, source_workspace = bounds.id(item.workspace_id), bounds.id(item.source_workspace)
        local component = bounds.text(item.component, 160)
        local overlay_owner = bounds.id(item.overlay_owner)
        if not workspace_id or not source_workspace or not component or component == "" or not overlay_owner then
            return nil, "publication profile identity is invalid"
        end
        local key = workspace_id .. "\n" .. component
        if seen[key] then return nil, "publication profile identity is duplicated" end
        seen[key] = true
        profiles[#profiles + 1] = {workspace_id = workspace_id, source_workspace = source_workspace,
            component = component, overlay_owner = overlay_owner}
    end
    return {profiles = profiles}, nil
end

local function load(): (Configuration?, string?)
    local entry, entry_error = registry.get(CONFIG)
    if not entry then return nil, tostring(entry_error or "publication profiles are unavailable") end
    return M.configuration(entry.data)
end

function M.snapshot_artifact(raw: unknown): (unknown?, string?)
    local reply = bounds.object(raw)
    local value = reply and bounds.object(reply.value) or nil
    if not reply or reply.ok ~= true or not value or value.path ~= "registry.json"
        or type(value.content_base64) ~= "string" or type(value.digest) ~= "string" then
        return nil, "authoring snapshot did not return registry.json"
    end
    local bytes, decode_error = base64.decode(value.content_base64)
    if not bytes or decode_error then return nil, "decode authoring registry artifact" end
    local entries, artifact_error = artifact.decode(bytes, value.digest)
    if not entries then return nil, artifact_error or "authoring registry artifact is invalid" end
    return {bytes = bytes, digest = value.digest, entries = entries}, nil
end

local function chosen_profile(config: Configuration, workspace_id: string, component: string): Profile?
    for _, item in ipairs(config.profiles) do
        if item.workspace_id == workspace_id and item.component == component then return item end
    end
    return nil
end

function M.call(raw: unknown): Result
    local request = bounds.object(raw)
    if not request or bounds.fields(request, {"operation", "workspace_id", "component", "version", "snapshot_digest"})
        or (request.operation ~= "prepare" and request.operation ~= "publish") then
        return failure("INVALID", "publication request is invalid")
    end
    local workspace_id, component = bounds.id(request.workspace_id), bounds.text(request.component, 160)
    local selected_version = bounds.id(request.version)
    local snapshot_digest = request.snapshot_digest
    if not workspace_id or not component or component == "" or not selected_version
        or (request.operation == "prepare" and (type(snapshot_digest) ~= "string" or #snapshot_digest ~= 64
            or not snapshot_digest:match("^[0-9a-f]+$")))
        or (request.operation == "publish" and snapshot_digest ~= nil) then
        return failure("INVALID", "publication identity is invalid")
    end
    local actor = security.actor()
    local action = request.operation == "prepare" and "bee.governance.delivery.manage" or "bee.governance.delivery.publish"
    if not actor or not security.can(action, workspace_id) then
        return failure("DENIED", "application publication is not authorized")
    end
    local config, config_error = load()
    if not config then return failure("UNAVAILABLE", config_error or "publication configuration is unavailable") end
    local chosen = chosen_profile(config, workspace_id, component)
    if not chosen then return failure("BLOCKED", "host has no publication profile for this application") end

    local node_id, node_error = system.node.id()
    local governance_resource, governance_error = resources.database()
    local sync_resource, sync_error = sync_resources.database()
    if not node_id or node_error or not governance_resource or not sync_resource then
        return failure("UNAVAILABLE", tostring(node_error or governance_error or sync_error or "publication storage is unavailable"))
    end

    if request.operation == "prepare" then
        local store, open_error = staging.open(governance_resource, node_id)
        if not store then return failure("UNAVAILABLE", open_error or "open authoring workspace") end
        local read = store:read_frozen(chosen.source_workspace, "registry.json", snapshot_digest :: string)
        store:close()
        local authored, authored_error = M.snapshot_artifact(read)
        local value = bounds.object(authored)
        if not value then return failure("BLOCKED", authored_error or "read authored registry artifact") end
        return publisher.prepare(sync_resource, node_id, {source_workspace = chosen.source_workspace,
            component = chosen.component, version = selected_version,
            artifact = {bytes = value.bytes, digest = value.digest}})
    end

    local overlay, overlay_error = registry.overlay(chosen.overlay_owner)
    if not overlay then return failure("UNAVAILABLE", tostring(overlay_error or "open publication overlay")) end
    local entries, entries_error = overlay:entries()
    if not entries then return failure("UNAVAILABLE", tostring(entries_error or "read publication overlay")) end
    local measured, artifact_error = artifact.create(entries)
    if not measured then return failure("BLOCKED", artifact_error or "measure publication overlay") end
    local activation_store, activation_error = activations.open(governance_resource, node_id, workspace_id)
    if not activation_store then return failure("UNAVAILABLE", activation_error or "open application activation state") end
    local desired = activations.desired(activation_store, chosen.overlay_owner)
    activations.close(activation_store)
    local intent = desired.ok and bounds.object(desired.value) or nil
    if not intent or intent.phase ~= "settled" or intent.outcome ~= "applied"
        or intent.source_node ~= node_id or intent.source_workspace ~= chosen.source_workspace
        or intent.version ~= selected_version or intent.artifact_digest ~= measured.digest then
        return failure("BLOCKED", "only the exact locally reviewed and applied version can be published")
    end
    return publisher.publish(sync_resource, node_id, {source_workspace = chosen.source_workspace,
        component = chosen.component, version = selected_version,
        artifact = {bytes = measured.bytes, digest = measured.digest}})
end

return M
