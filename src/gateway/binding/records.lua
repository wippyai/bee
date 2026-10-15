-- MIT. Records for the gateway authority.
local sql = require("sql")
local time = require("time")
local json = require("json")
local bounds = require("bounds")
local hooks = require("hooks")
local binding_store = require("binding_store")
local part_model = require("part_model")
local part_values = require("part_values")
local M = {}
type Reply = part_model.Reply
type Row = part_model.Row
type Object = part_model.Object
type OriginView = part_model.OriginView
type Binding = part_model.Binding
local FORMAT = part_values.FORMAT
local fail = part_values.fail
local integer = part_values.integer
local optional_text = part_values.optional_text
local optional_timestamp = part_values.optional_timestamp
local function decode_origin_view(value: unknown): (OriginView?, string?)
    local encoded, valid = optional_text(value, 1024)
    if not valid then return nil, "binding origin view is corrupt" end
    if not encoded then return nil, nil end
    local decoded, decode_error = json.decode(encoded)
    if decode_error then return nil, "binding origin view is corrupt" end
    local object = bounds.object(decoded)
    if not object or bounds.fields(object, {"view_id", "instance_id"}) then return nil, "binding origin view is corrupt" end
    local view_id, instance_id = bounds.id(object.view_id), bounds.id(object.instance_id)
    if not view_id or not instance_id then return nil, "binding origin view is corrupt" end
    return {view_id = view_id, instance_id = instance_id}, nil
end
local function binding_of(row: Row): (Binding?, string?)
    local binding_id, subject = bounds.id(row.binding_id), bounds.id(row.subject)
    local action_id, attempt_id, thread_id = bounds.id(row.action_id), bounds.id(row.attempt_id), bounds.id(row.thread_id)
    local owner_incarnation = bounds.count(row.owner_incarnation)
    local carrier_epoch, epoch = bounds.count(row.carrier_epoch), bounds.count(row.epoch)
    local credential_generation = bounds.count(row.credential_generation)
    local tools_json, hooks_json = bounds.text(row.tools_json, 8192), bounds.text(row.hooks_json, 8192)
    local request_digest = bounds.text(row.request_digest, 64)
    local created_at = bounds.text(row.created_at, 64)
    local idempotency_key, idempotency_valid = optional_text(row.idempotency_key, 160)
    local created, created_error = time.parse(FORMAT, created_at or "")
    if not binding_id then return nil, "binding identity is corrupt" end
    if not subject then return nil, "binding identity is corrupt" end
    if not action_id then return nil, "binding identity is corrupt" end
    if not attempt_id then return nil, "binding identity is corrupt" end
    if not thread_id then return nil, "binding identity is corrupt" end
    if owner_incarnation == nil or owner_incarnation == 0 then return nil, "binding incarnation is corrupt" end
    if carrier_epoch == nil or carrier_epoch == 0 then return nil, "binding carrier epoch is corrupt" end
    if epoch == nil or epoch == 0 then return nil, "binding listener epoch is corrupt" end
    if credential_generation == nil then return nil, "binding credential generation is corrupt" end
    if not tools_json then return nil, "binding tools are corrupt" end
    if not hooks_json then return nil, "binding hooks are corrupt" end
    if not request_digest or #request_digest ~= 64 or not request_digest:match("^[0-9a-f]+$") then return nil, "binding request digest is corrupt" end
    if not created_at or created_error or not created then return nil, "binding creation time is corrupt" end
    if not idempotency_valid or (idempotency_key ~= nil and not bounds.id(idempotency_key)) then return nil, "binding idempotency key is corrupt" end
    local tools_raw, tools_error = json.decode(tools_json)
    local names = bounds.ids(tools_raw, true)
    if tools_error or not names or #names > part_model.MAX_TOOLS then return nil, "binding tools are corrupt" end
    local hooks_raw, hooks_error = json.decode(hooks_json)
    local hook_names = bounds.ids(hooks_raw, true)
    if hooks_error or not hook_names or #hook_names > #hooks.EVENTS then return nil, "binding hooks are corrupt" end
    for _, name in ipairs(hook_names) do
        if not hooks.known(name) then return nil, "binding hooks are corrupt" end
    end
    local expires_at = bounds.text(row.expires_at, 64)
    local expires, expires_error = time.parse(FORMAT, expires_at or "")
    if not expires_at then return nil, "binding expiry is corrupt" end
    if expires_error or not expires then return nil, "binding expiry is corrupt" end
    local revoked_at, revoked_valid = optional_timestamp(row.revoked_at)
    local sealed_at, sealed_valid = optional_timestamp(row.sealed_at)
    local policy_ref, policy_valid = optional_text(row.policy_ref, 160)
    local workspace_id, workspace_valid = optional_text(row.workspace_id, 160)
    local stored_name = bounds.line(row.workspace_name, 80)
    if not revoked_valid or not sealed_valid or not policy_valid or not workspace_valid or not stored_name then
        return nil, "binding optional fields are corrupt"
    end
    if stored_name:match("^%s*$") then return nil, "binding optional fields are corrupt" end
    if (policy_ref ~= nil and not bounds.id(policy_ref)) or (workspace_id ~= nil and not bounds.id(workspace_id)) then
        return nil, "binding references are corrupt"
    end
    local origin, origin_error = decode_origin_view(row.origin_view_json)
    if origin_error then return nil, origin_error end
    return {binding_id = binding_id, subject = subject, action_id = action_id, attempt_id = attempt_id,
        thread_id = thread_id, owner_incarnation = owner_incarnation, carrier_epoch = carrier_epoch, tools = names, hooks = hook_names,
        epoch = epoch, credential_generation = credential_generation, expires_at = expires_at, revoked = revoked_at ~= nil, sealed = sealed_at ~= nil,
        policy_ref = policy_ref, workspace_id = workspace_id, workspace_name = stored_name, origin_view = origin}, nil
