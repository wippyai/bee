-- MIT. Destination reconciliation: boot recovery of desired activations and the source following pass.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local transaction = require("transaction")
local resources = require("resources")
local replicas = require("replicas")
local activations = require("activation_store")
local owner = require("activation_owner")
local delivery = require("delivery")
local destination = require("destination")
local materializer = require("materializer")
local state_guard = require("state_guard")
local capability_files = require("capability_files")
local follows = require("follow_store")
local follower = require("follow_source")
local follow_wake = require("follow_wake")
local M = {}
local part_destination_inspection = require("part_destination_inspection")
type Object = part_destination_inspection.Object
type Result = part_destination_inspection.Result
local failure = part_destination_inspection.failure
local load = part_destination_inspection.load
local selected = part_destination_inspection.selected
local part_destination_policy = require("part_destination_policy")
local owner_config = part_destination_policy.owner_config
local part_destination_stores = require("part_destination_stores")
local stores = part_destination_stores.stores
local close = part_destination_stores.close

-- Boot recovery follows only already-authorized desired intents. It never
-- reviews, selects or creates an approval request. A slot whose source the
-- host does not select for that owner stays unrestored.
-- Governance refuses a restoration whose approval does not cover the host
-- state; that overlay stays unrestored and its intent stays for the person to
-- review again. A generation whose stored artifact the current host rules
-- reject settles blocked and is reported once. An application whose grant
-- opens a folder missing from the workspace stays out of this start and is
-- reported at each start until the folder returns; its intent is unchanged.
-- Only such refusals let recovery continue.
local REFUSALS: {[string]: boolean} = {CONFLICT = true, DENIED = true, MISSING = true}

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
            if recovered_value and recovered_value.phase == "settled" then
                if recovered_value.outcome == "blocked" and recovered.replayed ~= true then
                    refused[#refused + 1] = overlay_owner .. ": " .. tostring(recovered_value.diagnostics)
                end
                break
            end
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
