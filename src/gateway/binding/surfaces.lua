-- MIT. Surfaces for the gateway authority.
local hash = require("hash")
local json = require("json")
local security = require("security")
local bounds = require("bounds")
local configuration = require("configuration")
local hooks = require("hooks")
local mcp = require("mcp")
local surface = require("surface")
local catalog = require("catalog")
local trait_access = require("trait_access")
local agent_trait = require("agent_trait")
local session_traits = require("session_traits")
local surface_store = require("surface_store")
local binding_store = require("binding_store")
local access = require("access")
local part_model = require("part_model")
local part_values = require("part_values")
local M = {}
type Reply = part_model.Reply
type Binding = part_model.Binding
type BoundSurface = part_model.BoundSurface
type RuntimeGrant = part_model.RuntimeGrant
local fail = part_values.fail
local succeed = part_values.succeed
local now_ms = part_values.now_ms
local stamp = part_values.stamp
local integer = part_values.integer
local open = part_values.open
function M.surface(binding: Binding): (BoundSurface?, Reply?)
    local db, open_failure = open()
    if not db then return nil, open_failure end
    local tx, tx_error = db:begin()
    if not tx or tx_error then db:release(); return nil, fail("STORAGE", "open surface read") end
    local stored, read_error = surface_store.read(tx, binding.binding_id)
    local granted, grant_error = surface_store.grants(tx, binding.binding_id,now_ms())
    local declaration = stored and bounds.object(json.decode(stored.surface_json))
    local saved: {string} = {}
    if declaration then
        local consent, err = surface_store.saved_consent(tx, binding.binding_id, binding.workspace_id, declaration, now_ms())
        if not consent then tx:rollback(); db:release(); return nil, fail("DENIED", err and err.message or "saved profile consent is no longer active") end
        saved = consent
    end
    tx:rollback()
    db:release()
    if not stored then return nil, fail("STORAGE", read_error and read_error.message or "read surface") end
    if not granted then return nil, fail("STORAGE", grant_error and grant_error.message or "read grants") end
    local digest, digest_error = hash.sha256(stored.surface_json)
    if not digest then return nil, fail("STORAGE", tostring(digest_error)) end
    local raw, raw_error = json.decode(stored.surface_json)
    local active, active_error = json.decode(stored.active_json)
    local dynamic, dynamic_error = json.decode(stored.context_json)
    if raw_error or active_error or dynamic_error then return nil, fail("STORAGE", "binding surface JSON is corrupt") end
    local configured, _, config_error = surface.prepare(raw, mcp.TOOLS, binding.tools, binding.workspace_id)
    if not configured then return nil, fail("STORAGE", config_error or "binding surface is invalid") end
    local extensions: {[string]: boolean} = {}
    local known: {[string]: boolean} = {}
    for index, trait in ipairs(configured.catalog.traits) do
        known[trait.id] = true
        if agent_trait.extension(trait) then
            extensions[trait.id] = true
            local live = trait_access.load(trait.id)
            if live and (#(trait.listens or {}) > 0 or #(trait.hooks or {}) > 0) then configured.catalog.traits[index] = live end
        end
    end
    local binding_traits: {string} = {}
    for _, id in ipairs(saved) do if known[id] then binding_traits[#binding_traits + 1] = id end end
    for _, id in ipairs(granted) do if known[id] and not extensions[id] and not bounds.member(id, binding_traits) then binding_traits[#binding_traits + 1] = id end end
    if #binding_traits > 0 then
        local extended, extend_error = surface.grant(configured, binding_traits)
        if not extended then return nil, fail("STORAGE", extend_error or "invalid grant") end
        configured = extended
    end
    local session_db, session_failure = open()
    if not session_db then return nil, session_failure end
    local session_tx, session_error = session_db:begin()
    if not session_tx then session_db:release(); return nil, fail("STORAGE", tostring(session_error)) end
    local session_allowed, session_active, trait_error = session_traits.selection(session_tx, trait_access.session(binding), binding.thread_id, binding.workspace_id or "", configured.catalog.traits)
    if not session_allowed or not session_active then session_tx:rollback(); session_db:release(); return nil, fail("STORAGE", trait_error or "read session selection") end
    local _, commit_error = session_tx:commit()
    session_db:release()
    if commit_error then return nil, fail("STORAGE", "commit trait consent check") end
    if #session_allowed > 0 then
        local extended, err = surface.grant(configured, session_allowed)
        if not extended then return nil, fail("DENIED", err or "invalid trait grant") end
        configured = extended
    end
    local active_traits = bounds.ids(active,true)
    if not active_traits then return nil,fail("STORAGE","binding selection is invalid") end
    local allowed: {[string]: boolean} = {}
    for _, id in ipairs(configured.allowed_traits) do allowed[id] = true end
    local live: {string} = {}
    local extension: {[string]: boolean} = {}
    for _, trait in ipairs(configured.catalog.traits) do if agent_trait.extension(trait) then extension[trait.id] = true end end
    for _, id in ipairs(active_traits) do if allowed[id] and not extension[id] then live[#live + 1] = id end end
    for _, id in ipairs(session_active) do if allowed[id] then live[#live + 1] = id end end
    local selected, selection_error = surface.select(configured, live, dynamic)
    if not selected then return nil, fail("STORAGE", selection_error or "binding selection is invalid") end
    for _, trait in ipairs(configured.catalog.traits) do
        if agent_trait.extension(trait) and bounds.member(trait.id, selected.active) then
            local unsupported = trait_access.supported(trait, trait_access.session(binding), binding.workspace_id or "", binding.hooks)
            if unsupported then return nil, fail("UNSUPPORTED_CAPABILITY", unsupported) end
        end
    end
    return {configuration = configured, selection = selected, revision = stored.revision, digest = digest}, nil
end
-- An application-open call is admitted only through the active built-in
-- runtime trait.  Access receipts are immutable effects; more than one may
-- legitimately contain the same trait after separate approved requests.  We
-- choose the lexicographically first approval ID under an explicit SQL order,
-- so a retried call carries stable provenance without inventing a second grant.
-- Any malformed receipt remains a storage failure, including one unrelated to
-- the selected trait, because it makes the binding's durable grant history
-- untrustworthy.
function M.application_runtime(binding: Binding, current: BoundSurface): (RuntimeGrant?, Reply?)
    local trait = mcp.APPLICATION_RUNTIME_TRAIT.id
    local configured = false
    local access = current.configuration.access
    if access then
        for _, id in ipairs(access.traits) do if id == trait then configured = true end end
    end
    if not configured then return nil, fail("DENIED", "application runtime access is not configured") end
    local active = false
    for _, id in ipairs(current.selection.active) do if id == trait then active = true end end
    if not active then return nil, fail("DENIED", "application runtime access is not active") end
    local db, open_failure = open()
    if not db then return nil, open_failure end
    local tx, begin_error = db:begin()
    if not tx or begin_error then db:release(); return nil, fail("STORAGE", "open application runtime access receipt") end
    local receipt, receipt_error = surface_store.runtime_grant(tx, binding.binding_id, trait,now_ms())
    tx:rollback()
    db:release()
    if receipt_error then return nil, fail(receipt_error.code, receipt_error.message) end
    if not receipt then return nil, fail("DENIED", "application runtime access has no approved receipt") end
    return {access_approval_id = receipt.approval_id, access_proposal_digest = receipt.proposal_digest,
        surface_revision = current.revision, surface_digest = current.digest}, nil
end
-- Only the authenticated HTTP handler invokes this library operation. The
-- binding row is rechecked inside the transaction before changing selection.
function M.select_surface(binding: Binding, expected_revision: integer, active: unknown, dynamic: unknown): Reply
    local current, current_error = M.surface(binding)
    if not current then return current_error or fail("STORAGE", "read surface") end
    local selected, selected_error = surface.select(current.configuration, active, dynamic)
    if not selected then return fail("INVALID", selected_error or "invalid selection") end
    local active_json, active_error = json.encode(selected.active)
    local context_json, context_error = json.encode(selected.context)
    if not active_json or active_error or not context_json or context_error then return fail("INVALID", "selection is not JSON") end
    local db, open_failure = open()
    if not db then return open_failure or fail("STORAGE", "open surface") end
    local tx, tx_error = db:begin()
    if not tx or tx_error then db:release(); return fail("STORAGE", "open surface mutation") end
    local rows, read_error = binding_store.access_authority(tx, binding.binding_id)
    if not rows or read_error or #rows ~= 1 then tx:rollback(); db:release(); return fail("STORAGE", "read binding") end
    local row = bounds.object(rows[1])
    if not row or row.revoked_at ~= nil or integer(row.credential_generation) ~= binding.credential_generation then
        tx:rollback(); db:release(); return fail("DENIED", "binding was revoked or credential replaced")
    end
    local trait_error = session_traits.select(tx, trait_access.session(binding), binding.thread_id, binding.workspace_id or "", current.configuration.catalog.traits, selected.active)
    if trait_error then tx:rollback(); db:release(); return fail("DENIED", trait_error) end
    local updated, update_error = surface_store.replace(tx, binding.binding_id, expected_revision, active_json, context_json)
    if not updated then tx:rollback(); db:release(); return fail(update_error and update_error.code or "STORAGE", update_error and update_error.message or "update surface") end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then return fail("STORAGE", "commit surface selection") end
    return succeed({revision = updated.revision, active_traits = selected.active, context = selected.context})
end
-- These methods are called only after bearer authentication by the MCP endpoint.
function M.request_access(binding: Binding, request: unknown): Reply
    local current, failure = M.surface(binding)
    if not current then return failure or fail("STORAGE", "read surface") end
    return access.request(binding, current.configuration, current.digest, request)
end
function M.access_status(binding: Binding, approval_id: string): Reply
    local current, failure = M.surface(binding)
    if not current then return failure or fail("STORAGE", "read surface") end
    local grant, pending = access.approved(binding, current.configuration, current.digest, approval_id)
    if not grant then return pending or fail("UNAVAILABLE", "approval status missing") end
    local db, open_failure = open()
    if not db then return open_failure or fail("STORAGE", "read access receipt") end
    local receipts, err = surface_store.receipt(db, binding.binding_id, approval_id)
    db:release()
    if not receipts or err then return fail("STORAGE", "read access receipt") end
    return succeed({approval_id = approval_id, status = #receipts > 0 and "granted" or "approved", revision = current.revision, traits = grant.traits})
end
function M.apply_access(binding: Binding, approval_id: string): Reply
    if not security.can("bee.approvals.own", "gateway.access") then return fail("DENIED", "only the access effect consumer applies decisions") end
    local current, failure = M.surface(binding)
    if not current then return failure or fail("STORAGE", "read surface") end
    local receipt_db, receipt_failure = open()
    if not receipt_db then return receipt_failure or fail("STORAGE", "read access receipt") end
    local receipts, receipt_error = surface_store.receipt(receipt_db, binding.binding_id, approval_id)
    receipt_db:release()
    if not receipts or receipt_error then return fail("STORAGE", "read access receipt") end
    if #receipts > 0 then
        local receipt = bounds.object(receipts[1])
        local encoded = receipt and bounds.text(receipt.traits_json, 8192)
        if not encoded then return fail("STORAGE", "invalid access receipt") end
        local raw, decode_error = json.decode(encoded)
        local traits = bounds.ids(raw, true)
        if not traits or decode_error then return fail("STORAGE", "invalid access receipt traits") end
        return succeed({approval_id = approval_id, status = "granted", revision = current.revision, traits = traits})
    end
    local grant, pending = access.approved(binding, current.configuration, current.digest, approval_id)
    if not grant then return pending or fail("UNAVAILABLE", "approval status missing") end
    local encoded, encode_error = json.encode(grant.traits)
    if not encoded or encode_error then return fail("STORAGE", "encode grant") end
    local db, open_failure = open()
    if not db then return open_failure or fail("STORAGE", "open grant store") end
    local tx, tx_error = db:begin()
    if not tx or tx_error then db:release(); return fail("STORAGE", "begin grant") end
    local rows, read_error = binding_store.surface_authority(tx, binding.binding_id)
    local row = rows and bounds.object(rows[1])
    local expires = row and bounds.text(row.expires_at)
    if read_error or not row or not expires or row.revoked_at ~= nil or row.sealed_at ~= nil or expires <= stamp(now_ms())
        or integer(row.credential_generation) ~= binding.credential_generation then
        tx:rollback(); db:release(); return fail("DENIED", "agent binding is no longer current")
    end
    local stored, stored_error = surface_store.read(tx, binding.binding_id)
    if not stored then tx:rollback(); db:release(); return fail("STORAGE", stored_error and stored_error.message or "read surface") end
    local digest = hash.sha256(stored.surface_json)
    if digest ~= current.digest then tx:rollback(); db:release(); return fail("CONFLICT", "MCP declaration changed") end
    local trait_error = session_traits.approve(tx, grant.approval_id .. ":grant")
    if trait_error then tx:rollback(); db:release(); return fail("DENIED", trait_error) end
    local updated, update_error = surface_store.grant(tx, binding.binding_id, grant.approval_id, grant.proposal_digest, encoded,now_ms())
    if not updated then tx:rollback(); db:release(); return fail(update_error and update_error.code or "STORAGE", update_error and update_error.message or "apply grant") end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then return fail("STORAGE", "grant commit outcome unknown; retry the same approval") end
    return succeed({approval_id = approval_id, status = "granted", revision = updated.revision, traits = grant.traits})
end
return M
