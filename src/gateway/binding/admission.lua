-- MIT. Admission for the gateway authority.
local uuid = require("uuid")
local json = require("json")
local security = require("security")
local system = require("system")
local bounds = require("bounds")
local hooks = require("hooks")
local mcp = require("mcp")
local surface = require("surface")
local trait_access = require("trait_access")
local session_traits = require("session_traits")
local surface_store = require("surface_store")
local binding_store = require("binding_store")
local hook_store = require("hook_store")
local access = require("access")
local part_listener = require("part_listener")
local part_model = require("part_model")
local part_records = require("part_records")
local part_surfaces = require("part_surfaces")
local part_values = require("part_values")
local M = {}
type Reply = part_model.Reply
type OriginView = part_model.OriginView
type Binding = part_model.Binding
local fail = part_values.fail
local succeed = part_values.succeed
local now_ms = part_values.now_ms
local stamp = part_values.stamp
local actor = part_values.actor
local integer = part_values.integer
local open = part_values.open
local digest_of = part_values.digest_of
local binding_of = part_records.binding_of
local view = part_records.view
local binding_by_id = part_records.binding_by_id
local listener_of = part_listener.listener_of
local synchronize_native_listener = part_listener.synchronize_native_listener
-- Resolve the durable gateway context for an approved effect. The stored
-- attempt identity, rather than proposal fields, supplies the binding that
-- the effect worker verifies. The caller names the tools the binding must
-- grant; an omitted list keeps the installation tools.
function M.effect_binding(value: unknown): Reply
    if not security.can(part_model.INSTALLATION_WORK, "resolve_binding") then
        return fail("DENIED", "caller may not resolve effect bindings")
    end
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"binding_id", "tools"}) then
        return fail("INVALID", "binding_id is required with optional tools")
    end
    local binding_id = bounds.id(object.binding_id)
    if not binding_id then return fail("INVALID", "binding_id is not an identifier") end
    local required: {string} = {"install_request", "uninstall_request"}
    if object.tools ~= nil then
        local named = bounds.ids(object.tools)
        if named and #named >= 1 and #named <= part_model.MAX_TOOLS then
            required = named
        else
            return fail("INVALID", "tools must name one or more tools")
        end
    end
    local db, open_failure = open()
    if not db then return open_failure or fail("STORAGE", "open binding store") end
    local binding, missing = binding_by_id(db, binding_id)
    db:release()
    if not binding then return missing or fail("NOT_FOUND", "binding does not exist") end
    local granted = false
    for _, tool in ipairs(binding.tools) do
        for _, need in ipairs(required) do
            if tool == need then granted = true end
        end
    end
    if not granted or not binding.workspace_id then
        return fail("DENIED", "binding has no effect authority or workspace")
    end
    return succeed({binding_id = binding.binding_id, subject = binding.subject, action_id = binding.action_id,
        attempt_id = binding.attempt_id, thread_id = binding.thread_id, workspace_id = binding.workspace_id})
