-- MIT. Listener for the gateway authority.
local sql = require("sql")
local time = require("time")
local json = require("json")
local security = require("security")
local system = require("system")
local crypto = require("crypto")
local http_client = require("http_client")
local bounds = require("bounds")
local canonical = require("canonical")
local configuration = require("configuration")
local listener_store = require("listener_store")
local part_model = require("part_model")
local part_records = require("part_records")
local part_values = require("part_values")
local M = {}
type Reply = part_model.Reply
type Row = part_model.Row
type Object = part_model.Object
type Binding = part_model.Binding
type Generation = part_model.Generation
type Drain = part_model.Drain
local FORMAT = part_values.FORMAT
local fail = part_values.fail
local succeed = part_values.succeed
local now_ms = part_values.now_ms
local stamp = part_values.stamp
local actor = part_values.actor
local integer = part_values.integer
local reference = part_values.reference
local open = part_values.open
local random_text = part_values.random_text
local optional_text = part_values.optional_text
local optional_timestamp = part_values.optional_timestamp
local view = part_records.view
local binding_by_id = part_records.binding_by_id
function M.accepts_host(value: unknown): boolean
    local current = configuration.current()
    return current ~= nil and configuration.host_matches(value, current.address)
end
function M.endpoint(): (string?, string?)
    return configuration.endpoint()
end
local function listener_of(db: sql.DB): (Row?, string?)
    local rows, err = listener_store.read(db)
    if err or not rows then return nil, "read listener" end
    if #rows == 0 then return nil, nil end
    if #rows ~= 1 then return nil, "listener row is duplicated" end
    local row = bounds.object(rows[1])
    local epoch = row and bounds.count(row.epoch)
    local address = row and bounds.line(row.address, 120)
    local secret = row and bounds.text(row.secret, 128)
    local drained = row and bounds.count(row.drained)
    local opened_at = row and bounds.text(row.opened_at, 64)
    local opened, opened_error = time.parse(FORMAT, opened_at or "")
    local deadline_at, deadline_valid = optional_timestamp(row and row.drain_deadline_at)
    local native_key, native_valid = optional_text(row and row.native_key, 160)
    if not row or epoch == nil or epoch == 0 or not address or not configuration.valid_address(address, false)
        or not secret or secret == "" or (drained ~= 0 and drained ~= 1) or not opened_at or opened_error or not opened
        or not deadline_valid or not native_valid then
        return nil, "listener row is corrupt"
    end
    if drained == 1 and not deadline_at then return nil, "listener drain deadline is absent" end
    if drained == 0 and deadline_at then return nil, "listener has an unexpected drain deadline" end
    return row, nil
end
-- The listener service's restart count is part of the generation, so a
-- service restart invalidates every readiness taken before it.
local function restarts(): (integer?, string?)
    local service, service_error = reference(part_model.LISTENER_SERVICE, "resource_ref", "gateway listener")
    if not service then return nil, service_error end
    local state, state_error = system.supervisor.state(service)
    if state_error or not state then return nil, "listener service state unavailable" end
    local retry_count = bounds.count(state.retry_count)
    if not retry_count then return nil, "listener service retry count is invalid" end
    return retry_count, nil
end
-- A permitted admission may initialize the host-selected native listener.
-- The conditional upsert gives simultaneous admissions one epoch and secret.
local function synchronize_native_listener(db: sql.DB): (boolean, string?)
    local configured, config_error = configuration.configured()
    if not configured then return false, config_error end
    if not configured:match(":0$") then return true, nil end
    local current, current_error = configuration.current()
    if not current or not current.native_key then return false, current_error or "native listener identity is unavailable" end
    local secret, secret_error = random_text()
    if not secret then return false, secret_error end
    local _, write_error = listener_store.initialize_native(db, current.address, secret, stamp(now_ms()), current.native_key)
    if write_error then return false, "record native listener" end
    local rechecked, recheck_error = configuration.current()
    if not rechecked or rechecked.native_key ~= current.native_key then return false, recheck_error or "native listener changed during admission" end
    return true, nil
