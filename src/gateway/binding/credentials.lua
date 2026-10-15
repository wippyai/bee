-- MIT. Credentials for the gateway authority.
local time = require("time")
local uuid = require("uuid")
local security = require("security")
local bounds = require("bounds")
local capability_model = require("capability_model")
local hooks = require("hooks")
local binding_store = require("binding_store")
local credential_store = require("credential_store")
local subject_call = require("subject_call")
local hook_store = require("hook_store")
local part_listener = require("part_listener")
local part_model = require("part_model")
local part_records = require("part_records")
local part_values = require("part_values")
local M = {}
type Reply = part_model.Reply
type Object = part_model.Object
type Binding = part_model.Binding
local FORMAT = part_values.FORMAT
local fail = part_values.fail
local succeed = part_values.succeed
local now_ms = part_values.now_ms
local stamp = part_values.stamp
local actor = part_values.actor
local integer = part_values.integer
local open = part_values.open
local token_hash = part_values.token_hash
local random_text = part_values.random_text
local optional_timestamp = part_values.optional_timestamp
local view = part_records.view
local binding_by_id = part_records.binding_by_id
local binding_by_carrier = part_records.binding_by_carrier
local binding_named = part_records.binding_named
-- materialize: placement's runner receives the token bytes once for the
-- current credential generation of the binding its attempt holds under
-- the carrier epoch it is attached to. The bytes are minted here and only
-- their hash is stored; the same generation cannot be materialized twice,
-- and a lost reply is recovered only by an explicit reissue, never by
-- replay.
function M.materialize(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id", "carrier_epoch", "binding_id", "materialization_key"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local attempt_id = bounds.id(object.attempt_id)
    if not attempt_id then return fail("INVALID", "attempt_id is not an identifier") end
    local key = bounds.id(object.materialization_key)
    if not key or #key > 128 then return fail("INVALID", "materialization_key is required") end
    local carrier_epoch = integer(object.carrier_epoch)
    if not carrier_epoch or carrier_epoch < 1 then return fail("INVALID", "carrier_epoch must be a positive integer") end
    local expected_binding: string? = nil
    if object.binding_id ~= nil then
        expected_binding = bounds.id(object.binding_id)
        if not expected_binding then return fail("INVALID", "binding_id is not an identifier") end
    end
    -- The materializer is the authenticated caller, never a payload field.
    local runner = actor()
    if not runner then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(part_model.MATERIALIZE, attempt_id) then return fail("DENIED", "caller is not a materializer admitted for attempt " .. attempt_id) end
    local db, open_failure = open()
    if not db then return open_failure end
    local binding, missing = binding_by_carrier(db, attempt_id, carrier_epoch, true)
    if not binding then db:release(); return missing end
    if expected_binding and binding.binding_id ~= expected_binding then
        db:release()
        return fail("CONFLICT", "the binding under carrier epoch " .. tostring(carrier_epoch) .. " is not the one the carrier recorded")
    end
    -- The one-time key placement issued for this start: its hash must be
    -- the one on the binding and still within its window; it is consumed
    -- below by the materialization it authorizes.
    local key_hash, key_hash_error = token_hash(key)
    if not key_hash then db:release(); return fail("STORAGE", key_hash_error or "hash key") end
    local key_rows, key_error = binding_store.materialization_key(db, binding.binding_id)
    if key_error or not key_rows or #key_rows ~= 1 then db:release(); return fail("STORAGE", "read materialization key") end
    local issued = bounds.object(key_rows[1])
    if not issued then db:release(); return fail("STORAGE", "materialization authorization is corrupt") end
    if issued.materialization_key_hash == nil and issued.materialization_expires_at == nil then
        db:release()
        return fail("DENIED", "materialization authorization has already been consumed")
    end
    local issued_hash = bounds.text(issued.materialization_key_hash, 64)
    local issued_expires_at = bounds.text(issued.materialization_expires_at, 64)
    if not issued_hash or #issued_hash ~= 64 or not issued_hash:match("^[0-9a-f]+$") or not issued_expires_at then
        db:release()
        return fail("STORAGE", "materialization authorization is corrupt")
    end
    if issued_hash ~= key_hash then
        db:release()
        return fail("DENIED", "materialization is not authorized by placement for this start")
    end
    local window, window_error = time.parse(FORMAT, issued_expires_at)
    if window_error or not window then db:release(); return fail("STORAGE", "materialization expiry is corrupt") end
    if not time.now():before(window) then db:release(); return fail("DENIED", "the materialization authorization has expired") end
    local generation, generation_failure = part_listener.generation(db)
    if not generation then db:release(); return assert(generation_failure) end
    local ok, reason = part_listener.valid(binding, generation)
    if not ok then db:release(); return fail("DENIED", reason) end
    local tx, begin_error = db:begin()
    if not tx then db:release(); return fail("STORAGE", tostring(begin_error or "begin credential materialization")) end
    local function abort(code: string, message: string): Reply
        tx:rollback()
        db:release()
        return fail(code, message)
    end
    local fresh_binding, fresh_error = binding_by_id(tx, binding.binding_id)
    if not fresh_binding then
        local fault = fresh_error and fresh_error.error
        return abort(fault and fault.code or "STORAGE", fault and fault.message or "read materialization binding")
    end
    binding = fresh_binding
    ok, reason = part_listener.valid(binding, generation)
    if not ok then return abort("DENIED", reason) end
    local current_keys, current_key_error = binding_store.materialization_key(tx, binding.binding_id)
    if not current_keys or current_key_error or #current_keys ~= 1 then return abort("STORAGE", "read materialization key") end
    if current_keys[1].materialization_key_hash ~= issued_hash or current_keys[1].materialization_expires_at ~= issued_expires_at then
        return abort("DENIED", "materialization authorization changed or was consumed")
    end
    -- Readers observe the generation, every credential and the consumed
    -- authorization together. A failed insertion publishes none of them.
    -- The first materialization opens generation 1; a single writer wins.
    local current = binding.credential_generation
    if current == 0 then
        local opened, open_error = binding_store.open_credential_generation(tx, binding.binding_id)
        if open_error then return abort("STORAGE", "open credential generation") end
        local affected = opened and bounds.count(opened.rows_affected)
        if affected ~= 1 then return abort("CONFLICT", "credential generation changed during materialization") end
        current = 1
    end
    -- One credential per kind: the tool credential always, the hook
    -- credential when the binding admits hook events. Both belong to the
    -- same generation and neither stands in for the other.
    local minted: Object = {}
    local kinds = {"tool"}
    if #binding.hooks > 0 then kinds[#kinds + 1] = "hook" end
    for _, kind in ipairs(kinds) do
        local token, token_error = random_text()
        if not token then return abort("STORAGE", token_error or "mint token") end
        local sum, hash_error = token_hash(token)
        if not sum then return abort("STORAGE", hash_error or "hash token") end
        local credential_id, id_error = uuid.v7()
        if id_error or not credential_id then return abort("STORAGE", "credential id") end
        local _, insert_error = credential_store.insert(tx, credential_id, binding.binding_id, current, kind, sum, runner, stamp(now_ms()))
        if insert_error then return abort("CONFLICT", "credential generation " .. tostring(current) .. " is already materialized; reissue to replace it") end
        minted[kind] = token
    end
    local _, consume_error = binding_store.consume_materialization_key(tx, binding.binding_id)
    if consume_error then return abort("STORAGE", "consume materialization key") end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then return fail("STORAGE", "commit credential materialization") end
    binding.credential_generation = current
    return succeed({binding = view(binding), token = minted.tool, hook_token = minted.hook, generation = current})
end
-- authorize_materialization: placement, at one start, authorizes the runner
-- it is about to spawn to materialize the binding the carrier recorded.
-- The key is returned once and only its hash is kept, with a window; a
-- process that merely shares the runner's actor cannot materialize.
function M.authorize_materialization(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id", "carrier_epoch", "binding_id", "ttl_ms"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local attempt_id, binding_id = bounds.id(object.attempt_id), bounds.id(object.binding_id)
    if not attempt_id then return fail("INVALID", "attempt_id is not an identifier") end
    if not binding_id then return fail("INVALID", "binding_id is not an identifier") end
    local carrier_epoch = integer(object.carrier_epoch)
    if not carrier_epoch or carrier_epoch < 1 then return fail("INVALID", "carrier_epoch must be a positive integer") end
    local ttl = part_model.DEFAULT_MATERIALIZATION_MS
    if object.ttl_ms ~= nil then
        local declared = bounds.integer(object.ttl_ms)
        if not declared or declared < 1000 or declared > part_model.MAX_MATERIALIZATION_MS then return fail("INVALID", "ttl_ms must be between 1000 and " .. tostring(part_model.MAX_MATERIALIZATION_MS)) end
        ttl = declared
    end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(part_model.MANAGE, "bindings") then return fail("DENIED", "caller does not manage gateway bindings") end
    local db, open_failure = open()
    if not db then return open_failure end
    local binding, missing = binding_by_carrier(db, attempt_id, carrier_epoch, true)
    if not binding then db:release(); return missing end
    if binding.binding_id ~= binding_id then db:release(); return fail("CONFLICT", "the binding under carrier epoch " .. tostring(carrier_epoch) .. " is not the one the carrier recorded") end
    local generation, generation_failure = part_listener.generation(db)
    if not generation then db:release(); return assert(generation_failure) end
    local ok, reason = part_listener.valid(binding, generation)
    if not ok then db:release(); return fail("DENIED", reason) end
    local key, key_error = random_text()
    if not key then db:release(); return fail("STORAGE", key_error or "materialization key") end
    local key_hash, hash_error = token_hash(key)
    if not key_hash then db:release(); return fail("STORAGE", hash_error or "hash key") end
    local _, write_error = binding_store.authorize_materialization(db, binding_id, key_hash, stamp(now_ms() + ttl))
    db:release()
    if write_error then return fail("STORAGE", "record materialization authorization") end
    return succeed({binding = view(binding), materialization_key = key})
end
-- reissue: the attempt's own carrier replaces the credential. It is a
-- compare-and-set on the expected generation, so concurrent reissues yield
-- exactly one successor and a stale request changes nothing; the previous
-- generation's credentials are revoked. No bytes are returned: the runner
-- materializes the new generation once.
function M.reissue(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"binding_id", "expected_generation"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local binding_id = bounds.id(object.binding_id)
    if not binding_id then return fail("INVALID", "binding_id is not an identifier") end
    local expected: integer = integer(object.expected_generation) or -1
    if expected < 0 then return fail("INVALID", "expected_generation must be a nonnegative integer") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    local db, open_failure = open()
    if not db then return open_failure end
    local binding, missing = binding_by_id(db, binding_id)
    if not binding then db:release(); return missing end
    if not security.can(part_model.ADMIT, binding.action_id) then db:release(); return fail("DENIED", "caller may not reissue credentials for action " .. binding.action_id) end
    local generation, generation_failure = part_listener.generation(db)
    if not generation then db:release(); return assert(generation_failure) end
    local ok, reason = part_listener.valid(binding, generation)
    if not ok then db:release(); return fail("DENIED", reason) end
    local advanced, advance_error = binding_store.advance_credential_generation(db, binding_id, expected)
    if advance_error then db:release(); return fail("STORAGE", "advance credential generation") end
    local affected = advanced and bounds.count(advanced.rows_affected)
    if affected == nil or affected > 1 then db:release(); return fail("STORAGE", "credential generation result is corrupt") end
    if affected ~= 1 then
        db:release()
        return fail("CONFLICT", "credential generation is not " .. tostring(expected) .. "; read the binding before reissuing")
    end
    local _, revoke_error = credential_store.revoke_through_generation(db, binding_id, expected, stamp(now_ms()))
    db:release()
    if revoke_error then return fail("STORAGE", "revoke previous credentials") end
    binding.credential_generation = expected + 1
    return succeed({binding = view(binding), generation = expected + 1})
end
local function close_origin(binding: Binding): Reply
    return subject_call.call(binding, {"bee.gateway.security:origin_withdraw_policy"},
        "bee.approvals.binding:withdraw_origin", {instance_id = binding.binding_id})
end
-- revoke: the admitting carrier, a manager, or the runner that
-- materialized the attempt retires one binding.
function M.revoke(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"binding_id"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local binding_id = bounds.id(object.binding_id)
    if not binding_id then return fail("INVALID", "binding_id is not an identifier") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    local db, open_failure = open()
    if not db then return open_failure end
    local binding, missing = binding_by_id(db, binding_id)
    if not binding then db:release(); return missing end
    if not security.can(part_model.ADMIT, binding.action_id) and not security.can(part_model.MANAGE, "bindings") and not security.can(part_model.MATERIALIZE, binding.attempt_id) then
        db:release()
        return fail("DENIED", "caller may not revoke bindings for action " .. binding.action_id)
    end
    local closed = close_origin(binding)
    if not closed.ok then db:release(); return closed end
    local revocation = capability_model.revocation_report({}, {binding.attempt_id})
    if not revocation then db:release(); return fail("STORAGE", "report binding revocation") end
    -- Revocation invalidates credentials and rejects rows no carrier began.
    -- A claimed row can be the thread commit whose acknowledgement was lost,
    -- so it remains queued for a current or replacement carrier to reconcile.
    local at = stamp(now_ms())
    local _, write_error = binding_store.revoke(db, binding_id, at)
    if write_error then db:release(); return fail("STORAGE", "revoke binding") end
    local _, reject_error = hook_store.reject_revoked_for_binding(db, binding_id, at)
    db:release()
    if reject_error then return fail("STORAGE", "reject queued hooks") end
    local result = view(binding)
    result.revoked = true
    result.sealed = true
    result.revocation = revocation
    return succeed(result)
end
-- seal: intake ends, credentials stay. New submissions are refused from
-- the seal's linearization point, which is the same transaction any
-- submission checks, while what was already accepted stays queued for
-- the carrier to drain. The runner seals when the child exits; the carrier
-- seals before its final drain.
function M.seal(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"binding_id"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local binding_id = bounds.id(object.binding_id)
    if not binding_id then return fail("INVALID", "binding_id is not an identifier") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    local db, open_failure = open()
    if not db then return open_failure end
    local binding, missing = binding_by_id(db, binding_id)
    if not binding then db:release(); return missing end
    if not security.can(part_model.ADMIT, binding.action_id) and not security.can(part_model.MANAGE, "bindings") and not security.can(part_model.MATERIALIZE, binding.attempt_id) then
        db:release()
        return fail("DENIED", "caller may not seal this binding")
    end
    local closed = close_origin(binding)
    if not closed.ok then db:release(); return closed end
    local _, write_error = binding_store.seal(db, binding_id, stamp(now_ms()))
    db:release()
    if write_error then return fail("STORAGE", "seal binding") end
    binding.sealed = true
    return succeed(view(binding))
end
-- revoke_attempt: the independent owner (placement's supervision) retires
-- every binding of an attempt whose carrier epoch is at most the reported
-- one. A delayed report from an old carrier therefore cannot revoke the
-- binding a replacement carrier admitted under a higher epoch.
function M.revoke_attempt(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id", "carrier_epoch"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local attempt_id = bounds.id(object.attempt_id)
    if not attempt_id then return fail("INVALID", "attempt_id is not an identifier") end
    local carrier_epoch = integer(object.carrier_epoch)
    if not carrier_epoch or carrier_epoch < 1 then return fail("INVALID", "carrier_epoch must be a positive integer") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(part_model.MANAGE, "bindings") then return fail("DENIED", "caller does not manage gateway bindings") end
    local revocation = capability_model.revocation_report({}, {attempt_id})
    if not revocation then return fail("INVALID", "report attempt revocation") end
    local db, open_failure = open()
    if not db then return open_failure end
    local at = stamp(now_ms())
    local origins, origins_error = binding_store.origins(db, attempt_id, carrier_epoch)
    if origins_error or not origins then db:release(); return fail("STORAGE", "read attempt origins") end
    for _, raw in ipairs(origins) do
        local row = bounds.object(raw)
        local id = row and bounds.id(row.binding_id)
        if not id then db:release(); return fail("STORAGE", "invalid attempt origin") end
        local binding, missing = binding_by_id(db, id)
        if not binding then db:release(); return missing end
        local closed = close_origin(binding)
        if not closed.ok then db:release(); return closed end
    end
    local result, write_error = binding_store.revoke_attempt(db, attempt_id, carrier_epoch, at)
    if write_error then db:release(); return fail("STORAGE", "revoke attempt bindings") end
    local revoked = result and bounds.count(result.rows_affected)
    if revoked == nil then db:release(); return fail("STORAGE", "revocation result is corrupt") end
    local _, reject_error = hook_store.reject_revoked_attempt(db, attempt_id, at)
    db:release()
    if reject_error then return fail("STORAGE", "reject queued hooks") end
    return succeed({attempt_id = attempt_id, carrier_epoch = carrier_epoch, revoked = revoked, revocation = revocation})
end
-- renew_attempt: placement's supervision extends the bindings a live attempt
-- holds at or below its carrier epoch by their recorded term once less than
-- half of the term remains. A revoked, sealed, expired or epoch-fenced
-- binding stays ended.
function M.renew_attempt(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id", "carrier_epoch"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local attempt_id = bounds.id(object.attempt_id)
    if not attempt_id then return fail("INVALID", "attempt_id is not an identifier") end
    local carrier_epoch = integer(object.carrier_epoch)
    if not carrier_epoch or carrier_epoch < 1 then return fail("INVALID", "carrier_epoch must be a positive integer") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(part_model.MANAGE, "bindings") then return fail("DENIED", "caller does not manage gateway bindings") end
    local db, open_failure = open()
    if not db then return open_failure end
    local generation, generation_failure = part_listener.generation(db)
    if not generation then db:release(); return assert(generation_failure) end
    local now = now_ms()
    local rows, read_error = binding_store.attempt_leases(db, attempt_id, carrier_epoch, generation.epoch, stamp(now))
    if read_error or not rows then db:release(); return fail("STORAGE", "read attempt bindings") end
    local renewed = 0
    for _, row in ipairs(rows) do
        local lease = integer(row.lease_ms)
        if not lease or lease < 1 then db:release(); return fail("STORAGE", "binding lease length is corrupt") end
        if tostring(row.expires_at) <= stamp(now + lease // 2) then
            local _, extend_error = binding_store.extend(db, tostring(row.binding_id), stamp(now + lease))
            if extend_error then db:release(); return fail("STORAGE", "renew binding") end
            renewed = renewed + 1
        end
    end
    db:release()
    return succeed({attempt_id = attempt_id, carrier_epoch = carrier_epoch, renewed = renewed})
end
-- check: a binding in its current state, named by id or by attempt and carrier
-- epoch, for placement's recheck of what an attempt still holds. Bindings,
-- never bytes.
function M.check(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"binding_id", "attempt_id", "carrier_epoch"})
    if unknown_field then return fail("INVALID", unknown_field) end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    local db, open_failure = open()
    if not db then return open_failure end
    local binding, missing = binding_named(db, object)
    if not binding then db:release(); return missing end
    if not security.can(part_model.MATERIALIZE, binding.attempt_id) and not security.can(part_model.ADMIT, binding.action_id) and not security.can(part_model.MANAGE, "bindings") then
        db:release()
        return fail("DENIED", "caller may not check this binding")
    end
    local generation, generation_failure = part_listener.generation(db)
    db:release()
    if not generation then return assert(generation_failure) end
    local ok, reason = part_listener.valid(binding, generation)
    local result = view(binding)
    result.valid = ok
    result.reason = reason
    result.generation = generation
    result.presented_count = 0
    if binding.credential_generation > 0 then
        local db_again, again_failure = open()
        if not db_again then return again_failure end
        local presented, presented_error = binding_store.credential_presentation(db_again, binding.binding_id, binding.credential_generation)
        db_again:release()
        if presented_error or not presented or #presented ~= 1 then return fail("STORAGE", "read credential") end
        local credential_row = bounds.object(presented[1])
        local presented_count = credential_row and bounds.count(credential_row.presented_count)
        local last_presented_at, valid_last_presented_at = optional_timestamp(credential_row and credential_row.last_presented_at)
        if not credential_row or presented_count == nil or not valid_last_presented_at
            or (presented_count == 0 and last_presented_at ~= nil) or (presented_count > 0 and last_presented_at == nil) then
            return fail("STORAGE", "credential presentation state is corrupt")
        end
        result.presented_count = presented_count
        result.last_presented_at = last_presented_at
    end
    return succeed(result)
end
-- A credential is valid only for its action, kind, current generation and expiry.
function M.authenticate(token: string, action_id: string, kind: string): (Binding?, Reply?)
    if #token == 0 or #token > 128 then return nil, fail("UNAUTHENTICATED", "token is not presentable") end
    local sum, hash_error = token_hash(token)
    if not sum then return nil, fail("STORAGE", hash_error or "hash token") end
    local db, open_failure = open()
    if not db then return nil, open_failure end
    local rows, err = credential_store.by_hash(db, sum)
    if err or not rows then db:release(); return nil, fail("STORAGE", "read credential") end
    if #rows == 0 then db:release(); return nil, fail("UNAUTHENTICATED", "token is not admitted") end
    if #rows ~= 1 then db:release(); return nil, fail("STORAGE", "credential hash is not unique") end
    local credential = bounds.object(rows[1])
    local credential_id = credential and bounds.id(credential.credential_id)
    local binding_id = credential and bounds.id(credential.binding_id)
    local credential_generation = credential and bounds.count(credential.generation)
    local credential_kind = credential and bounds.text(credential.kind, 16)
    local revoked_at, valid_revoked_at = optional_timestamp(credential and credential.revoked_at)
    if not credential or not credential_id or not binding_id or credential_generation == nil or credential_generation == 0
        or (credential_kind ~= "tool" and credential_kind ~= "hook") or not valid_revoked_at then
        db:release()
        return nil, fail("STORAGE", "credential row is corrupt")
    end
    if revoked_at then db:release(); return nil, fail("UNAUTHENTICATED", "token was replaced or revoked") end
    if credential_kind ~= kind then db:release(); return nil, fail("UNAUTHENTICATED", "credential is a " .. credential_kind .. " credential, not admitted on this endpoint") end
    local binding, missing = binding_by_id(db, binding_id)
    if not binding then db:release(); return nil, missing end
    local generation, generation_failure = part_listener.generation(db)
    if not generation then db:release(); return nil, generation_failure end
    if credential_generation ~= binding.credential_generation then db:release(); return nil, fail("UNAUTHENTICATED", "token belongs to a superseded credential generation") end
    if binding.action_id ~= action_id then db:release(); return nil, fail("DENIED", "token is bound to another action") end
    local ok, reason = part_listener.valid(binding, generation)
    if not ok then db:release(); return nil, fail("UNAUTHENTICATED", reason) end
    -- An accepted presentation is counted; the count is what proves a
    -- client authenticated without any bytes in evidence.
    local _, count_error = credential_store.presented(db, credential_id, stamp(now_ms()))
    db:release()
    if count_error then return nil, fail("STORAGE", "count presentation") end
    return binding, nil
end
function M.managed_binding(binding_id: string): (Binding?, Reply?)
    if not actor() or not security.can(part_model.MANAGE, "bindings") then return nil, fail("DENIED", "caller does not manage bindings") end
    local db, failure = open()
    if not db then return nil, failure end
    local binding, missing = binding_by_id(db, binding_id)
    db:release()
    return binding, missing
end
return M