end
-- admit: binds the admitted subject, action, attempt, thread, owner
-- incarnation, the carrier's epoch, tools and expiry. No token exists yet:
-- bytes are minted only when placement materializes them. The caller holds
-- bee.gateway.admit on the action and names the subject the launch
-- admission established; it cannot widen the tool set beyond the catalog.
local function admission_reply(binding: Binding, raw: unknown, replayed: boolean): Reply
    local declaration = assert(bounds.object(raw))
    local access = bounds.object(declaration.access)
    local gated = access and bounds.ids(access.traits, true) or {}
    local seeds: {string} = {}
    for _, id in ipairs(bounds.ids(declaration.active_traits, true) or {}) do
        if bounds.member(id, gated or {}) then seeds[#seeds + 1] = id end
    end
    local pending: {string} = {}
    if #seeds > 0 then
        local seed_db, seed_failure = open()
        if not seed_db then return seed_failure end
        local seed_tx, seed_error = seed_db:begin()
        if not seed_tx then seed_db:release(); return fail("STORAGE", tostring(seed_error)) end
        local saved, saved_error = surface_store.saved_consent(seed_tx, binding.binding_id, binding.workspace_id, declaration, now_ms())
        if not saved then seed_tx:rollback(); seed_db:release(); return fail("DENIED", saved_error and saved_error.message or "read saved consent") end
        for _, id in ipairs(seeds) do
            local existing, err = session_traits.read(seed_tx, trait_access.session(binding), id)
            if err then seed_tx:rollback(); seed_db:release(); return fail("STORAGE", err) end
            if not existing and not bounds.member(id, saved) then pending[#pending + 1] = id end
        end
        seed_tx:rollback()
        seed_db:release()
    end
    local approval_id: string? = nil
    if #pending > 0 then
        local requested = part_surfaces.request_access(binding, {idempotency_key = "profile-traits", traits = pending, reason = "This session's profile selects these application traits."})
        if not requested.ok then return requested end
        local requested_value = bounds.object(requested.value)
        approval_id = requested_value and bounds.id(requested_value.approval_id)
    end
    local current, surface_error = part_surfaces.surface(binding)
    if not current then return surface_error or fail("STORAGE", "binding surface is unavailable") end
    return succeed({binding = view(binding), replayed = replayed, trait_approval_id = approval_id})
end
function M.admit(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"subject", "action_id", "attempt_id", "thread_id", "owner_incarnation", "carrier_epoch", "tools", "hooks", "ttl_ms", "idempotency_key", "surface", "policy_ref", "workspace_id", "workspace_name", "origin_view"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local subject, action_id, attempt_id, thread_id = bounds.id(object.subject), bounds.id(object.action_id), bounds.id(object.attempt_id), bounds.id(object.thread_id)
    -- The launch policy the attempt ran under, recorded as attribution in the
    -- tool call context. It conveys no authority.
    local policy_ref: string? = nil
    if object.policy_ref ~= nil then
        policy_ref = bounds.id(object.policy_ref)
        if not policy_ref then return fail("INVALID", "policy_ref is not an identifier") end
    end
    local workspace_id: string? = nil
    if object.workspace_id ~= nil then
        workspace_id = bounds.id(object.workspace_id)
        if not workspace_id then return fail("INVALID", "workspace_id is not an identifier") end
    end
    local origin_view: OriginView? = nil
    if object.origin_view ~= nil then
        local declared = bounds.object(object.origin_view)
        if not declared or bounds.fields(declared, {"view_id", "instance_id"}) then return fail("INVALID", "origin_view must contain only view_id and instance_id") end
        local view_id, instance_id = bounds.id(declared.view_id), bounds.id(declared.instance_id)
        if not view_id or not instance_id then return fail("INVALID", "origin_view needs view_id and instance_id identifiers") end
        origin_view = {view_id = view_id, instance_id = instance_id}
    end
    if not subject then return fail("INVALID", "subject is not an identifier") end
    if not action_id then return fail("INVALID", "action_id is not an identifier") end
    local workspace_name = action_id:sub(-80)
    if object.workspace_name ~= nil then
        local named = bounds.line(object.workspace_name, 80)
        if not named or named:match("^%s*$") then return fail("INVALID", "workspace_name must be one printable line of at most 80 bytes") end
        workspace_name = named
    end
    if not attempt_id then return fail("INVALID", "attempt_id is not an identifier") end
    if not thread_id then return fail("INVALID", "thread_id is not an identifier") end
    local incarnation = integer(object.owner_incarnation)
    if not incarnation or incarnation < 1 then return fail("INVALID", "owner_incarnation must be a positive integer") end
    local carrier_epoch = integer(object.carrier_epoch)
    if not carrier_epoch or carrier_epoch < 1 then return fail("INVALID", "carrier_epoch must be a positive integer") end
    local tools, tools_error = bounds.ids(object.tools, true)
    if not tools then return fail("INVALID", "tools: " .. tostring(tools_error)) end
    if #tools > part_model.MAX_TOOLS then return fail("INVALID", "tools exceeds " .. tostring(part_model.MAX_TOOLS) .. " tools") end
    local selected_surface: unknown = object.surface
    if selected_surface == nil then
        selected_surface = {tools = {}, traits = {}, base_tools = tools, active_traits = {}, fixed_context = {}, dynamic_keys = {}}
    end
    local prepared, initial, surface_error = surface.prepare(selected_surface, mcp.TOOLS, tools, workspace_id)
    if not prepared or not initial then return fail("INVALID", surface_error or "invalid MCP surface") end
    local surface_json, surface_encode_error = json.encode(selected_surface)
    if not surface_json or surface_encode_error or #surface_json > 131072 then return fail("INVALID", "MCP surface exceeds storage bound") end
    table.sort(tools)
    -- Hook events the binding admits, from the closed catalog; a binding
    -- without them gets no hook credential.
    local admitted_hooks: {string} = {}
    if object.hooks ~= nil then
        local declared, hooks_error = bounds.ids(object.hooks, true)
        if not declared then return fail("INVALID", "hooks: " .. tostring(hooks_error)) end
        if #declared > #hooks.EVENTS then return fail("INVALID", "hooks names more events than the catalog holds") end
        for _, name in ipairs(declared) do
            if not hooks.known(name) then return fail("INVALID", "hook " .. name .. " is not in the gateway catalog") end
        end
        table.sort(declared)
        admitted_hooks = declared
    end
    if #tools == 0 and #admitted_hooks == 0 then return fail("INVALID", "binding needs tools or hooks") end
    local ttl = part_model.DEFAULT_TTL_MS
    if object.ttl_ms ~= nil then
        local declared = bounds.integer(object.ttl_ms)
        if not declared or declared < 1 or declared > part_model.MAX_TTL_MS then return fail("INVALID", "ttl_ms must be between 1 and " .. tostring(part_model.MAX_TTL_MS)) end
        ttl = declared
    end
    local idempotency_key: string? = nil
    if object.idempotency_key ~= nil then
        idempotency_key = bounds.id(object.idempotency_key)
        if not idempotency_key then return fail("INVALID", "idempotency_key is not an identifier") end
    end
    local caller = actor()
    if not caller then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(part_model.ADMIT, action_id) then return fail("DENIED", "caller may not admit gateway bindings for action " .. action_id) end
    local request_digest, digest_error = digest_of({subject = subject, action_id = action_id, attempt_id = attempt_id, thread_id = thread_id, owner_incarnation = incarnation, carrier_epoch = carrier_epoch, tools = tools, hooks = admitted_hooks, surface = selected_surface, policy_ref = policy_ref, workspace_id = workspace_id, workspace_name = workspace_name, origin_view = origin_view})
    if not request_digest then return fail("INVALID", digest_error or "request is not measurable") end
    local db, open_failure = open()
    if not db then return open_failure end
    local synchronized, synchronization_error = synchronize_native_listener(db)
    if not synchronized then db:release(); return fail("UNAVAILABLE", synchronization_error or "native listener unavailable") end
    local listener, listener_error = listener_of(db)
    if listener_error then db:release(); return fail("STORAGE", listener_error) end
    if not listener then db:release(); return fail("UNAVAILABLE", "the gateway listener has not been opened") end
    local drained = bounds.count(listener.drained)
    if drained ~= 0 and drained ~= 1 then db:release(); return fail("STORAGE", "listener drain state is corrupt") end
    if drained == 1 then db:release(); return fail("UNAVAILABLE", "the gateway is draining; no new admissions") end
    local epoch = bounds.count(listener.epoch)
    if not epoch or epoch == 0 then db:release(); return fail("STORAGE", "listener epoch is corrupt") end
    if idempotency_key then
        local replay, replay_error = binding_store.by_idempotency_key(db, caller, idempotency_key)
        if replay_error or not replay then db:release(); return fail("STORAGE", "read bindings") end
        if #replay == 1 then
            local stored = replay[1]
            db:release()
            local binding, decode_error = binding_of(stored)
            if not binding then return fail("STORAGE", decode_error or "binding is corrupt") end
            if stored.request_digest ~= request_digest then return fail("CONFLICT", "idempotency key reused with a different request") end
            return admission_reply(binding, selected_surface, true)
        end
    end
    local binding_id, id_error = uuid.v7()
    if id_error or not binding_id then db:release(); return fail("STORAGE", "binding id") end
    local created = now_ms()
    -- Exactly one live binding per attempt and carrier epoch: the same
    -- admission replays it, a different one at the same epoch conflicts,
    -- and only a strictly newer carrier epoch supersedes what earlier
    -- epochs hold. The decision and the insert share one transaction.
    local tx, begin_error = db:begin()
    if not tx then db:release(); return fail("STORAGE", "begin admission") end
    -- An epoch below the highest the attempt was ever admitted under is a
    -- delayed admission from a fenced carrier, live binding or not.
    local highest_rows, highest_error = binding_store.highest_carrier_epoch(tx, attempt_id)
    if highest_error or not highest_rows then tx:rollback(); db:release(); return fail("STORAGE", "read bindings") end
    if #highest_rows ~= 1 then tx:rollback(); db:release(); return fail("STORAGE", "binding carrier epoch is corrupt") end
    local highest_raw = (bounds.object(highest_rows[1]) or {}).highest
    local highest = highest_raw == nil and nil or bounds.count(highest_raw)
    if highest_raw ~= nil and (highest == nil or highest == 0) then tx:rollback(); db:release(); return fail("STORAGE", "binding carrier epoch is corrupt") end
    if highest and carrier_epoch < highest then
        tx:rollback()
        db:release()
        return fail("CONFLICT", "carrier epoch " .. tostring(carrier_epoch) .. " is below the highest epoch " .. tostring(highest) .. " admitted for attempt " .. attempt_id)
    end
    local live, live_error = binding_store.live_at_carrier_epoch(tx, attempt_id, carrier_epoch)
    if live_error or not live then tx:rollback(); db:release(); return fail("STORAGE", "read bindings") end
    if #live > 0 then
        local stored = live[1]
        tx:rollback()
        db:release()
        local binding, decode_error = binding_of(stored)
        if not binding then return fail("STORAGE", decode_error or "binding is corrupt") end
        if stored.request_digest ~= request_digest then return fail("CONFLICT", "attempt " .. attempt_id .. " already holds a different binding under carrier epoch " .. tostring(carrier_epoch)) end
        return admission_reply(binding, selected_surface, true)
    end
    if workspace_id then
        local names, name_error = binding_store.workspace_name_conflict(tx, workspace_id, workspace_name, action_id, epoch)
        if name_error or not names then tx:rollback(); db:release(); return fail("STORAGE", "read workspace session names") end
        if #names > 0 then tx:rollback(); db:release(); return fail("CONFLICT", "workspace_name is already assigned to another live action") end
    end
    -- A claimed row may already be in the thread even though its later
    -- acknowledgement was lost. Supersession fences future intake, but it
    -- cannot truthfully reject that durable uncertainty; a replacement can
    -- reclaim the row under its newer carrier epoch.
    local _, reject_superseded = hook_store.reject_superseded(tx, stamp(created), attempt_id, carrier_epoch)
    if reject_superseded then tx:rollback(); db:release(); return fail("STORAGE", "reject superseded hooks") end
    local _, supersede_error = binding_store.supersede_older(tx, stamp(created), attempt_id, carrier_epoch)
    if supersede_error then tx:rollback(); db:release(); return fail("STORAGE", "supersede earlier bindings") end
    local origin_json = origin_view and json.encode(origin_view) or ""
    if origin_view and not origin_json then tx:rollback(); db:release(); return fail("INVALID", "origin_view is not JSON") end
    local _, insert_error = binding_store.insert(tx, binding_id, subject, action_id, attempt_id, thread_id, incarnation, carrier_epoch,
        json.encode(tools), json.encode(admitted_hooks), epoch, stamp(created + ttl), ttl, idempotency_key, request_digest, stamp(created),
        policy_ref or "", workspace_id or "", workspace_name, origin_json)
    if insert_error then tx:rollback(); db:release(); return fail("STORAGE", "record binding") end
    local authorized_surface, authority_error = surface_store.bind_authority(tx,assert(system.node.id()),workspace_id,subject,binding_id,assert(bounds.object(selected_surface)),policy_ref)
    if not authorized_surface then tx:rollback(); db:release(); return fail("STORAGE",authority_error and authority_error.message or "record surface authority") end
    surface_json = authorized_surface
    local saved, saved_error = surface_store.saved_consent(tx, binding_id, workspace_id, assert(bounds.object(selected_surface)), created)
    if not saved then tx:rollback(); db:release(); return fail("DENIED", saved_error and saved_error.message or "read saved consent") end
    for _, id in ipairs(saved) do if not bounds.member(id, initial.active) then initial.active[#initial.active + 1] = id end end
    local initialized, initialize_error = surface_store.initialize(tx, binding_id, surface_json, json.encode(initial.active) or "[]", "{}")
    if not initialized then tx:rollback(); db:release(); return fail("STORAGE", initialize_error and initialize_error.message or "record binding surface") end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then return fail("STORAGE", "commit admission") end
    local binding: Binding = {binding_id = binding_id, subject = subject, action_id = action_id, attempt_id = attempt_id, thread_id = thread_id, owner_incarnation = incarnation,
        carrier_epoch = carrier_epoch, tools = tools, hooks = admitted_hooks, epoch = epoch, credential_generation = 0, expires_at = stamp(created + ttl), revoked = false, sealed = false, policy_ref = policy_ref, workspace_id = workspace_id, workspace_name = workspace_name, origin_view = origin_view}
    return admission_reply(binding, selected_surface, false)
end
return M
