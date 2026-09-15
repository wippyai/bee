-- MIT. The gateway authority: bindings that stand for an admitted attempt,
-- credentials minted only at delivery and stored only as hashes, a listener
-- epoch and secret that fence and authenticate readiness, drain, and the
-- independent revocation placement runs when a carrier is lost. It issues
-- tokens itself; the credential broker gains no token semantics. Every
-- tool call still runs as the bound subject and is authorized again by the
-- thread owner.
local sql = require("sql")
local hash = require("hash")
local time = require("time")
local uuid = require("uuid")
local json = require("json")
local security = require("security")
local system = require("system")
local crypto = require("crypto")
local base64 = require("base64")
local http_client = require("http_client")
local bounds = require("bounds")
local canonical = require("canonical")
local persist = require("persist")
local migrations = require("migrations")
local registry = require("registry")
local configuration = require("configuration")
local hooks = require("hooks")
local M = {}
function M.accepts_host(value: unknown): boolean
    local current = configuration.current()
    return current ~= nil and configuration.host_matches(value, current.address)
end
M.LEDGER = {table = "bee_gateway_schema_migrations", label = "gateway"}
M.ADMIT = "bee.gateway.admit"
M.MANAGE = "bee.gateway.manage"
M.MATERIALIZE = "bee.gateway.materialize"
M.DATABASE_REF = "bee.gateway:database_ref"
M.LISTENER_SERVICE = "bee.gateway:listener_ref"
M.ENDPOINT = configuration.ENDPOINT
M.MAX_TTL_MS = 86400000
M.DEFAULT_TTL_MS = 3600000
M.MAX_DRAIN_MS = 600000
M.DEFAULT_DRAIN_MS = 30000
M.WAIT_SLICE_MS = 1000
M.TOKEN_BYTES = 32
M.MAX_RETAINED_HOOKS = 256
M.MAX_RETAINED_HOOK_BYTES = 524288
M.MAX_HOOK_CLAIM = 32
M.DEFAULT_MATERIALIZATION_MS = 60000
M.MAX_MATERIALIZATION_MS = 600000
M.MAX_TOOLS = 16
M.TOOL_NAMES = {"thread_read", "thread_wait", "thread_message", "workspace"}
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown}
type Row = {[string]: unknown}
type Object = {[string]: unknown}
type Binding = {binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, owner_incarnation: integer, carrier_epoch: integer,
    tools: {string}, hooks: {string}, epoch: integer, credential_generation: integer, expires_at: string, revoked: boolean, sealed: boolean}
type Generation = {epoch: integer, restarts: integer}
type Drain = {draining: boolean, past_deadline: boolean}
local FORMAT = "2006-01-02T15:04:05.000Z07:00"
local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}}
end
local function succeed(value: unknown): Reply
    return {ok = true, value = value}
end
local function now_ms(): integer
    return math.floor(time.now():unix_nano() / 1000000)
end
local function stamp(ms: integer): string
    return time.unix(math.floor(ms / 1000), (ms % 1000) * 1000000):utc():format(FORMAT)
end
local function actor(): string?
    local current = security.actor()
    if not current then return nil end
    return bounds.id(current:id())
end
local function text(value: unknown): string?
    if type(value) ~= "string" then return nil end
    return value :: string
end
local function integer(value: unknown): integer?
    local number = tonumber(value)
    if not number then return nil end
    return math.floor(number)
end
local function reference(id: string, field: string, what: string): (string?, string?)
    local entry, err = registry.get(id)
    if err or not entry then return nil, what .. " reference is not in the registry" end
    local data = entry.data
    if type(data) ~= "table" then return nil, what .. " reference has no data" end
    local target = (data :: Object)[field]
    if type(target) ~= "string" or target == "" then return nil, what .. " reference is not linked" end
    return target :: string, nil
end
function M.database(): (string?, string?)
    return reference(M.DATABASE_REF, "resource_ref", "gateway database")
end
function M.endpoint(): (string?, string?)
    return configuration.endpoint()
end
local function open(): (sql.DB?, Reply?)
    local resource, resource_error = M.database()
    if not resource then return nil, fail("STORAGE", resource_error or "gateway database") end
    local db, open_error = persist.open({resource = resource, ledger = M.LEDGER, migrations = migrations.all()})
    if not db then return nil, fail("STORAGE", open_error or "open gateway store") end
    return db, nil