end
function M.generation(db: sql.DB): (Generation?, Reply?)
    local listener, listener_error = listener_of(db)
    if listener_error then return nil, fail("STORAGE", listener_error) end
    if not listener then return nil, fail("UNAVAILABLE", "the gateway listener has not been opened") end
    local current, current_error = configuration.current()
    if not current then return nil, fail("UNAVAILABLE", current_error or "gateway endpoint is unavailable") end
    local stored_epoch = bounds.count(listener.epoch)
    local stored_address = bounds.line(listener.address, 120)
    local stored_native_key, native_key_valid = optional_text(listener.native_key, 160)
    if not stored_epoch or not stored_address or not native_key_valid then return nil, fail("STORAGE", "listener identity is corrupt") end
    if current.address ~= stored_address or current.native_key ~= stored_native_key then
        local secret, secret_error = random_text()
        if not secret then return nil, fail("STORAGE", secret_error or "listener secret") end
        local reconciled, reconcile_error = listener_store.reconcile(db, stored_epoch, stored_address, stored_native_key,
            current.address, secret, stamp(now_ms()), current.native_key)
        if reconcile_error or not reconciled then return nil, fail("STORAGE", "reconcile host-selected listener") end
        local refreshed, refresh_error = listener_of(db)
        if refresh_error or not refreshed then return nil, fail("STORAGE", refresh_error or "read reconciled listener") end
        local rechecked, recheck_error = configuration.current()
        if not rechecked or refreshed.address ~= rechecked.address or refreshed.native_key ~= rechecked.native_key then
            return nil, fail("UNAVAILABLE", recheck_error or "gateway listener changed during reconciliation")
        end
        listener = refreshed
    end
    local count, count_error = restarts()
    if not count then return nil, fail("UNAVAILABLE", count_error or "listener restarts unknown") end
    local epoch = bounds.count(listener.epoch)
    if epoch == nil then return nil, fail("STORAGE", "listener epoch is corrupt") end
    return {epoch = epoch, restarts = count}, nil
end
-- Binding validity requires the current epoch and a live, unrevoked binding.
function M.valid(binding: Binding, generation: Generation): (boolean, string)
    if binding.revoked then return false, "binding is revoked" end
    if binding.epoch ~= generation.epoch then return false, "binding belongs to an earlier listener epoch" end
    local expires = time.parse(FORMAT, binding.expires_at)
    if not expires or not time.now():before(expires) then return false, "binding has expired" end
    return true, ""
