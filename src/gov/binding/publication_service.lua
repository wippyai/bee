-- MIT. Host-selected overlay publication. Callers name a configured
-- application and version; the host profile chooses the source workspace and
-- overlay. Remote identities and destination policy never enter publication.
local registry = require("registry")
local contract = require("contract")
local security = require("security")
local system = require("system")
local base64 = require("base64")
local json = require("json")
local bounds = require("bounds")
local artifact = require("artifact")
local publisher = require("publisher")
local author = require("author")
local staging = require("staging")
local activations = require("activation_store")
local resources = require("resources")
local transaction = require("transaction")
local materializer = require("materializer")
local application_admission = require("application_admission")
local publication_profiles = require("publication_profiles")
local activation_profiles = require("activation_profiles")
local workspace_applications = require("workspace_applications")
local capability_grants = require("capability_grants")
local capability_model = require("capability_model")

local M = {}
M.BACKEND = "bee.gov.binding:publication_backend_call"
M.EXECUTE = "bee.gov.publication.execute"
M.SCOPE = "bee.gov.security:publication_execution_scope"
function M.required_action(operation: unknown): string?
    if operation == "prepare" then return "bee.gov.delivery.manage" end
    if operation == "publish" then return "bee.gov.delivery.publish" end
    return nil
end
type Object = {[string]: unknown}
type Profile = publication_profiles.Profile
type Result = transaction.Result

local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end

-- The delivery path consumes exactly one frozen file: entries.json, a JSON list
-- of complete registry entries. A frozen overlay that cannot become an
-- application is refused here, at the step where that truth is decided, with a
-- named code and the remedy the author needs. The remedy is carried in the
-- failure value under the field name the destination's own diagnostics use
-- (modules/gov/src/binding/preflight.lua), so one reader handles both.
local MISSING_ARTIFACT_REMEDY = "freeze an overlay that holds entries.json, a JSON list of complete "
    .. "registry entries; read the overlay tool's guide operation for this destination's contract "
    .. "and one minimal example"
local INVALID_ARTIFACT_REMEDY = "write entries.json as a JSON list of complete registry entries, each "
    .. "with id, kind and a data object; read the overlay tool's guide operation for the exact shape "
    .. "and one minimal example"

local function refusal(code: string, message: string, remedy: string): Result
    return transaction.failure(code, message, {remedy = remedy})
end

-- Exposed so a unit test can pin the named code and remedy without standing up
-- a live workspace. This is the same refusal prepare returns.
function M.artifact_refusal(code: string, message: string?): Result
    local remedy = code == "MISSING_ARTIFACT" and MISSING_ARTIFACT_REMEDY or INVALID_ARTIFACT_REMEDY
    return refusal(code, message or (code == "MISSING_ARTIFACT"
        and "the frozen overlay holds no entries.json"
        or "authored entries are not a JSON list"), remedy)
end

local function load(): (publication_profiles.Configuration?, string?)
    local entry, entry_error = resources.publication_profiles()
    if not entry then return nil, tostring(entry_error or "publication profiles are unavailable") end
    local activation_entry, activation_error = resources.activation_profiles()
    if not activation_entry then return nil, tostring(activation_error) end
    local activation, decode_error = activation_profiles.decode(activation_entry.data)
    if not activation then return nil, tostring(decode_error) end
    local node, node_error = system.node.id()
    if not node then return nil, tostring(node_error) end
    return publication_profiles.configuration(entry.data, activation, node)
end

-- Returns the measured artifact, or a named refusal code with its reason. The
-- code distinguishes a snapshot with no entries.json at all from one whose
-- entries.json cannot become a registry artifact, so the caller can hand the
-- author the matching remedy.
function M.snapshot_artifact(raw: unknown): (unknown?, string?, string?)
    local reply = bounds.object(raw)
    local value = reply and bounds.object(reply.value) or nil
    if not reply or reply.ok ~= true or not value or value.path ~= "entries.json"
        or type(value.content_base64) ~= "string" then
        return nil, "the frozen overlay holds no entries.json", "MISSING_ARTIFACT"
    end
    local bytes, decode_error = base64.decode(value.content_base64)
    if not bytes or decode_error then return nil, "decode authored entries: " .. tostring(decode_error), "INVALID_ARTIFACT" end
    local decoded, json_error = json.decode(bytes)
    if json_error or type(decoded) ~= "table" then return nil, "authored entries are not a JSON list", "INVALID_ARTIFACT" end
    local measured, artifact_error = artifact.create(decoded)
    if not measured then return nil, artifact_error or "authored entries are invalid", "INVALID_ARTIFACT" end
    return measured, nil, nil