end
local function digest_of(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest request" end
    return sum, nil
end
local function token_hash(token: string): (string?, string?)
    local sum, hash_error = hash.sha256(token)
    if hash_error or not sum then return nil, "digest token" end
    return sum, nil
end
local function random_text(): (string?, string?)
    local raw, random_error = crypto.random.bytes(M.TOKEN_BYTES)
    if random_error or not raw then return nil, "generate random bytes" end
    local encoded, encode_error = base64.encode(raw)
    if encode_error or not encoded then return nil, "encode random bytes" end
    return encoded, nil
end
local function listener_of(db: sql.DB): (Row?, string?)
    local rows, err = db:query("SELECT epoch, address, secret, drained, opened_at, drain_deadline_at, native_key FROM bee_gateway_listener WHERE singleton = 1")
    if err or not rows then return nil, "read listener" end
    if #rows == 0 then return nil, nil end
    return rows[1] :: Row, nil
end
-- The listener service's restart count is part of the generation, so a
-- service restart invalidates every readiness taken before it.
local function restarts(): (integer?, string?)
    local service, service_error = reference(M.LISTENER_SERVICE, "resource_ref", "gateway listener")
    if not service then return nil, service_error end
    local state, state_error = system.supervisor.state(service)
    if state_error or not state then return nil, "listener service state unavailable" end
    return integer(state.retry_count) or 0, nil
end
local function binding_of(row: Row): (Binding?, string?)
    local tools: unknown, decode_error = json.decode(tostring(row.tools_json))
    if decode_error or type(tools) ~= "table" then return nil, "binding tools are corrupt" end
    local names: {string} = {}
    for _, name in ipairs(tools :: {unknown}) do names[#names + 1] = tostring(name) end
    local hook_names: {string} = {}
    local admitted_hooks: unknown, hooks_error = json.decode(tostring(row.hooks_json or "[]"))
    if hooks_error or type(admitted_hooks) ~= "table" then return nil, "binding hooks are corrupt" end
    for _, name in ipairs(admitted_hooks :: {unknown}) do hook_names[#hook_names + 1] = tostring(name) end
    return {binding_id = tostring(row.binding_id), subject = tostring(row.subject), action_id = tostring(row.action_id), attempt_id = tostring(row.attempt_id),
        thread_id = tostring(row.thread_id), owner_incarnation = integer(row.owner_incarnation) or 0, carrier_epoch = integer(row.carrier_epoch) or 0, tools = names, hooks = hook_names,
        epoch = integer(row.epoch) or 0, credential_generation = integer(row.credential_generation) or 0, expires_at = tostring(row.expires_at), revoked = row.revoked_at ~= nil, sealed = row.sealed_at ~= nil}, nil
end
local function view(binding: Binding): Object
    return {binding_id = binding.binding_id, subject = binding.subject, action_id = binding.action_id, attempt_id = binding.attempt_id, thread_id = binding.thread_id,
        owner_incarnation = binding.owner_incarnation, carrier_epoch = binding.carrier_epoch, tools = binding.tools, hooks = binding.hooks, epoch = binding.epoch,
        credential_generation = binding.credential_generation, expires_at = binding.expires_at, revoked = binding.revoked, sealed = binding.sealed}
end
local function binding_by_id(db: sql.DB, binding_id: string): (Binding?, Reply?)
    local rows, err = db:query("SELECT * FROM bee_gateway_bindings WHERE binding_id = ?", {binding_id})
    if err or not rows then return nil, fail("STORAGE", "read binding") end
    if #rows == 0 then return nil, fail("NOT_FOUND", "binding does not exist") end
    local binding, decode_error = binding_of(rows[1] :: Row)
    if not binding then return nil, fail("STORAGE", decode_error or "binding is corrupt") end
    return binding, nil
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
    local _, write_error = db:execute("INSERT INTO bee_gateway_listener (singleton, epoch, address, secret, drained, opened_at, native_key) VALUES (1, 1, ?, ?, 0, ?, ?) " ..
        "ON CONFLICT(singleton) DO UPDATE SET epoch = bee_gateway_listener.epoch + 1, address = excluded.address, secret = excluded.secret, drained = 0, drain_deadline_at = NULL, opened_at = excluded.opened_at, native_key = excluded.native_key " ..
        "WHERE bee_gateway_listener.native_key IS NOT excluded.native_key", {current.address, secret, stamp(now_ms()), current.native_key})
    if write_error then return false, "record native listener" end
    local rechecked, recheck_error = configuration.current()
    if not rechecked or rechecked.native_key ~= current.native_key then return false, recheck_error or "native listener changed during admission" end
    return true, nil
end
function M.generation(db: sql.DB): (Generation?, Reply?)
    local listener, listener_error = listener_of(db)
    if listener_error then return nil, fail("STORAGE", listener_error) end
    if not listener then return nil, fail("UNAVAILABLE", "the gateway listener has not been opened") end
    if listener.native_key ~= nil then
        local current, current_error = configuration.current()
        if not current or current.native_key ~= listener.native_key then
            return nil, fail("UNAVAILABLE", current_error or "native listener changed; a new admission is required")
        end
    end
    local count, count_error = restarts()
    if not count then return nil, fail("UNAVAILABLE", count_error or "listener restarts unknown") end
    return {epoch = integer(listener.epoch) or 0, restarts = count}, nil
end
-- Validity of a binding now: current epoch, not revoked, not expired.
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
    if not security.can(M.MANAGE, "listener") then return fail("DENIED", "caller does not manage the gateway listener") end
    local secret, secret_error = random_text()
    if not secret then return fail("STORAGE", secret_error or "listener secret") end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local current, current_error = listener_of(db)
    if current_error then db:release(); return fail("STORAGE", current_error) end
    local epoch = (current and (integer(current.epoch) or 0) or 0) + 1
    local _, write_error = db:execute("INSERT INTO bee_gateway_listener (singleton, epoch, address, secret, drained, drain_deadline_at, opened_at, native_key) VALUES (1, ?, ?, ?, 0, NULL, ?, NULLIF(?, '')) " ..
        "ON CONFLICT(singleton) DO UPDATE SET epoch = excluded.epoch, address = excluded.address, secret = excluded.secret, drained = 0, drain_deadline_at = NULL, opened_at = excluded.opened_at, native_key = excluded.native_key",
        {epoch, address, secret, stamp(now_ms()), selected.native_key or ""})
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
-- admit: binds the admitted subject, action, attempt, thread, owner
-- incarnation, the carrier's epoch, tools and expiry. No token exists yet:
-- bytes are minted only when placement materializes them. The caller holds
-- bee.gateway.admit on the action and names the subject the launch
-- admission established; it cannot widen the tool set beyond the catalog.
function M.admit(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"subject", "action_id", "attempt_id", "thread_id", "owner_incarnation", "carrier_epoch", "tools", "hooks", "ttl_ms", "idempotency_key"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local subject, action_id, attempt_id, thread_id = bounds.id(object.subject), bounds.id(object.action_id), bounds.id(object.attempt_id), bounds.id(object.thread_id)
    if not subject then return fail("INVALID", "subject is not an identifier") end
    if not action_id then return fail("INVALID", "action_id is not an identifier") end
    if not attempt_id then return fail("INVALID", "attempt_id is not an identifier") end
    if not thread_id then return fail("INVALID", "thread_id is not an identifier") end
    local incarnation = integer(object.owner_incarnation)
    if not incarnation or incarnation < 1 then return fail("INVALID", "owner_incarnation must be a positive integer") end
    local carrier_epoch = integer(object.carrier_epoch)
    if not carrier_epoch or carrier_epoch < 1 then return fail("INVALID", "carrier_epoch must be a positive integer") end
    local tools, tools_error = bounds.ids(object.tools, true)
    if not tools then return fail("INVALID", "tools: " .. tostring(tools_error)) end
    if #tools > M.MAX_TOOLS then return fail("INVALID", "tools exceeds " .. tostring(M.MAX_TOOLS) .. " tools") end
    local known: {[string]: boolean} = {}
    for _, name in ipairs(M.TOOL_NAMES) do known[name] = true end
    for _, name in ipairs(tools) do
        if not known[name] then return fail("INVALID", "tool " .. name .. " is not in the gateway catalog") end
    end
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
    local ttl = M.DEFAULT_TTL_MS
    if object.ttl_ms ~= nil then
        local declared = bounds.integer(object.ttl_ms)
        if not declared or declared < 1 or declared > M.MAX_TTL_MS then return fail("INVALID", "ttl_ms must be between 1 and " .. tostring(M.MAX_TTL_MS)) end
        ttl = declared
    end
    local idempotency_key: string? = nil
    if object.idempotency_key ~= nil then
        idempotency_key = bounds.id(object.idempotency_key)
        if not idempotency_key then return fail("INVALID", "idempotency_key is not an identifier") end
    end
    local caller = actor()
    if not caller then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.ADMIT, action_id) then return fail("DENIED", "caller may not admit gateway bindings for action " .. action_id) end
    local request_digest, digest_error = digest_of({subject = subject, action_id = action_id, attempt_id = attempt_id, thread_id = thread_id, owner_incarnation = incarnation, carrier_epoch = carrier_epoch, tools = tools, hooks = admitted_hooks})
    if not request_digest then return fail("INVALID", digest_error or "request is not measurable") end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local synchronized, synchronization_error = synchronize_native_listener(db)
    if not synchronized then db:release(); return fail("UNAVAILABLE", synchronization_error or "native listener unavailable") end
    local listener, listener_error = listener_of(db)
    if listener_error then db:release(); return fail("STORAGE", listener_error) end
    if not listener then db:release(); return fail("UNAVAILABLE", "the gateway listener has not been opened") end
    if integer(listener.drained) == 1 then db:release(); return fail("UNAVAILABLE", "the gateway is draining; no new admissions") end
    local epoch = integer(listener.epoch) or 0
    if idempotency_key then
        local replay, replay_error = db:query("SELECT * FROM bee_gateway_bindings WHERE subject = ? AND idempotency_key = ?", {caller, idempotency_key})
        if replay_error or not replay then db:release(); return fail("STORAGE", "read bindings") end
        if #replay == 1 then
            local stored = replay[1] :: Row
            db:release()
            if stored.request_digest ~= request_digest then return fail("CONFLICT", "idempotency key reused with a different request") end
            local binding = binding_of(stored)
            if not binding then return fail("STORAGE", "binding is corrupt") end
            return succeed({binding = view(binding), replayed = true})
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
    local highest_rows, highest_error = tx:query("SELECT MAX(carrier_epoch) AS highest FROM bee_gateway_bindings WHERE attempt_id = ?", {attempt_id})
    if highest_error or not highest_rows then tx:rollback(); db:release(); return fail("STORAGE", "read bindings") end
    local highest = #highest_rows == 1 and integer((highest_rows[1] :: Row).highest) or nil
    if highest and carrier_epoch < highest then
        tx:rollback()
        db:release()
        return fail("CONFLICT", "carrier epoch " .. tostring(carrier_epoch) .. " is below the highest epoch " .. tostring(highest) .. " admitted for attempt " .. attempt_id)
    end
    local live, live_error = tx:query("SELECT * FROM bee_gateway_bindings WHERE attempt_id = ? AND carrier_epoch = ? AND revoked_at IS NULL", {attempt_id, carrier_epoch})
    if live_error or not live then tx:rollback(); db:release(); return fail("STORAGE", "read bindings") end
    if #live > 0 then
        local stored = live[1] :: Row
        tx:rollback()
        db:release()
        if stored.request_digest ~= request_digest then return fail("CONFLICT", "attempt " .. attempt_id .. " already holds a different binding under carrier epoch " .. tostring(carrier_epoch)) end
        local binding = binding_of(stored)
        if not binding then return fail("STORAGE", "binding is corrupt") end
        return succeed({binding = view(binding), replayed = true})
    end
    -- A claimed row may already be in the thread even though its later
    -- acknowledgement was lost. Supersession fences future intake, but it
    -- cannot truthfully reject that durable uncertainty; a replacement can
    -- reclaim the row under its newer carrier epoch.
    local _, reject_superseded = tx:execute("UPDATE bee_gateway_hooks SET status = 'rejected', rejected_reason = 'binding superseded', updated_at = ? WHERE status = 'queued' AND claimed_epoch = 0 AND binding_id IN (SELECT binding_id FROM bee_gateway_bindings WHERE attempt_id = ? AND carrier_epoch < ? AND revoked_at IS NULL)", {stamp(created), attempt_id, carrier_epoch})
    if reject_superseded then tx:rollback(); db:release(); return fail("STORAGE", "reject superseded hooks") end
    local _, supersede_error = tx:execute("UPDATE bee_gateway_bindings SET revoked_at = ? WHERE attempt_id = ? AND carrier_epoch < ? AND revoked_at IS NULL", {stamp(created), attempt_id, carrier_epoch})
    if supersede_error then tx:rollback(); db:release(); return fail("STORAGE", "supersede earlier bindings") end
    local _, insert_error = tx:execute([[INSERT INTO bee_gateway_bindings (binding_id, subject, action_id, attempt_id, thread_id, owner_incarnation, carrier_epoch, tools_json, hooks_json,
        epoch, credential_generation, expires_at, revoked_at, idempotency_key, request_digest, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, NULL, ?, ?, ?)]],
        {binding_id, subject, action_id, attempt_id, thread_id, incarnation, carrier_epoch, json.encode(tools), json.encode(admitted_hooks), epoch, stamp(created + ttl), idempotency_key, request_digest, stamp(created)})
    if insert_error then tx:rollback(); db:release(); return fail("STORAGE", "record binding") end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then return fail("STORAGE", "commit admission") end
    local binding: Binding = {binding_id = binding_id, subject = subject, action_id = action_id, attempt_id = attempt_id, thread_id = thread_id, owner_incarnation = incarnation,
        carrier_epoch = carrier_epoch, tools = tools, hooks = admitted_hooks, epoch = epoch, credential_generation = 0, expires_at = stamp(created + ttl), revoked = false, sealed = false}
    return succeed({binding = view(binding), replayed = false})
end
-- The binding an attempt holds under a carrier epoch: the one issued at
-- the highest epoch not above it, so a replacement carrier that took over
-- a running child inherits the binding its child already holds. The live
-- one for materialization, the latest for a check that reports revocation.
local function binding_by_carrier(db: sql.DB, attempt_id: string, carrier_epoch: integer, live: boolean): (Binding?, Reply?)
    local filter = live and " AND revoked_at IS NULL" or ""
    local rows, err = db:query("SELECT * FROM bee_gateway_bindings WHERE attempt_id = ? AND carrier_epoch <= ?" .. filter .. " ORDER BY carrier_epoch DESC, created_at DESC, binding_id DESC LIMIT 1", {attempt_id, carrier_epoch})
    if err or not rows then return nil, fail("STORAGE", "read binding") end
    if #rows == 0 then return nil, fail("NOT_FOUND", "no " .. (live and "live " or "") .. "binding for attempt " .. attempt_id .. " under carrier epoch " .. tostring(carrier_epoch)) end
    local binding, decode_error = binding_of(rows[1] :: Row)
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
    if not security.can(M.MATERIALIZE, attempt_id) then return fail("DENIED", "caller is not a materializer admitted for attempt " .. attempt_id) end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local binding, missing = binding_by_carrier(db, attempt_id, carrier_epoch, true)
    if not binding then db:release(); return missing :: Reply end
    if expected_binding and binding.binding_id ~= expected_binding then
        db:release()
        return fail("CONFLICT", "the binding under carrier epoch " .. tostring(carrier_epoch) .. " is not the one the carrier recorded")
    end
    -- The one-time key placement issued for this start: its hash must be
    -- the one on the binding and still within its window; it is consumed
    -- below by the materialization it authorizes.
    local key_hash, key_hash_error = token_hash(key)
    if not key_hash then db:release(); return fail("STORAGE", key_hash_error or "hash key") end
    local key_rows, key_error = db:query("SELECT materialization_key_hash, materialization_expires_at FROM bee_gateway_bindings WHERE binding_id = ?", {binding.binding_id})
    if key_error or not key_rows or #key_rows ~= 1 then db:release(); return fail("STORAGE", "read materialization key") end
    local issued = key_rows[1] :: Row
    if type(issued.materialization_key_hash) ~= "string" or issued.materialization_key_hash ~= key_hash then
        db:release()
        return fail("DENIED", "materialization is not authorized by placement for this start")
    end
    local window = time.parse(FORMAT, tostring(issued.materialization_expires_at))
    if not window or not time.now():before(window) then db:release(); return fail("DENIED", "the materialization authorization has expired") end
    local generation, generation_failure = M.generation(db)
    if not generation then db:release(); return generation_failure :: Reply end
    local ok, reason = M.valid(binding, generation)
    if not ok then db:release(); return fail("DENIED", reason) end
    -- The first materialization opens generation 1; a single writer wins.
    local current = binding.credential_generation
    if current == 0 then
        local opened, open_error = db:execute("UPDATE bee_gateway_bindings SET credential_generation = 1 WHERE binding_id = ? AND credential_generation = 0", {binding.binding_id})
        if open_error then db:release(); return fail("STORAGE", "open credential generation") end
        if opened and (integer(opened.rows_affected) or 0) == 1 then current = 1
        else
            local again, again_missing = binding_by_id(db, binding.binding_id)
            if not again then db:release(); return again_missing :: Reply end
            current = again.credential_generation
        end
    end
    -- One credential per kind: the tool credential always, the hook
    -- credential when the binding admits hook events. Both belong to the
    -- same generation and neither stands in for the other.
    local minted: Object = {}
    local kinds = {"tool"}
    if #binding.hooks > 0 then kinds[#kinds + 1] = "hook" end
    for _, kind in ipairs(kinds) do
        local token, token_error = random_text()
        if not token then db:release(); return fail("STORAGE", token_error or "mint token") end
        local sum, hash_error = token_hash(token)
        if not sum then db:release(); return fail("STORAGE", hash_error or "hash token") end
        local credential_id, id_error = uuid.v7()
        if id_error or not credential_id then db:release(); return fail("STORAGE", "credential id") end
        local _, insert_error = db:execute("INSERT INTO bee_gateway_credentials (credential_id, binding_id, generation, kind, token_hash, runner, materialized_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)",
            {credential_id, binding.binding_id, current, kind, sum, runner, stamp(now_ms())})
        if insert_error then db:release(); return fail("CONFLICT", "credential generation " .. tostring(current) .. " is already materialized; reissue to replace it") end
        minted[kind] = token
    end
    local _, consume_error = db:execute("UPDATE bee_gateway_bindings SET materialization_key_hash = NULL, materialization_expires_at = NULL WHERE binding_id = ?", {binding.binding_id})
    db:release()
    if consume_error then return fail("STORAGE", "consume materialization key") end
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
    local ttl = M.DEFAULT_MATERIALIZATION_MS
    if object.ttl_ms ~= nil then
        local declared = bounds.integer(object.ttl_ms)
        if not declared or declared < 1000 or declared > M.MAX_MATERIALIZATION_MS then return fail("INVALID", "ttl_ms must be between 1000 and " .. tostring(M.MAX_MATERIALIZATION_MS)) end
        ttl = declared
    end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.MANAGE, "bindings") then return fail("DENIED", "caller does not manage gateway bindings") end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local binding, missing = binding_by_carrier(db, attempt_id, carrier_epoch, true)
    if not binding then db:release(); return missing :: Reply end
    if binding.binding_id ~= binding_id then db:release(); return fail("CONFLICT", "the binding under carrier epoch " .. tostring(carrier_epoch) .. " is not the one the carrier recorded") end
    local generation, generation_failure = M.generation(db)
    if not generation then db:release(); return generation_failure :: Reply end
    local ok, reason = M.valid(binding, generation)
    if not ok then db:release(); return fail("DENIED", reason) end
    local key, key_error = random_text()
    if not key then db:release(); return fail("STORAGE", key_error or "materialization key") end
    local key_hash, hash_error = token_hash(key)
    if not key_hash then db:release(); return fail("STORAGE", hash_error or "hash key") end
    local _, write_error = db:execute("UPDATE bee_gateway_bindings SET materialization_key_hash = ?, materialization_expires_at = ? WHERE binding_id = ?", {key_hash, stamp(now_ms() + ttl), binding_id})
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
    if not db then return open_failure :: Reply end
    local binding, missing = binding_by_id(db, binding_id)
    if not binding then db:release(); return missing :: Reply end
    if not security.can(M.ADMIT, binding.action_id) then db:release(); return fail("DENIED", "caller may not reissue credentials for action " .. binding.action_id) end
    local generation, generation_failure = M.generation(db)
    if not generation then db:release(); return generation_failure :: Reply end
    local ok, reason = M.valid(binding, generation)
    if not ok then db:release(); return fail("DENIED", reason) end
    local advanced, advance_error = db:execute("UPDATE bee_gateway_bindings SET credential_generation = ? WHERE binding_id = ? AND credential_generation = ?", {expected + 1, binding_id, expected})
    if advance_error then db:release(); return fail("STORAGE", "advance credential generation") end
    if not advanced or (integer(advanced.rows_affected) or 0) ~= 1 then
        db:release()
        return fail("CONFLICT", "credential generation is not " .. tostring(expected) .. "; read the binding before reissuing")
    end
    local _, revoke_error = db:execute("UPDATE bee_gateway_credentials SET revoked_at = COALESCE(revoked_at, ?) WHERE binding_id = ? AND generation <= ?", {stamp(now_ms()), binding_id, expected})
    db:release()
    if revoke_error then return fail("STORAGE", "revoke previous credentials") end
    binding.credential_generation = expected + 1
    return succeed({binding = view(binding), generation = expected + 1})
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
    if not db then return open_failure :: Reply end
    local binding, missing = binding_by_id(db, binding_id)
    if not binding then db:release(); return missing :: Reply end
    if not security.can(M.ADMIT, binding.action_id) and not security.can(M.MANAGE, "bindings") and not security.can(M.MATERIALIZE, binding.attempt_id) then
        db:release()
        return fail("DENIED", "caller may not revoke bindings for action " .. binding.action_id)
    end
    -- Revocation invalidates credentials and rejects rows no carrier began.
    -- A claimed row can be the thread commit whose acknowledgement was lost,
    -- so it remains queued for a current or replacement carrier to reconcile.
    local at = stamp(now_ms())
    local _, write_error = db:execute("UPDATE bee_gateway_bindings SET revoked_at = COALESCE(revoked_at, ?), sealed_at = COALESCE(sealed_at, ?) WHERE binding_id = ?", {at, at, binding_id})
    if write_error then db:release(); return fail("STORAGE", "revoke binding") end
    local _, reject_error = db:execute("UPDATE bee_gateway_hooks SET status = 'rejected', rejected_reason = 'binding revoked', updated_at = ? WHERE binding_id = ? AND status = 'queued' AND claimed_epoch = 0", {at, binding_id})
    db:release()
    if reject_error then return fail("STORAGE", "reject queued hooks") end
    binding.revoked = true
    binding.sealed = true
    return succeed(view(binding))
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
    if not db then return open_failure :: Reply end
    local binding, missing = binding_by_id(db, binding_id)
    if not binding then db:release(); return missing :: Reply end
    if not security.can(M.ADMIT, binding.action_id) and not security.can(M.MANAGE, "bindings") and not security.can(M.MATERIALIZE, binding.attempt_id) then
        db:release()
        return fail("DENIED", "caller may not seal this binding")
    end
    local _, write_error = db:execute("UPDATE bee_gateway_bindings SET sealed_at = COALESCE(sealed_at, ?) WHERE binding_id = ?", {stamp(now_ms()), binding_id})
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
    if not security.can(M.MANAGE, "bindings") then return fail("DENIED", "caller does not manage gateway bindings") end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local at = stamp(now_ms())
    local result, write_error = db:execute("UPDATE bee_gateway_bindings SET revoked_at = ? WHERE attempt_id = ? AND carrier_epoch <= ? AND revoked_at IS NULL", {at, attempt_id, carrier_epoch})
    if write_error then db:release(); return fail("STORAGE", "revoke attempt bindings") end
    local _, reject_error = db:execute("UPDATE bee_gateway_hooks SET status = 'rejected', rejected_reason = 'binding revoked', updated_at = ? WHERE status = 'queued' AND claimed_epoch = 0 AND binding_id IN (SELECT binding_id FROM bee_gateway_bindings WHERE attempt_id = ? AND revoked_at = ?)", {at, attempt_id, at})
    db:release()
    if reject_error then return fail("STORAGE", "reject queued hooks") end
    return succeed({attempt_id = attempt_id, carrier_epoch = carrier_epoch, revoked = result and (integer(result.rows_affected) or 0) or 0})
end
-- check: a binding as it stands now, named by id or by attempt and carrier
-- epoch, for placement's recheck of what an attempt still holds. Bindings,
-- never bytes.
function M.check(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"binding_id", "attempt_id", "carrier_epoch"})
    if unknown_field then return fail("INVALID", unknown_field) end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local binding, missing = binding_named(db, object)
    if not binding then db:release(); return missing :: Reply end
    if not security.can(M.MATERIALIZE, binding.attempt_id) and not security.can(M.ADMIT, binding.action_id) and not security.can(M.MANAGE, "bindings") then
        db:release()
        return fail("DENIED", "caller may not check this binding")
    end
    local generation, generation_failure = M.generation(db)
    db:release()
    if not generation then return generation_failure :: Reply end
    local ok, reason = M.valid(binding, generation)
    local result = view(binding)
    result.valid = ok
    result.reason = reason
    result.generation = generation
    result.presented_count = 0
    if binding.credential_generation > 0 then
        local db_again, again_failure = open()
        if not db_again then return again_failure :: Reply end
        local presented, presented_error = db_again:query("SELECT presented_count, last_presented_at FROM bee_gateway_credentials WHERE binding_id = ? AND generation = ? AND kind = 'tool'", {binding.binding_id, binding.credential_generation})
        db_again:release()
        if presented_error or not presented then return fail("STORAGE", "read credential") end
        if #presented == 1 then
            result.presented_count = integer((presented[1] :: Row).presented_count) or 0
            result.last_presented_at = (presented[1] :: Row).last_presented_at
        end
    end
    return succeed(result)
end
-- drain: no new admissions, every outstanding wait is released at its
-- next slice, bounded reads may finish until the host-owned deadline, and
-- past it nothing is served so the host can stop the service.
function M.drain(value: unknown): Reply
    local object = bounds.object(value) or {}
    local unknown_field = bounds.fields(object, {"deadline_ms"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local deadline = M.DEFAULT_DRAIN_MS
    if object.deadline_ms ~= nil then
        local declared = bounds.integer(object.deadline_ms)
        if not declared or declared < 0 or declared > M.MAX_DRAIN_MS then return fail("INVALID", "deadline_ms must be between 0 and " .. tostring(M.MAX_DRAIN_MS)) end
        deadline = declared
    end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.MANAGE, "listener") then return fail("DENIED", "caller does not manage the gateway listener") end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local deadline_at = stamp(now_ms() + deadline)
    local _, write_error = db:execute("UPDATE bee_gateway_listener SET drained = 1, drain_deadline_at = ? WHERE singleton = 1", {deadline_at})
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
    if not listener or integer(listener.drained) ~= 1 then return {draining = false, past_deadline = false}, nil end
    local past = false
    local deadline_text = text(listener.drain_deadline_at)
    if deadline_text then
        local deadline = time.parse(FORMAT, deadline_text)
        past = deadline ~= nil and not time.now():before(deadline)
    end
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
    if not db then return open_failure :: Reply end
    local listener, listener_error = listener_of(db)
    if listener_error or not listener then db:release(); return fail("UNAVAILABLE", listener_error or "the gateway listener has not been opened") end
    local generation, generation_failure = M.generation(db)
    if not generation then db:release(); return generation_failure :: Reply end
    local binding: Binding? = nil
    if object.binding_id ~= nil then
        local binding_id = bounds.id(object.binding_id)
        if not binding_id then db:release(); return fail("INVALID", "binding_id is not an identifier") end
        local found, missing = binding_by_id(db, binding_id)
        if not found then db:release(); return missing :: Reply end
        binding = found
    end
    db:release()
    local selected, selection_error = configuration.current()
    if not selected then return fail("UNAVAILABLE", selection_error or "gateway endpoint") end
    if listener.address ~= selected.address or listener.native_key ~= selected.native_key then
        return fail("UNAVAILABLE", "the stored listener is not the host-selected execution")
    end
    local nonce, nonce_error = random_text()
    if not nonce then return fail("STORAGE", nonce_error or "nonce") end
    local address = tostring(listener.address)
    local response, request_error = http_client.get("http://" .. address .. "/ready", {timeout = "2s", query = {nonce = nonce}})
    if request_error or not response then return fail("UNAVAILABLE", "the listener did not answer: " .. tostring(request_error)) end
    if response.status_code ~= 200 then return fail("UNAVAILABLE", "the listener answered " .. tostring(response.status_code)) end
    local answered: unknown, decode_error = json.decode(tostring(response.body))
    if decode_error or type(answered) ~= "table" then return fail("UNAVAILABLE", "the listener answered unreadably") end
    local reported = answered :: Object
    local verified, verify_failure = M.verify(tostring(listener.secret), generation, nonce, reported)
    if not verified then return verify_failure :: Reply end
    local result: Object = {generation = generation, address = address, listening = true}
    if binding then
        local ok, reason = M.valid(binding, generation)
        result.binding = view(binding)
        result.binding_valid = ok
        result.binding_reason = reason
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
    local proof, proof_error = M.proof(tostring(listener.secret), generation, nonce)
    if not proof then return nil, fail("STORAGE", proof_error or "proof") end
    return {epoch = generation.epoch, restarts = generation.restarts, proof = proof}, nil
end
-- authenticate: a presented token against the action in the URL and the
-- endpoint's credential kind. Its hash must name a live credential of that
-- kind in the binding's current generation, the binding must name that
-- action, and it must be valid now. A hook credential never opens the tool
-- endpoint and a tool credential never opens the hook endpoint.
function M.authenticate(token: string, action_id: string, kind: string): (Binding?, Reply?)
    if #token == 0 or #token > 128 then return nil, fail("UNAUTHENTICATED", "token is not presentable") end
    local sum, hash_error = token_hash(token)
    if not sum then return nil, fail("STORAGE", hash_error or "hash token") end
    local db, open_failure = open()
    if not db then return nil, open_failure end
    local rows, err = db:query("SELECT credential_id, binding_id, generation, kind, revoked_at FROM bee_gateway_credentials WHERE token_hash = ?", {sum})
    if err or not rows then db:release(); return nil, fail("STORAGE", "read credential") end
    if #rows == 0 then db:release(); return nil, fail("UNAUTHENTICATED", "token is not admitted") end
    local credential = rows[1] :: Row
    if credential.revoked_at ~= nil then db:release(); return nil, fail("UNAUTHENTICATED", "token was replaced or revoked") end
    if tostring(credential.kind) ~= kind then db:release(); return nil, fail("UNAUTHENTICATED", "credential is a " .. tostring(credential.kind) .. " credential, not admitted on this endpoint") end
    local binding, missing = binding_by_id(db, tostring(credential.binding_id))
    if not binding then db:release(); return nil, missing end
    local generation, generation_failure = M.generation(db)
    if not generation then db:release(); return nil, generation_failure end
    if (integer(credential.generation) or 0) ~= binding.credential_generation then db:release(); return nil, fail("UNAUTHENTICATED", "token belongs to a superseded credential generation") end
    if binding.action_id ~= action_id then db:release(); return nil, fail("DENIED", "token is bound to another action") end
    local ok, reason = M.valid(binding, generation)
    if not ok then db:release(); return nil, fail("UNAUTHENTICATED", reason) end
    -- An accepted presentation is counted; the count is what proves a
    -- client authenticated without any bytes in evidence.
    local _, count_error = db:execute("UPDATE bee_gateway_credentials SET presented_count = presented_count + 1, last_presented_at = ? WHERE credential_id = ?", {stamp(now_ms()), tostring(credential.credential_id)})
    db:release()
    if count_error then return nil, fail("STORAGE", "count presentation") end
    return binding, nil
end
-- submit_hook: an observation the attempt reports about itself, queued in
-- the gateway store under the binding's identity until a carrier commits
-- it. The payload's identifiers are recorded as claims; nothing content
-- bearing is kept; control fields are dropped first. Identity is the
-- occurrence the event carries: an identical replay answers the queued or
-- committed event again, a changed submission under the same occurrence
-- conflicts, and an event without a unique occurrence is recorded per
-- delivery as ambiguous.
function M.submit_hook(binding: Binding, payload: Object, provenance: string): Reply
    local cleaned = hooks.control_free(payload)
    local event = bounds.id(cleaned.hook_event_name) or bounds.id(cleaned.event) or ""
    if event == "" then return fail("INVALID", "hook_event_name is required") end
    if not hooks.known(event) then return fail("INVALID", "event " .. event .. " is not in the hook catalog") end
    local admitted = false
    for _, name in ipairs(binding.hooks) do if name == event then admitted = true end end
    if not admitted then return fail("DENIED", "event " .. event .. " is not admitted for this binding") end
    local submission, normalize_error = hooks.normalize(event, cleaned)
    if not submission then return fail("INVALID", normalize_error or "hook") end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    -- The seal check, the replay check, the bound and the insert are one
    -- transaction, so no submission is accepted after the seal's point.
    local tx, begin_error = db:begin()
    if not tx then db:release(); return fail("STORAGE", "begin intake") end
    local function done(reply: Reply): Reply
        tx:rollback()
        db:release()
        return reply
    end
    local state, state_error = tx:query("SELECT sealed_at, revoked_at FROM bee_gateway_bindings WHERE binding_id = ?", {binding.binding_id})
    if state_error or not state or #state ~= 1 then return done(fail("STORAGE", "read binding")) end
    local current = state[1] :: Row
    if not submission.ambiguous then
        local existing, existing_error = tx:query("SELECT event_id, digest, status, rejected_reason FROM bee_gateway_hooks WHERE binding_id = ? AND event = ? AND occurrence = ? AND ambiguous = 0", {binding.binding_id, event, submission.occurrence})
        if existing_error or not existing then return done(fail("STORAGE", "read hooks")) end
        if #existing == 1 then
            local stored = existing[1] :: Row
            if tostring(stored.digest) ~= submission.digest then return done(fail("CONFLICT", "occurrence " .. submission.occurrence .. " of " .. event .. " was already submitted with different content")) end
            return done(succeed({event_id = tostring(stored.event_id), status = tostring(stored.status), replayed = true, ambiguous = false, rejected_reason = stored.rejected_reason}))
        end
    end
    if current.revoked_at ~= nil then return done(fail("DENIED", "intake is closed: binding revoked")) end
    if current.sealed_at ~= nil then return done(fail("DENIED", "intake is sealed: the attempt's child has ended")) end
    local queued, count_error = tx:query("SELECT COUNT(*) AS queued FROM bee_gateway_hooks WHERE binding_id = ? AND status = 'queued'", {binding.binding_id})
    if count_error or not queued or #queued ~= 1 then return done(fail("STORAGE", "count hooks")) end
    if (integer((queued[1] :: Row).queued) or 0) >= hooks.MAX_QUEUE then
        return done(fail("OVERLOAD", "the binding holds " .. tostring(hooks.MAX_QUEUE) .. " queued hooks; retry after " .. tostring(hooks.RETRY_AFTER_MS) .. " ms"))
    end
    local sequence_rows, sequence_error = tx:query("SELECT COALESCE(MAX(sequence), 0) AS last FROM bee_gateway_hooks WHERE binding_id = ?", {binding.binding_id})
    if sequence_error or not sequence_rows or #sequence_rows ~= 1 then return done(fail("STORAGE", "sequence hooks")) end
    local sequence = (integer((sequence_rows[1] :: Row).last) or 0) + 1
    local event_id, id_error = uuid.v7()
    if id_error or not event_id then return done(fail("STORAGE", "event id")) end
    local at = stamp(now_ms())
    local _, insert_error = tx:execute("INSERT INTO bee_gateway_hooks (event_id, binding_id, attempt_id, action_id, carrier_epoch, event, occurrence, ambiguous, digest, fields_json, provenance, status, sequence, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', ?, ?, ?)",
        {event_id, binding.binding_id, binding.attempt_id, binding.action_id, binding.carrier_epoch, event, submission.occurrence, submission.ambiguous and 1 or 0, submission.digest, json.encode(submission.fields), provenance, sequence, at, at})
    if insert_error then return done(fail("STORAGE", "queue hook")) end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then return fail("STORAGE", "commit intake") end
    return succeed({event_id = event_id, status = "queued", replayed = false, ambiguous = submission.ambiguous})
end
-- hook_status: what became of one submission; unknown when nothing under
-- that id exists for the binding, which after a loss permits a replay.
function M.hook_status(binding: Binding, event_id: string): Reply
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local rows, err = db:query("SELECT event, occurrence, ambiguous, status, sequence, claimed_epoch, rejected_reason FROM bee_gateway_hooks WHERE event_id = ? AND binding_id = ?", {event_id, binding.binding_id})
    db:release()
    if err or not rows then return fail("STORAGE", "read hook") end
    if #rows == 0 then return succeed({event_id = event_id, status = "unknown"}) end
    local row = rows[1] :: Row
    return succeed({event_id = event_id, status = tostring(row.status), event = tostring(row.event), occurrence = tostring(row.occurrence), ambiguous = integer(row.ambiguous) == 1, sequence = integer(row.sequence) or 0,
        claimed_epoch = integer(row.claimed_epoch) or 0, rejected_reason = row.rejected_reason})
end
-- hook_queue: the queued and committed submissions of a binding in order,
-- for the carrier that will commit them and for proofs. Fields only.
function M.hook_queue(binding: Binding): Reply
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local rows, err = db:query("SELECT event_id, event, occurrence, ambiguous, digest, fields_json, provenance, status, sequence, created_at, claimed_epoch, rejected_reason FROM bee_gateway_hooks WHERE binding_id = ? ORDER BY sequence", {binding.binding_id})
    db:release()
    if err or not rows then return fail("STORAGE", "read hooks") end
    local list: {Object} = {}
    for index, row in ipairs(rows) do
        local fields: unknown = json.decode(tostring((row :: Row).fields_json))
        list[index] = {event_id = tostring((row :: Row).event_id), event = tostring((row :: Row).event), occurrence = tostring((row :: Row).occurrence), ambiguous = integer((row :: Row).ambiguous) == 1,
            digest = tostring((row :: Row).digest), fields = fields, provenance = tostring((row :: Row).provenance), status = tostring((row :: Row).status), sequence = integer((row :: Row).sequence) or 0, created_at = tostring((row :: Row).created_at),
            claimed_epoch = integer((row :: Row).claimed_epoch) or 0, rejected_reason = (row :: Row).rejected_reason}
    end
    return succeed({hooks = list})
end
-- The binding admission and every hook mutation serialize this comparison in
-- one gateway-store transaction. The thread carrier epoch still fences the
-- record commit; this only prevents a preflight read from letting an old
-- gateway claim or acknowledgment race a later admission.
local function intake_epoch(tx: sql.Transaction, attempt_id: string, carrier_epoch: integer): Reply?
    local rows, err = tx:query("SELECT MAX(carrier_epoch) AS highest FROM bee_gateway_bindings WHERE attempt_id = ?", {attempt_id})
    if err or not rows or #rows ~= 1 then return fail("STORAGE", "read bindings") end
    local highest = integer((rows[1] :: Row).highest) or 0
    if carrier_epoch < highest then
        return fail("CONFLICT", "carrier epoch " .. tostring(carrier_epoch) .. " is below the highest epoch " .. tostring(highest) .. " admitted for attempt " .. attempt_id)
    end
    return nil
end
local function intake_binding(tx: sql.Transaction, binding_id: string): (Binding?, Reply?)
    local rows, err = tx:query("SELECT * FROM bee_gateway_bindings WHERE binding_id = ?", {binding_id})
    if err or not rows then return nil, fail("STORAGE", "read binding") end
    if #rows == 0 then return nil, fail("NOT_FOUND", "binding does not exist") end
    local binding, decode_error = binding_of(rows[1] :: Row)
    if not binding then return nil, fail("STORAGE", decode_error or "binding is corrupt") end
    return binding, nil
end
local function intake_generation(tx: sql.Transaction): (Generation?, Reply?)
    local rows, err = tx:query("SELECT epoch FROM bee_gateway_listener WHERE singleton = 1")
    if err or not rows then return nil, fail("STORAGE", "read listener") end
    if #rows == 0 then return nil, fail("UNAVAILABLE", "the gateway listener has not been opened") end
    local count, count_error = restarts()
    if not count then return nil, fail("UNAVAILABLE", count_error or "listener restarts unknown") end
    return {epoch = integer((rows[1] :: Row).epoch) or 0, restarts = count}, nil
end
local function intake_caller(binding: Binding): Reply?
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.ADMIT, binding.action_id) and not security.can(M.MANAGE, "bindings") then return fail("DENIED", "caller may not drain this binding's hooks") end
    return nil
end
local function intake_request(value: unknown, extra: {string}): (Object?, Binding?, sql.DB?, integer?, Reply?)
    local object = bounds.object(value)
    if not object then return nil, nil, nil, nil, fail("INVALID", "request must be an object") end
    local fields = {"binding_id", "carrier_epoch"}
    for _, name in ipairs(extra) do fields[#fields + 1] = name end
    local unknown_field = bounds.fields(object, fields)
    if unknown_field then return nil, nil, nil, nil, fail("INVALID", unknown_field) end
    local binding_id = bounds.id(object.binding_id)
    if not binding_id then return nil, nil, nil, nil, fail("INVALID", "binding_id is not an identifier") end
    local carrier_epoch = integer(object.carrier_epoch)
    if not carrier_epoch or carrier_epoch < 1 then return nil, nil, nil, nil, fail("INVALID", "carrier_epoch must be a positive integer") end
    local db, open_failure = open()
    if not db then return nil, nil, nil, nil, open_failure end
    local binding, missing = binding_by_id(db, binding_id)
    if not binding then db:release(); return nil, nil, nil, nil, missing end
    local refusal = intake_caller(binding)
    if refusal then db:release(); return nil, nil, nil, nil, refusal end
    return object, binding, db, carrier_epoch, nil
end
-- hook_claim: the carrier takes the next queued submissions of its binding
-- under its epoch. Rows a lower epoch claimed are taken over; rows already
-- claimed by this epoch are redelivered until acknowledgment, while rows a
-- higher epoch claimed are never touched. An invalid binding rejects only
-- work no carrier claimed. It still lets a current or replacement carrier
-- reclaim claimed rows, because their thread commit may have succeeded before
-- the acknowledgement was lost.
function M.hook_claim(value: unknown): Reply
    local object, binding, db, carrier_epoch, refusal = intake_request(value, {"limit"})
    if not object or not binding or not db or not carrier_epoch then return refusal :: Reply end
    local limit = M.MAX_HOOK_CLAIM
    if object.limit ~= nil then
        local declared = bounds.integer(object.limit)
        if not declared or declared < 1 or declared > M.MAX_HOOK_CLAIM then db:release(); return fail("INVALID", "limit must be between 1 and " .. tostring(M.MAX_HOOK_CLAIM)) end
        limit = declared
    end
    local tx, begin_error = db:begin()
    if not tx then db:release(); return fail("STORAGE", "begin hook claim") end
    local current_binding, binding_failure = intake_binding(tx, binding.binding_id)
    if not current_binding then tx:rollback(); db:release(); return binding_failure :: Reply end
    local generation, generation_failure = intake_generation(tx)
    if not generation then tx:rollback(); db:release(); return generation_failure :: Reply end
    local epoch_refusal = intake_epoch(tx, current_binding.attempt_id, carrier_epoch)
    if epoch_refusal then tx:rollback(); db:release(); return epoch_refusal end
    local at = stamp(now_ms())
    local ok, reason = M.valid(current_binding, generation)
    local recovery_only = false
    if not ok then
        -- A credential can no longer submit after revocation, expiry or a
        -- listener-epoch change. This internal operation is independently
        -- authorized and carrier-epoch fenced, so it may recover only rows
        -- whose delivery already began; unclaimed rows are terminally refused.
        local _, reject_error = tx:execute("UPDATE bee_gateway_hooks SET status = 'rejected', rejected_reason = ?, updated_at = ? WHERE binding_id = ? AND status = 'queued' AND claimed_epoch = 0", {reason, at, current_binding.binding_id})
        if reject_error then tx:rollback(); db:release(); return fail("STORAGE", "reject unclaimed hooks") end
        recovery_only = true
    end
    local claimed_filter = recovery_only and " AND claimed_epoch > 0" or ""
    local rows, err = tx:query("SELECT event_id FROM bee_gateway_hooks WHERE binding_id = ? AND status = 'queued' AND claimed_epoch <= ?" .. claimed_filter .. " ORDER BY sequence LIMIT ?", {current_binding.binding_id, carrier_epoch, limit})
    if err or not rows then tx:rollback(); db:release(); return fail("STORAGE", "read queued hooks") end
    local claimed: {Object} = {}
    for _, row in ipairs(rows) do
        local event_id = tostring((row :: Row).event_id)
        local result, claim_error = tx:execute("UPDATE bee_gateway_hooks SET claimed_epoch = ?, claimed_at = ?, updated_at = ? WHERE event_id = ? AND status = 'queued' AND claimed_epoch <= ?", {carrier_epoch, at, at, event_id, carrier_epoch})
        if claim_error then tx:rollback(); db:release(); return fail("STORAGE", "claim hook") end
        if result and (integer(result.rows_affected) or 0) == 1 then
            local detail, detail_error = tx:query("SELECT event_id, event, occurrence, ambiguous, digest, fields_json, provenance, sequence, created_at FROM bee_gateway_hooks WHERE event_id = ?", {event_id})
            if detail_error or not detail or #detail ~= 1 then tx:rollback(); db:release(); return fail("STORAGE", "read claimed hook") end
            local item = detail[1] :: Row
            local fields: unknown = json.decode(tostring(item.fields_json))
            claimed[#claimed + 1] = {event_id = event_id, event = tostring(item.event), occurrence = tostring(item.occurrence), ambiguous = integer(item.ambiguous) == 1, digest = tostring(item.digest),
                fields = fields, provenance = tostring(item.provenance), sequence = integer(item.sequence) or 0, created_at = tostring(item.created_at)}
        end
    end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then return fail("STORAGE", "commit hook claim") end
    return succeed({binding_id = binding.binding_id, carrier_epoch = carrier_epoch, hooks = claimed})
end
-- Keeps the retained rows of a binding within the bounds by dropping the
-- oldest committed or rejected ones; queued rows are never pruned.
local function prune(db: sql.DB, binding_id: string): string?
    local rows, err = db:query("SELECT event_id, LENGTH(fields_json) AS bytes FROM bee_gateway_hooks WHERE binding_id = ? AND status IN ('committed', 'rejected') ORDER BY sequence DESC", {binding_id})
    if err or not rows then return "read retained hooks" end
    local kept = 0
    local bytes = 0
    for _, row in ipairs(rows) do
        kept = kept + 1
        bytes = bytes + (integer((row :: Row).bytes) or 0)
        if kept > M.MAX_RETAINED_HOOKS or bytes > M.MAX_RETAINED_HOOK_BYTES then
            local _, delete_error = db:execute("DELETE FROM bee_gateway_hooks WHERE event_id = ?", {tostring((row :: Row).event_id)})
            if delete_error then return "prune retained hooks" end
        end
    end
    return nil
end
-- hook_ack: the carrier reports that the named claimed submissions are
-- thread records; only the epoch that claimed them may say so.
function M.hook_ack(value: unknown): Reply
    local object, binding, db, carrier_epoch, refusal = intake_request(value, {"event_ids"})
    if not object or not binding or not db or not carrier_epoch then return refusal :: Reply end
    local event_ids, ids_error = bounds.ids(object.event_ids, true)
    if not event_ids then db:release(); return fail("INVALID", "event_ids: " .. tostring(ids_error)) end
    if #event_ids > M.MAX_HOOK_CLAIM then db:release(); return fail("INVALID", "event_ids exceeds " .. tostring(M.MAX_HOOK_CLAIM)) end
    local tx, begin_error = db:begin()
    if not tx then db:release(); return fail("STORAGE", "begin hook acknowledgment") end
    local epoch_refusal = intake_epoch(tx, binding.attempt_id, carrier_epoch)
    if epoch_refusal then tx:rollback(); db:release(); return epoch_refusal end
    local at = stamp(now_ms())
    local acknowledged = 0
    for _, event_id in ipairs(event_ids) do
        -- Only the epoch that claimed a row may acknowledge it: a replacement
        -- takes the row over first, then commits it, then acknowledges.
        local result, ack_error = tx:execute("UPDATE bee_gateway_hooks SET status = 'committed', updated_at = ? WHERE event_id = ? AND binding_id = ? AND status = 'queued' AND claimed_epoch = ?", {at, event_id, binding.binding_id, carrier_epoch})
        if ack_error then tx:rollback(); db:release(); return fail("STORAGE", "acknowledge hook") end
        if result and (integer(result.rows_affected) or 0) == 1 then acknowledged = acknowledged + 1 end
    end
    local _, commit_error = tx:commit()
    if commit_error then db:release(); return fail("STORAGE", "commit hook acknowledgment") end
    local prune_error = prune(db, binding.binding_id)
    db:release()
    if prune_error then return fail("STORAGE", prune_error) end
    return succeed({binding_id = binding.binding_id, acknowledged = acknowledged})
end
-- hook_reject: the carrier ends intake for its binding. Only unclaimed rows
-- are proved never to have reached a thread commit; claimed rows stay for
-- reconciliation rather than being falsely called rejected.
function M.hook_reject(value: unknown): Reply
    local object, binding, db, carrier_epoch, refusal = intake_request(value, {"reason"})
    if not object or not binding or not db or not carrier_epoch then return refusal :: Reply end
    local reason = bounds.line(object.reason, 120)
    if not reason or reason == "" then db:release(); return fail("INVALID", "reason is required") end
    local tx, begin_error = db:begin()
    if not tx then db:release(); return fail("STORAGE", "begin hook rejection") end
    local epoch_refusal = intake_epoch(tx, binding.attempt_id, carrier_epoch)
    if epoch_refusal then tx:rollback(); db:release(); return epoch_refusal end
    local result, reject_error = tx:execute("UPDATE bee_gateway_hooks SET status = 'rejected', rejected_reason = ?, updated_at = ? WHERE binding_id = ? AND status = 'queued' AND claimed_epoch = 0", {reason, stamp(now_ms()), binding.binding_id})
    if reject_error then tx:rollback(); db:release(); return fail("STORAGE", "reject queued hooks") end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then return fail("STORAGE", "commit hook rejection") end
    return succeed({binding_id = binding.binding_id, rejected = result and (integer(result.rows_affected) or 0) or 0})
end
return M