end
local function view(binding: Binding): Object
    return {binding_id = binding.binding_id, subject = binding.subject, action_id = binding.action_id, attempt_id = binding.attempt_id, thread_id = binding.thread_id,
        owner_incarnation = binding.owner_incarnation, carrier_epoch = binding.carrier_epoch, tools = binding.tools, hooks = binding.hooks, epoch = binding.epoch,
        credential_generation = binding.credential_generation, expires_at = binding.expires_at, revoked = binding.revoked, sealed = binding.sealed, policy_ref = binding.policy_ref, workspace_id = binding.workspace_id, workspace_name = binding.workspace_name, origin_view = binding.origin_view}
end
local function binding_by_id(db: sql.DB | sql.Transaction, binding_id: string): (Binding?, Reply?)
    local rows, err = binding_store.by_id(db, binding_id)
    if err or not rows then return nil, fail("STORAGE", "read binding") end
    if #rows == 0 then return nil, fail("NOT_FOUND", "binding does not exist") end
    local binding, decode_error = binding_of(rows[1])
    if not binding then return nil, fail("STORAGE", decode_error or "binding is corrupt") end
    return binding, nil
end
-- The binding an attempt holds under a carrier epoch: the one issued at
-- the highest epoch not above it, so a replacement carrier that took over
-- a running child inherits the binding its child already holds. The live
-- one for materialization, the latest for a check that reports revocation.
local function binding_by_carrier(db: sql.DB, attempt_id: string, carrier_epoch: integer, live: boolean): (Binding?, Reply?)
    local rows, err = binding_store.by_carrier(db, attempt_id, carrier_epoch, live)
    if err or not rows then return nil, fail("STORAGE", "read binding") end
    if #rows == 0 then return nil, fail("NOT_FOUND", "no " .. (live and "live " or "") .. "binding for attempt " .. attempt_id .. " under carrier epoch " .. tostring(carrier_epoch)) end
    local binding, decode_error = binding_of(rows[1])
    if not binding then return nil, fail("STORAGE", decode_error or "binding is corrupt") end
    return binding, nil
end
-- The binding a request names: by id, or by the attempt and carrier epoch
-- the runner is attached under.
local function binding_named(db: sql.DB, object: Object): (Binding?, Reply?)
    if object.binding_id ~= nil then
        local binding_id = bounds.id(object.binding_id)
        if not binding_id then return nil, fail("INVALID", "binding_id is not an identifier") end
        return binding_by_id(db, binding_id)
    end
    local attempt_id = bounds.id(object.attempt_id)
    if not attempt_id then return nil, fail("INVALID", "attempt_id is not an identifier") end
    local carrier_epoch = integer(object.carrier_epoch)
    if not carrier_epoch or carrier_epoch < 1 then return nil, fail("INVALID", "carrier_epoch must be a positive integer") end
    return binding_by_carrier(db, attempt_id, carrier_epoch, false)
end
M.binding_by_carrier = binding_by_carrier
M.binding_by_id = binding_by_id
M.binding_named = binding_named
M.binding_of = binding_of
M.view = view
return M