end

-- Publication transfers the portable artifact only, after proving that the
-- complete local overlay (including its private derived admission entry) is
-- still the exact settled intent.
local function publish_intent(raw: unknown, profile: Profile, node_id: string,
    workspace_id: string, version: string): (Object?, {unknown}?, Object?, string?)
    local intent = bounds.object(raw)
    if not intent or intent.phase ~= "settled" or intent.outcome ~= "applied"
        or intent.overlay_owner ~= profile.overlay_owner or intent.source_node ~= node_id
        or intent.source_workspace ~= profile.source_workspace or intent.workspace_id ~= workspace_id
        or intent.version ~= version then
        return nil, nil, nil, "only the exact locally reviewed and applied version can be published"
    end
    local entries, artifact_error = artifact.decode(intent.artifact_bytes, intent.artifact_digest)
    if not entries then return nil, nil, nil, tostring(artifact_error or "decode immutable publication artifact") end
    for _, entry in ipairs(entries) do
        if application_admission.reserved(entry.id) then
            return nil, nil, nil, "portable artifact entry uses a reserved application admission identity"
        end
    end
    local bytes, digest = intent.application_admission_bytes, intent.application_admission_digest
    if bytes == nil and digest == nil then return intent, entries, nil, nil end
    if type(bytes) ~= "string" or type(digest) ~= "string" then
        return nil, nil, nil, "immutable application admission blob is incomplete"
    end
    local measured, admission_error = application_admission.decode(bytes, digest, intent.application_admission_generation)
    if not measured then return nil, nil, nil, tostring(admission_error) end
    local record = measured.record
    if record.workspace_id ~= workspace_id or record.overlay_owner ~= profile.overlay_owner
        or record.source_node ~= node_id or record.source_workspace ~= profile.source_workspace
        or record.artifact_digest ~= intent.artifact_digest then
        return nil, nil, nil, "immutable application admission does not match publication identity"
    end
    return intent, entries, {bytes = measured.bytes, digest = measured.digest, identity_generation = intent.application_admission_generation}, nil
end

local function same_intent(before: Object, after: Object): boolean
    for _, field in ipairs({"intent_id", "revision", "phase", "outcome", "overlay_owner", "source_node",
        "source_workspace", "workspace_id", "version", "artifact_bytes", "artifact_digest",
        "application_admission_bytes", "application_admission_digest"}) do
        if before[field] ~= after[field] then return false end
    end
    return true
end