end
-- open: the managed host brings the listener up, advances the epoch and
-- mints the secret that authenticates the listener's readiness answer;
-- every earlier readiness and binding is fenced.
function M.open(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"address"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local address = bounds.line(object.address, 120)
    if not address or not configuration.valid_address(address, false) then return fail("INVALID", "address must be a loopback or private IPv4 host and port") end
    local selected, endpoint_error = configuration.current()
    if not selected then return fail("UNAVAILABLE", endpoint_error or "gateway endpoint") end
    if address ~= selected.address then return fail("DENIED", "address is not the host-configured gateway endpoint") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(part_model.MANAGE, "listener") then return fail("DENIED", "caller does not manage the gateway listener") end
    local secret, secret_error = random_text()
    if not secret then return fail("STORAGE", secret_error or "listener secret") end
    local db, open_failure = open()
    if not db then return open_failure end
    local current_epoch: integer = 0
    local rows, read_error = listener_store.read(db)
    if read_error or not rows then db:release(); return fail("STORAGE", "read listener for recovery") end
    if #rows > 1 then db:release(); return fail("STORAGE", "listener row is duplicated") end
    if #rows == 1 then
        local current = bounds.object(rows[1])
        local declared_epoch = current and bounds.count(current.epoch)
        if declared_epoch == nil or declared_epoch == 0 then db:release(); return fail("STORAGE", "listener epoch is corrupt") end
        current_epoch = declared_epoch
    end
    local epoch = current_epoch + 1
    local _, write_error = listener_store.open(db, epoch, address, secret, stamp(now_ms()), selected.native_key or "")
    db:release()
    if write_error then return fail("STORAGE", "record listener") end
    if selected.native_key then
        local rechecked, recheck_error = configuration.current()
        if not rechecked or rechecked.native_key ~= selected.native_key then
            return fail("UNAVAILABLE", recheck_error or "native listener changed during open")
        end
    end
    return succeed({epoch = epoch, address = address})
end
-- drain: no new admissions, every outstanding wait is released at its
-- next slice, bounded reads may finish until the host-owned deadline, and
-- past it nothing is served so the host can stop the service.
function M.drain(value: unknown): Reply
    local object = bounds.object(value) or {}
    local unknown_field = bounds.fields(object, {"deadline_ms"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local deadline = part_model.DEFAULT_DRAIN_MS
    if object.deadline_ms ~= nil then
        local declared = bounds.integer(object.deadline_ms)
        if not declared or declared < 0 or declared > part_model.MAX_DRAIN_MS then return fail("INVALID", "deadline_ms must be between 0 and " .. tostring(part_model.MAX_DRAIN_MS)) end
        deadline = declared
    end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(part_model.MANAGE, "listener") then return fail("DENIED", "caller does not manage the gateway listener") end
    local db, open_failure = open()
    if not db then return open_failure end
    local deadline_at = stamp(now_ms() + deadline)
    local _, write_error = listener_store.start_drain(db, deadline_at)
    db:release()
    if write_error then return fail("STORAGE", "record drain") end
    return succeed({drained = true, deadline_at = deadline_at})
end
function M.draining(): (Drain?, Reply?)
    local db, open_failure = open()
    if not db then return nil, open_failure end
    local listener, listener_error = listener_of(db)
    db:release()
    if listener_error then return nil, fail("STORAGE", listener_error) end
    if not listener then return nil, fail("UNAVAILABLE", "the gateway listener has not been opened") end
    local drained = integer(listener.drained)
    if drained ~= 0 and drained ~= 1 then return nil, fail("STORAGE", "listener drain state is corrupt") end
    if drained == 0 then return {draining = false, past_deadline = false}, nil end
    local deadline_text = bounds.text(listener.drain_deadline_at)
    if not deadline_text then return nil, fail("STORAGE", "drain deadline is absent or corrupt") end
    local deadline, parse_error = time.parse(FORMAT, deadline_text)
    if parse_error or not deadline then return nil, fail("STORAGE", "drain deadline is corrupt") end
    local past = not time.now():before(deadline)
    return {draining = true, past_deadline = past}, nil
end
-- The readiness proof: an HMAC over the generation and the caller's nonce
-- under the listener secret only this runtime's store holds. Another
-- process answering on the port cannot produce it. A store upgraded
-- without a reopen holds no secret and proves nothing.
function M.proof(secret: string, generation: Generation, nonce: string): (string?, string?)
    if secret == "" then return nil, "the listener has not been opened since the store gained its secret" end
    local encoded, encode_error = canonical.encode({epoch = generation.epoch, restarts = generation.restarts, nonce = nonce})
    if not encoded then return nil, encode_error end
    local mac, mac_error = crypto.hmac.sha256(secret, encoded)
    if mac_error or not mac then return nil, "compute proof" end
    return mac, nil
end
-- verify: the listener's answer is accepted only under the generation this
-- runtime holds and with the proof over this request's nonce.
function M.verify(secret: string, generation: Generation, nonce: string, answered: Object): (boolean, Reply?)
    if integer(answered.epoch) ~= generation.epoch or integer(answered.restarts) ~= generation.restarts then
        return false, fail("CONFLICT", "the listener answered under another generation; take readiness again")
    end
    local expected, proof_error = M.proof(secret, generation, nonce)
    if not expected then return false, fail("UNAVAILABLE", proof_error or "proof") end
    if type(answered.proof) ~= "string" or answered.proof ~= expected then return false, fail("DENIED", "the listener's answer is not this gateway's: readiness refused") end
    return true, nil
end
-- ready: a real loopback request with a fresh nonce; readiness holds only
-- when the answer's generation matches what the store and supervisor hold
-- and its proof verifies under the listener secret.
function M.ready(value: unknown): Reply
    local object = bounds.object(value) or {}
    local unknown_field = bounds.fields(object, {"binding_id"})
    if unknown_field then return fail("INVALID", unknown_field) end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    local db, open_failure = open()
    if not db then return open_failure end
    local listener, listener_error = listener_of(db)
    if listener_error or not listener then db:release(); return fail("UNAVAILABLE", listener_error or "the gateway listener has not been opened") end
    local generation, generation_failure = M.generation(db)
    if not generation then db:release(); return assert(generation_failure) end
    local reconciled_listener, reconcile_error = listener_of(db)
    if reconcile_error or not reconciled_listener then
        db:release()
        return fail("UNAVAILABLE", reconcile_error or "the gateway listener has not been opened")
    end
    listener = reconciled_listener
    local binding: Binding? = nil
    if object.binding_id ~= nil then
        local binding_id = bounds.id(object.binding_id)
        if not binding_id then db:release(); return fail("INVALID", "binding_id is not an identifier") end
        local found, missing = binding_by_id(db, binding_id)
        if not found then db:release(); return missing end
        binding = found
    end
    db:release()
    local selected, selection_error = configuration.current()
    if not selected then return fail("UNAVAILABLE", selection_error or "gateway endpoint") end
    local address = bounds.text(listener.address, 120)
    local secret = bounds.text(listener.secret, 128)
    if not address or not secret then return fail("STORAGE", "listener endpoint or secret is corrupt") end
    if address ~= selected.address or listener.native_key ~= selected.native_key then
        return fail("UNAVAILABLE", "the stored listener is not the host-selected execution")
    end
    local nonce, nonce_error = random_text()
    if not nonce then return fail("STORAGE", nonce_error or "nonce") end
    local response, request_error = http_client.get("http://" .. address .. "/ready", {timeout = "2s", query = {nonce = nonce}})
    if request_error or not response then return fail("UNAVAILABLE", "the listener did not answer: " .. tostring(request_error)) end
    if response.status_code ~= 200 then
        local body: unknown = json.decode(tostring(response.body))
        local failure = bounds.object((bounds.object(body) or {}).error)
        local code = failure and bounds.line(failure.code, 64)
        local message = failure and bounds.line(failure.message, 200)
        local detail = code and message and (": " .. code .. ": " .. message) or ""
        return fail("UNAVAILABLE", "the listener answered " .. tostring(response.status_code) .. detail)
    end
    local answered: unknown, decode_error = json.decode(tostring(response.body))
    if decode_error or type(answered) ~= "table" then return fail("UNAVAILABLE", "the listener answered unreadably") end
    local reported = answered
    local verified, verify_failure = M.verify(secret, generation, nonce, reported)
    if not verified then return assert(verify_failure) end
    local result: Object = {generation = generation, address = address, listening = true}
    if binding then
        local ok, reason = M.valid(binding, generation)
        result.binding = view(binding)
        result.binding_valid = ok
        if not ok then result.binding_reason = reason end
    end
    return succeed(result)
end
-- The listener's own answer to GET /ready: the generation and a proof over
-- the caller's nonce under the listener secret. It carries no binding.
function M.ready_report(nonce: string): (Object?, Reply?)
    local db, open_failure = open()
    if not db then return nil, open_failure end
    local listener, listener_error = listener_of(db)
    if listener_error or not listener then db:release(); return nil, fail("UNAVAILABLE", listener_error or "not opened") end
    local generation, generation_failure = M.generation(db)
    db:release()
    if not generation then return nil, generation_failure end
    local secret = bounds.text(listener.secret, 128)
    if not secret then return nil, fail("STORAGE", "listener secret is corrupt") end
    local proof, proof_error = M.proof(secret, generation, nonce)
    if not proof then return nil, fail("STORAGE", proof_error or "proof") end
    return {epoch = generation.epoch, restarts = generation.restarts, proof = proof}, nil
end
M.listener_of = listener_of
M.restarts = restarts
M.synchronize_native_listener = synchronize_native_listener
return M