-- The Sessions contract answers for the caller's own session; the definition's
-- registry entry titles the agent.
local function session_source(caller: security.Actor): author.Source
    return {
        session = function(id: string): unknown
            local definition = contract.get("bee.threads.sessions:contract")
            if not definition then return nil end
            local acted = definition:with_actor(caller)
            if not acted then return nil end
            local owner = acted:open()
            if not owner then return nil end
            local reply = bounds.object(owner:get({session = id}))
            local value = reply and reply.ok == true and bounds.object(reply.value) or nil
            return value and value.value or nil
        end,
        title = function(ref: string): string?
            local entry = registry.get(ref)
            local data = entry and bounds.object(entry.data)
            return data and bounds.line(data.title, author.MAX_NAME) or nil
        end,
    }
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
    if not actor or not security.can(M.EXECUTE, M.BACKEND) then
        return failure("DENIED", "application publication is not authorized")
    end
    local config, config_error = load()
    if not config then return failure("UNAVAILABLE", config_error or "publication configuration is unavailable") end
    local node_id, node_error = system.node.id()
    local governance_resource, governance_error = resources.database()
    if not node_id or node_error or not governance_resource then
        return failure("UNAVAILABLE", tostring(node_error or governance_error or "publication storage is unavailable"))
    end
    local source_store, open_error = staging.open(governance_resource, node_id)
    if not source_store then return failure("UNAVAILABLE", open_error or "open authored overlay store") end
    local sources, sources_error = staging.sources(source_store)
    source_store:close()
    if not sources then return failure("UNAVAILABLE", sources_error or "read authored overlays") end
    local chosen, refused = publication_profiles.for_component(config, workspace_id, component, sources)
    if not chosen then
        local reason = refused or {message = "publication profile is unavailable", remedy = ""}
        return refusal("BLOCKED", reason.message, reason.remedy)
    end

    if request.operation == "prepare" then
        local store, open_error = staging.open(governance_resource, node_id)
        if not store then return failure("UNAVAILABLE", open_error or "open overlay") end
        local read = store:read_frozen(chosen.source_workspace, "entries.json", assert(snapshot_digest))
        store:close()
        local authored, authored_error, authored_code = M.snapshot_artifact(read)
        local value = bounds.object(authored)
        if not value then
            -- A workspace that cannot become an application is refused with a
            -- named code and the remedy for exactly that diagnosis.
            return M.artifact_refusal(authored_code or "INVALID_ARTIFACT", authored_error)
        end
        return publisher.prepare(node_id, {source_workspace = chosen.source_workspace,
            component = chosen.component, version = selected_version,
            author = author.name(actor:id(), session_source(actor)),
            artifact = {bytes = value.bytes, digest = value.digest}})
    end

    local activation_store, activation_error = activations.open(governance_resource, node_id, workspace_id)
    if not activation_store then return failure("UNAVAILABLE", activation_error or "open application activation state") end
    local active: Profile = chosen
    local identity = workspace_applications.identity(workspace_id, chosen.source_workspace)
    local prior_owner = workspace_applications.prior_owner(workspace_id, chosen.source_workspace)
    if identity and prior_owner and chosen.overlay_owner == identity.overlay_owner then
        local prior = activations.desired(activation_store, prior_owner)
        if prior.ok then active.overlay_owner = prior_owner
        elseif prior.code ~= "NOT_FOUND" then
            activations.close(activation_store)
            return failure("UNAVAILABLE", prior.message or "read prior application activation")
        end
    end
    local desired = activations.desired(activation_store, active.overlay_owner)
    local intent, entries, admission, intent_error = publish_intent(desired.ok and desired.value or nil,
        active, node_id, workspace_id, selected_version)
    if not intent or not entries then activations.close(activation_store); return failure("BLOCKED", intent_error or "read immutable activation intent") end
    -- A workspace application's overlay also holds the host entries its live
    -- grant record installed; the comparison includes exactly those.
    local generated: Object? = nil
    if identity and (active.overlay_owner == identity.overlay_owner or active.overlay_owner == prior_owner) then
        local record_id = active.overlay_owner == prior_owner and capability_grants.prior_record_id(active.overlay_owner)
            or capability_grants.record_id(active.overlay_owner)
        local installed = record_id and registry.get(record_id) or nil
        if installed then
            local raw_catalog = registry.get("bee.capability:catalog")
            local vocabulary, catalog_error = capability_model.decode(raw_catalog)
            local record, record_error = vocabulary and capability_grants.decode(installed, active.overlay_owner,
                workspace_id, (bounds.object(installed) and bounds.object((bounds.object(installed)).data) or {}).application, vocabulary) or nil
            local live, live_error = false, nil
            if record then
                live, live_error = capability_grants.live(record, function(id: string): unknown return registry.get(id) end)
            end
            if not record or not live then
                activations.close(activation_store)
                return failure("BLOCKED", tostring(catalog_error or record_error or live_error or "installed grant is not live"))
            end
            generated = capability_grants.installed(installed, record)
        end
    end
    local matches, match_error = materializer.matches_composed(active.overlay_owner, entries, admission, generated)
    if matches == nil then activations.close(activation_store); return failure("UNAVAILABLE", tostring(match_error)) end
    if matches ~= true then activations.close(activation_store); return failure("BLOCKED", "complete applied overlay no longer matches its immutable intent") end
    -- Fence the immutable record after observing the overlay.  A superseding
    -- activation cannot publish bytes that were only valid for the prior slot.
    local fenced = activations.desired(activation_store, active.overlay_owner)
    activations.close(activation_store)
    local current, _, _, fence_error = publish_intent(fenced.ok and fenced.value or nil,
        active, node_id, workspace_id, selected_version)
    if not current or not same_intent(intent, current) then
        return failure("BLOCKED", fence_error or "applied activation changed before publication")
    end
    return publisher.publish(node_id, {source_workspace = chosen.source_workspace,
        component = chosen.component, version = selected_version,
        author = author.name(actor:id(), session_source(actor)),
        artifact = {bytes = intent.artifact_bytes, digest = intent.artifact_digest}})
end

return M
