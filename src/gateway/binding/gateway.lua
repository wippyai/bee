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
local contract = require("contract")
local system = require("system")
local crypto = require("crypto")
local base64 = require("base64")
local http_client = require("http_client")
local bounds = require("bounds")
local canonical = require("canonical")
local capability_model = require("capability_model")
local node_database = require("node_database")
local registry = require("registry")
local configuration = require("configuration")
local hooks = require("hooks")
local mcp = require("mcp")
local surface = require("surface")
local trait_access = require("trait_access")
local agent_trait = require("agent_trait")
local session_traits = require("session_traits")
local surface_store = require("surface_store")
local grant_store = require("grant_store")
local binding_store = require("binding_store")
local credential_store = require("credential_store")
local external_store = require("external_store")
local subject_call = require("subject_call")
local hook_store = require("hook_store")
local listener_store = require("listener_store")
local access = require("access")
local elevation = require("elevation")
local capability_use = require("capability_use")
local installation = require("installation")
local sessions = require("sessions")
local M = {}
function M.accepts_host(value: unknown): boolean
    local current = configuration.current()
    return current ~= nil and configuration.host_matches(value, current.address)
end
M.ADMIT = "bee.gateway.admit"
M.MANAGE = "bee.gateway.manage"
M.MATERIALIZE = "bee.gateway.materialize"
M.INSTALLATION_WORK = "bee.gateway.installation_work"
M.LISTENER_SERVICE = "bee.gateway.env:listener_ref"
M.ENDPOINT = configuration.ENDPOINT
M.MAX_TTL_MS = 86400000
M.DEFAULT_TTL_MS = 3600000
M.MAX_DRAIN_MS = 600000
M.DEFAULT_DRAIN_MS = 30000
M.TOKEN_BYTES = 32
M.MAX_RETAINED_HOOKS = 256
M.MAX_RETAINED_HOOK_BYTES = 524288
M.MAX_HOOK_CLAIM = 32
M.DEFAULT_MATERIALIZATION_MS = 60000
M.MAX_MATERIALIZATION_MS = 600000
M.MAX_TOOLS = 32
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown}
type Row = {[string]: unknown}
type Object = {[string]: unknown}
type OriginView = {view_id: string, instance_id: string}
type Binding = {agent_traits: {string}?, agent_profile_write: boolean?, binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, owner_incarnation: integer, carrier_epoch: integer,
    approving_grant_id: string?, tools: {string}, hooks: {string}, epoch: integer, credential_generation: integer, expires_at: string, revoked: boolean, sealed: boolean, policy_ref: string?, workspace_id: string?, workspace_name: string, origin_view: OriginView?}
type Generation = {epoch: integer, restarts: integer}
type BoundSurface = {configuration: surface.Surface, selection: surface.Selection, revision: integer, digest: string}
type RuntimeGrant = {access_approval_id: string, access_proposal_digest: string, surface_revision: integer, surface_digest: string}
type Drain = {draining: boolean, past_deadline: boolean}
type HookRecord = {event_id: string, event: string, occurrence: string, ambiguous: boolean, digest: string, fields: Object,
    provenance: string, sequence: integer, created_at: string}
type HookQueueItem = HookRecord & {status: string, claimed_epoch: integer, rejected_reason: string?}
type HookStatus = {status: string, event: string, occurrence: string, ambiguous: boolean, sequence: integer,
    claimed_epoch: integer, rejected_reason: string?}
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
    return value
end
local function integer(value: unknown): integer?
    return bounds.integer(value)
end
local function reference(id: string, field: string, what: string): (string?, string?)
    local entry, err = registry.get(id)
    if err or not entry then return nil, what .. " reference is not in the registry" end
    local data = entry.data
    if type(data) ~= "table" then return nil, what .. " reference has no data" end
    local target = (data)[field]
    if type(target) ~= "string" or target == "" then return nil, what .. " reference is not linked" end
    return target, nil
end
function M.endpoint(): (string?, string?)
    return configuration.endpoint()
end
local function open(): (sql.DB?, Reply?)
    local db, open_error = node_database.open()
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
-- SQLite stores absent optional text as NULL or an empty string.
local function optional_text(value: unknown, limit: integer): (string?, boolean)
    if value == nil then return nil, true end
    local declared = bounds.text(value, limit)
    if not declared then return nil, false end
    if declared == "" then return nil, true end
    return declared, true
end
local function optional_timestamp(value: unknown): (string?, boolean)
    local declared, valid = optional_text(value, 64)
    if not valid or not declared then return declared, valid end
    local parsed, parse_error = time.parse(FORMAT, declared)
    if parse_error or not parsed then return nil, false end
    return declared, true
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
    local service, service_error = reference(M.LISTENER_SERVICE, "resource_ref", "gateway listener")
    if not service then return nil, service_error end
    local state, state_error = system.supervisor.state(service)
    if state_error or not state then return nil, "listener service state unavailable" end
    local retry_count = bounds.count(state.retry_count)
    if not retry_count then return nil, "listener service retry count is invalid" end
    return retry_count, nil
end
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
    if tools_error or not names or #names > M.MAX_TOOLS then return nil, "binding tools are corrupt" end
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
local function stored_hook_fields(value: unknown): (Object?, string?)
    local encoded = bounds.text(value, 8192)
    if not encoded then return nil, "hook fields JSON is corrupt" end
    local decoded, decode_error = json.decode(encoded)
    if decode_error then return nil, "hook fields JSON is corrupt" end
    local fields, fields_error = hooks.stored_fields(decoded)
    if not fields then return nil, fields_error or "hook fields are corrupt" end
    return fields, nil
end
local function hook_record(value: unknown): (HookRecord?, string?)
    local row = bounds.object(value)
    if not row then return nil, "hook row is corrupt" end
    local event_id, event = bounds.id(row.event_id), bounds.text(row.event, 64)
    local occurrence = bounds.text(row.occurrence, 256)
    local ambiguous = bounds.count(row.ambiguous)
    local digest = bounds.text(row.digest, 64)
    local provenance = bounds.text(row.provenance, 80)
    local sequence = bounds.count(row.sequence)
    local created_at = bounds.text(row.created_at, 64)
    local created, created_error = time.parse(FORMAT, created_at or "")
    local fields, fields_error = stored_hook_fields(row.fields_json)
    if not event_id then return nil, "hook row identity is corrupt" end
    if not event or not hooks.known(event) then return nil, "hook event is corrupt" end
    if not occurrence or occurrence == "" then return nil, "hook occurrence is corrupt" end
    if ambiguous == nil or (ambiguous ~= 0 and ambiguous ~= 1) then return nil, "hook ambiguity flag is corrupt" end
    if not digest then return nil, "hook digest is corrupt" end
    if #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return nil, "hook digest is corrupt" end
    if not provenance or provenance == "" then return nil, "hook provenance is corrupt" end
    if sequence == nil or sequence == 0 then return nil, "hook sequence is corrupt" end
    if not created_at or created_error or not created then return nil, "hook creation time is corrupt" end
    if not fields then return nil, fields_error or "hook fields are corrupt" end
    if fields.event ~= event then return nil, "hook row event does not match its fields" end
    return {event_id = event_id, event = event, occurrence = occurrence, ambiguous = ambiguous == 1, digest = digest,
        fields = fields, provenance = provenance, sequence = sequence, created_at = created_at}, nil
end
local function hook_status(value: unknown): (HookStatus?, string?)
    local row = bounds.object(value)
    if not row then return nil, "hook status row is corrupt" end
    local event = bounds.text(row.event, 64)
    local occurrence = bounds.text(row.occurrence, 256)
    local ambiguous = bounds.count(row.ambiguous)
    local status = bounds.text(row.status, 16)
    local sequence, claimed_epoch = bounds.count(row.sequence), bounds.count(row.claimed_epoch)
    local rejected_reason, reason_valid = optional_text(row.rejected_reason, 120)
    if not event or not hooks.known(event) then return nil, "hook status event is corrupt" end
    if not occurrence or occurrence == "" then return nil, "hook status occurrence is corrupt" end
    if ambiguous == nil or (ambiguous ~= 0 and ambiguous ~= 1) then return nil, "hook status ambiguity flag is corrupt" end
    if status ~= "queued" and status ~= "committed" and status ~= "rejected" then return nil, "hook status state is corrupt" end
    if sequence == nil or sequence == 0 then return nil, "hook status sequence is corrupt" end
    if claimed_epoch == nil then return nil, "hook claimed epoch is corrupt" end
    if not reason_valid then return nil, "hook rejection reason is corrupt" end
    return {status = status, event = event, occurrence = occurrence, ambiguous = ambiguous == 1, sequence = sequence,
        claimed_epoch = claimed_epoch, rejected_reason = rejected_reason}, nil
end
local function binding_by_id(db: sql.DB, binding_id: string): (Binding?, Reply?)
    local rows, err = binding_store.by_id(db, binding_id)
    if err or not rows then return nil, fail("STORAGE", "read binding") end
    if #rows == 0 then return nil, fail("NOT_FOUND", "binding does not exist") end
    local binding, decode_error = binding_of(rows[1])
    if not binding then return nil, fail("STORAGE", decode_error or "binding is corrupt") end
    return binding, nil
end
-- Resolve the durable gateway context for an approved effect. The stored
-- attempt identity, rather than proposal fields, supplies the binding that
-- the effect worker verifies. The caller names the tools the binding must
-- grant; an omitted list keeps the installation tools.
function M.effect_binding(value: unknown): Reply
    if not security.can(M.INSTALLATION_WORK, "resolve_binding") then
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
        if named and #named >= 1 and #named <= M.MAX_TOOLS then
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
    if not security.can(M.MANAGE, "listener") then return fail("DENIED", "caller does not manage the gateway listener") end
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
            local existing, err = session_traits.read(seed_tx, binding.action_id, id)
            if err then seed_tx:rollback(); seed_db:release(); return fail("STORAGE", err) end
            if not existing and not bounds.member(id, saved) then pending[#pending + 1] = id end
        end
        seed_tx:rollback()
        seed_db:release()
    end
    local approval_id: string? = nil
    if #pending > 0 then
        local requested = M.request_access(binding, {idempotency_key = "profile-traits", traits = pending, reason = "This session's profile selects these application traits."})
        if not requested.ok then return requested end
        local requested_value = bounds.object(requested.value)
        approval_id = requested_value and bounds.id(requested_value.approval_id)
    end
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
    if #tools > M.MAX_TOOLS then return fail("INVALID", "tools exceeds " .. tostring(M.MAX_TOOLS) .. " tools") end
    local selected_surface: unknown = object.surface
    if selected_surface == nil then
        selected_surface = {tools = {}, traits = {}, base_tools = tools, active_traits = {}, fixed_context = {}, dynamic_keys = {}}
    end
    local prepared, initial, surface_error = surface.prepare(selected_surface, mcp.TOOLS, tools)
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
    local generation, generation_failure = M.generation(db)
    if not generation then db:release(); return assert(generation_failure) end
    local ok, reason = M.valid(binding, generation)
    if not ok then db:release(); return fail("DENIED", reason) end
    -- The first materialization opens generation 1; a single writer wins.
    local current = binding.credential_generation
    if current == 0 then
        local opened, open_error = binding_store.open_credential_generation(db, binding.binding_id)
        if open_error then db:release(); return fail("STORAGE", "open credential generation") end
        local affected = opened and bounds.count(opened.rows_affected)
        if not affected or affected > 1 then db:release(); return fail("STORAGE", "credential generation result is corrupt") end
        if affected == 1 then current = 1 else
            local again, again_missing = binding_by_id(db, binding.binding_id)
            if not again then db:release(); return again_missing end
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
        local _, insert_error = credential_store.insert(db, credential_id, binding.binding_id, current, kind, sum, runner, stamp(now_ms()))
        if insert_error then db:release(); return fail("CONFLICT", "credential generation " .. tostring(current) .. " is already materialized; reissue to replace it") end
        minted[kind] = token
    end
    local _, consume_error = binding_store.consume_materialization_key(db, binding.binding_id)
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
    if not db then return open_failure end
    local binding, missing = binding_by_carrier(db, attempt_id, carrier_epoch, true)
    if not binding then db:release(); return missing end
    if binding.binding_id ~= binding_id then db:release(); return fail("CONFLICT", "the binding under carrier epoch " .. tostring(carrier_epoch) .. " is not the one the carrier recorded") end
    local generation, generation_failure = M.generation(db)
    if not generation then db:release(); return assert(generation_failure) end
    local ok, reason = M.valid(binding, generation)
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
    if not security.can(M.ADMIT, binding.action_id) then db:release(); return fail("DENIED", "caller may not reissue credentials for action " .. binding.action_id) end
    local generation, generation_failure = M.generation(db)
    if not generation then db:release(); return assert(generation_failure) end
    local ok, reason = M.valid(binding, generation)
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
    if not security.can(M.ADMIT, binding.action_id) and not security.can(M.MANAGE, "bindings") and not security.can(M.MATERIALIZE, binding.attempt_id) then
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
    if not security.can(M.ADMIT, binding.action_id) and not security.can(M.MANAGE, "bindings") and not security.can(M.MATERIALIZE, binding.attempt_id) then
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
    if not security.can(M.MANAGE, "bindings") then return fail("DENIED", "caller does not manage gateway bindings") end
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
    if not security.can(M.MANAGE, "bindings") then return fail("DENIED", "caller does not manage gateway bindings") end
    local db, open_failure = open()
    if not db then return open_failure end
    local generation, generation_failure = M.generation(db)
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
    if not db then return open_failure end
    local binding, missing = binding_named(db, object)
    if not binding then db:release(); return missing end
    if not security.can(M.MATERIALIZE, binding.attempt_id) and not security.can(M.ADMIT, binding.action_id) and not security.can(M.MANAGE, "bindings") then
        db:release()
        return fail("DENIED", "caller may not check this binding")
    end
    local generation, generation_failure = M.generation(db)
    db:release()
    if not generation then return assert(generation_failure) end
    local ok, reason = M.valid(binding, generation)
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
    local configured, _, config_error = surface.prepare(raw, mcp.TOOLS, binding.tools)
    if not configured then return nil, fail("STORAGE", config_error or "binding surface is invalid") end
    local extensions: {[string]: boolean} = {}
    for index, trait in ipairs(configured.catalog.traits) do
        if agent_trait.extension(trait) then
            extensions[trait.id] = true
            local live = trait_access.load(trait.id)
            if live then configured.catalog.traits[index] = live end
        end
    end
    local binding_traits: {string} = {}
    for _, id in ipairs(saved) do binding_traits[#binding_traits + 1] = id end
    for _, id in ipairs(granted) do if not extensions[id] and not bounds.member(id, binding_traits) then binding_traits[#binding_traits + 1] = id end end
    if #binding_traits > 0 then
        local extended, extend_error = surface.grant(configured, binding_traits)
        if not extended then return nil, fail("STORAGE", extend_error or "invalid grant") end
        configured = extended
    end
    local session_db, session_failure = open()
    if not session_db then return nil, session_failure end
    local session_tx, session_error = session_db:begin()
    if not session_tx then session_db:release(); return nil, fail("STORAGE", tostring(session_error)) end
    local session_allowed, session_active, trait_error = session_traits.selection(session_tx, binding.action_id, binding.thread_id, binding.workspace_id or "", configured.catalog.traits)
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
    local trait_error = session_traits.select(tx, binding.action_id, binding.thread_id, binding.workspace_id or "", current.configuration.catalog.traits, selected.active)
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
-- Capability elevation and installation requests run as the bound subject:
-- the binding row is rechecked on every call, and only the bound subject may
-- act for its own attempt. Elevation takes its approval policy from the
-- binding's own surface access; installation from the host configuration.
local function own_binding(value: unknown): (Binding?, Reply?)
    local object = bounds.object(value)
    if not object then return nil, fail("INVALID", "request must be an object") end
    local binding_id = bounds.id(object.binding_id)
    if not binding_id then return nil, fail("INVALID", "binding_id is not an identifier") end
    local caller = actor()
    if not caller then return nil, fail("UNAUTHENTICATED", "no actor") end
    local db, open_failure = open()
    if not db then return nil, open_failure end
    local binding, missing = binding_by_id(db, binding_id)
    db:release()
    if not binding then return nil, missing end
    if binding.subject ~= caller then return nil, fail("DENIED", "only the bound subject acts for its own attempt") end
    if binding.revoked then return nil, fail("DENIED", "binding is revoked") end
    local expires = time.parse(FORMAT, binding.expires_at)
    if not expires or not time.now():before(expires) then return nil, fail("DENIED", "binding has expired") end
    return binding, nil
end
local function elevation_policy(binding: Binding): (string?, Reply?)
    local current, failure = M.surface(binding)
    if not current then return nil, failure or fail("STORAGE", "read surface") end
    local access = current.configuration.access
    if not access then return nil, fail("DENIED", "this agent has no elevation approval policy") end
    return access.policy, nil
end
function M.request_capability(value: unknown): Reply
    local binding, refusal = own_binding(value)
    if not binding then return refusal or fail("UNAVAILABLE", "binding is unavailable") end
    local policy_name, policy_refusal = elevation_policy(binding)
    if not policy_name then return policy_refusal end
    local object = bounds.object(value) or {}
    return elevation.request(binding, policy_name, {capability = object.capability, parameters = object.parameters, ttl_ms = object.ttl_ms})
end
function M.capability_status(value: unknown): Reply
    local binding, refusal = own_binding(value)
    if not binding then return refusal or fail("UNAVAILABLE", "binding is unavailable") end
    local policy_name, policy_refusal = elevation_policy(binding)
    if not policy_name then return policy_refusal end
    local object = bounds.object(value) or {}
    return elevation.status(binding, policy_name, object.approval_id)
end
-- A tool exercises only the approved capability this attempt holds; the
-- held approval is checked again on every call.
local function held(value: unknown, tool: string): (Binding?, elevation.Held?, Reply?)
    local binding, refusal = own_binding(value)
    if not binding then return nil, nil, refusal or fail("UNAVAILABLE", "binding is unavailable") end
    local policy_name, policy_refusal = elevation_policy(binding)
    if not policy_name then return nil, nil, policy_refusal end
    local object = bounds.object(value) or {}
    local request, held_refusal = elevation.held(binding, policy_name, object.approval_id, tool)
    if not request then return nil, nil, held_refusal end
    return binding, request, nil
end
function M.process_run(value: unknown): Reply
    local binding, request, refusal = held(value, "process_run")
    if not binding or not request then return refusal or fail("DENIED", "no held capability runs a process") end
    return capability_use.process(binding, request, value)
end
function M.http_request(value: unknown): Reply
    local binding, request, refusal = held(value, "http_request")
    if not binding or not request then return refusal or fail("DENIED", "no held capability sends HTTP requests") end
    return capability_use.http(request, value)
end
local function installation_call(value: unknown, fields: {string}): (Binding?, string?, unknown?, Reply?)
    local binding, refusal = own_binding(value)
    if not binding then return nil, nil, nil, refusal end
    local policy_name, policy_refusal = installation.approval_policy()
    if not policy_name then return nil, nil, nil, policy_refusal end
    local object = bounds.object(value) or {}
    local request: {[string]: unknown} = {}
    for _, name in ipairs(fields) do request[name] = object[name] end
    return binding, policy_name, request, nil
end
function M.install_request(value: unknown): Reply
    local binding, policy_name, request, refusal = installation_call(value, {"component", "version", "parameters"})
    if not binding or not policy_name then return assert(refusal) end
    return installation.request(installation.port(binding), binding, policy_name, "install", request)
end
function M.uninstall_request(value: unknown): Reply
    local binding, policy_name, request, refusal = installation_call(value, {"component"})
    if not binding or not policy_name then return assert(refusal) end
    return installation.request(installation.port(binding), binding, policy_name, "uninstall", request)
end
function M.install_status(value: unknown): Reply
    local binding, policy_name, request, refusal = installation_call(value, {"request_id"})
    if not binding or not policy_name then return assert(refusal) end
    return installation.status(installation.port(binding), binding, policy_name, request)
end
-- The bound-subject door for the sibling publication tool surface: those
-- tools live in their own module (this one is at the checker's inference
-- budget) and resolve their caller through this shared door.
function M.own_binding(value: unknown): (Binding?, Reply?)
    return own_binding(value)
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
    local generation, generation_failure = M.generation(db)
    if not generation then db:release(); return nil, generation_failure end
    if credential_generation ~= binding.credential_generation then db:release(); return nil, fail("UNAUTHENTICATED", "token belongs to a superseded credential generation") end
    if binding.action_id ~= action_id then db:release(); return nil, fail("DENIED", "token is bound to another action") end
    local ok, reason = M.valid(binding, generation)
    if not ok then db:release(); return nil, fail("UNAUTHENTICATED", reason) end
    -- An accepted presentation is counted; the count is what proves a
    -- client authenticated without any bytes in evidence.
    local _, count_error = credential_store.presented(db, credential_id, stamp(now_ms()))
    db:release()
    if count_error then return nil, fail("STORAGE", "count presentation") end
    return binding, nil
end
M.READ_WORKSPACE = "bee.node.workspace.read"
M.MAX_DESCRIBED = 50
local function directory(value: unknown, fields: {string}): ({Object}?, Object?, Reply?)
    local request = bounds.object(value)
    if not request or bounds.fields(request, fields) then return nil, nil, fail("INVALID", "invalid workspace directory request") end
    local workspace = bounds.id(request.workspace_id)
    if not workspace or #workspace ~= 32 or workspace:find("[^0-9a-f]") then return nil, nil, fail("INVALID", "canonical workspace_id required") end
    local caller = security.actor()
    if not caller or not security.can(M.READ_WORKSPACE, workspace) then return nil, nil, fail("DENIED", "caller may not read this workspace") end
    local attributed, actor_error = security.new_actor(caller:id(), {workspace_id = workspace})
    if not attributed then return nil, nil, fail("DENIED", tostring(actor_error)) end
    local definition, contract_error = contract.get("bee.threads.sessions:contract")
    if not definition then return nil, nil, fail("UNAVAILABLE", tostring(contract_error)) end
    local acted, acting_error = definition:with_actor(attributed)
    if not acted then return nil, nil, fail("DENIED", tostring(acting_error)) end
    local owner, open_error = acted:open()
    if not owner then return nil, nil, fail("UNAVAILABLE", tostring(open_error)) end
    local rows: {Object} = {}
    local cursor: string? = nil
    local seen: {[string]: boolean} = {}
    for _ = 1, 64 do
        local reply_raw, call_error = owner:list({filter = {workspace = workspace}, cursor = cursor})
        local reply = bounds.object(reply_raw)
        if call_error or not reply or reply.ok ~= true then return nil, nil, fail("UNAVAILABLE", tostring(call_error or "Sessions directory unavailable")) end
        local items, decode_error = sessions.project(reply.value, workspace)
        if not items then return nil, nil, fail("UNAVAILABLE", decode_error or "invalid Sessions directory") end
        for _, item in ipairs(items) do rows[#rows + 1] = item end
        local page = bounds.object(reply.value)
        cursor = page and bounds.id(page.next)
        if not cursor then return rows, request, nil end
        if seen[cursor] then return nil, nil, fail("UNAVAILABLE", "Sessions directory repeated its cursor") end
        seen[cursor] = true
    end
    return nil, nil, fail("UNAVAILABLE", "Sessions directory exceeds the workspace projection bound")
end
function M.describe(value: unknown): Reply
    local listed, _, refused = directory(value, {"workspace_id"})
    if not listed then return assert(refused) end
    local items: {Object} = {}
    for index = 1, math.min(#listed, M.MAX_DESCRIBED) do items[index] = listed[index] end
    return succeed({title = "Agent sessions", items = items, total = #listed})
end
function M.search(value: unknown): Reply
    local listed, request, refused = directory(value, {"workspace_id", "text", "limit"})
    if not listed or not request then return assert(refused) end
    local wanted = bounds.line(request.text, 240)
    if not wanted then return fail("INVALID", "text must be one nonempty line") end
    local limit = request.limit == nil and M.MAX_DESCRIBED or bounds.integer(request.limit)
    if not limit or limit < 1 or limit > M.MAX_DESCRIBED then return fail("INVALID", "limit must be between 1 and 50") end
    local hits: {Object} = {}
    for _, item in ipairs(listed) do
        if #hits >= limit then break end
        if tostring(item.label):lower():find(wanted:lower(), 1, true) or tostring(item.session):sub(1, #wanted) == wanted then hits[#hits + 1] = item end
    end
    return succeed({title = "Agent sessions", hits = hits})
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
    if not db then return open_failure end
    -- The seal check, the replay check, the bound and the insert are one
    -- transaction, so no submission is accepted after the seal's point.
    local tx, begin_error = db:begin()
    if not tx then db:release(); return fail("STORAGE", "begin intake") end
    local function done(reply: Reply): Reply
        tx:rollback()
        db:release()
        return reply
    end
    local state, state_error = binding_store.intake_state(tx, binding.binding_id)
    if state_error or not state or #state ~= 1 then return done(fail("STORAGE", "read binding")) end
    local current = bounds.object(state[1])
    local revoked_at, valid_revoked_at = optional_timestamp(current and current.revoked_at)
    local sealed_at, valid_sealed_at = optional_timestamp(current and current.sealed_at)
    if not current or not valid_revoked_at or not valid_sealed_at then return done(fail("STORAGE", "binding intake state is corrupt")) end
    if not submission.ambiguous then
        local existing, existing_error = hook_store.existing_occurrence(tx, binding.binding_id, event, submission.occurrence)
        if existing_error or not existing then return done(fail("STORAGE", "read hooks")) end
        if #existing > 1 then return done(fail("STORAGE", "hook occurrence is duplicated")) end
        if #existing == 1 then
            local stored = bounds.object(existing[1])
            local stored_digest = stored and bounds.text(stored.digest, 64)
            local stored_id = stored and bounds.id(stored.event_id)
            local stored_status = stored and bounds.text(stored.status, 16)
            local rejected_reason, reason_valid = optional_text(stored and stored.rejected_reason, 120)
            if not stored or not stored_digest or #stored_digest ~= 64 or not stored_digest:match("^[0-9a-f]+$") or not stored_id
                or (stored_status ~= "queued" and stored_status ~= "committed" and stored_status ~= "rejected") or not reason_valid then
                return done(fail("STORAGE", "hook occurrence row is corrupt"))
            end
            if stored_digest ~= submission.digest then return done(fail("CONFLICT", "occurrence " .. submission.occurrence .. " of " .. event .. " was already submitted with different content")) end
            return done(succeed({event = event, event_id = stored_id, status = stored_status, replayed = true, ambiguous = false, rejected_reason = rejected_reason}))
        end
    end
    if revoked_at ~= nil then return done(fail("DENIED", "intake is closed: binding revoked")) end
    if sealed_at ~= nil then return done(fail("DENIED", "intake is sealed: the attempt's child has ended")) end
    local queued, count_error = hook_store.queued_count(tx, binding.binding_id)
    if count_error or not queued or #queued ~= 1 then return done(fail("STORAGE", "count hooks")) end
    local queued_row = bounds.object(queued[1])
    local queued_count = queued_row and bounds.count(queued_row.queued)
    if queued_count == nil then return done(fail("STORAGE", "queued hook count is corrupt")) end
    if queued_count >= hooks.MAX_QUEUE then
        return done(fail("OVERLOAD", "the binding holds " .. tostring(hooks.MAX_QUEUE) .. " queued hooks; retry after " .. tostring(hooks.RETRY_AFTER_MS) .. " ms"))
    end
    local sequence_rows, sequence_error = hook_store.last_sequence(tx, binding.binding_id)
    if sequence_error or not sequence_rows or #sequence_rows ~= 1 then return done(fail("STORAGE", "sequence hooks")) end
    local sequence_row = bounds.object(sequence_rows[1])
    local last_sequence = (sequence_row and bounds.count(sequence_row.last)) or -1
    if last_sequence < 0 or last_sequence >= 9007199254740991 then return done(fail("STORAGE", "hook sequence is corrupt")) end
    local sequence = last_sequence + 1
    local event_id, id_error = uuid.v7()
    if id_error or not event_id then return done(fail("STORAGE", "event id")) end
    local at = stamp(now_ms())
    local fields_json, fields_error = json.encode(submission.fields)
    if fields_error or not fields_json then return done(fail("STORAGE", "encode hook fields")) end
    local _, insert_error = hook_store.insert(tx, event_id, binding.binding_id, binding.attempt_id, binding.action_id, binding.carrier_epoch,
        event, submission.occurrence, submission.ambiguous and 1 or 0, submission.digest, fields_json, provenance, sequence, at)
    if insert_error then return done(fail("STORAGE", "queue hook")) end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then return fail("STORAGE", "commit intake") end
    return succeed({event = event, event_id = event_id, status = "queued", replayed = false, ambiguous = submission.ambiguous})
end
-- hook_status: what became of one submission; unknown when nothing under
-- that id exists for the binding, which after a loss permits a replay.
function M.hook_status(binding: Binding, event_id: string): Reply
    local db, open_failure = open()
    if not db then return open_failure end
    local rows, err = hook_store.status(db, event_id, binding.binding_id)
    db:release()
    if err or not rows then return fail("STORAGE", "read hook") end
    if #rows == 0 then return succeed({event_id = event_id, status = "unknown"}) end
    local status, decode_error = hook_status(rows[1])
    if not status then return fail("STORAGE", decode_error or "hook status is corrupt") end
    return succeed({event_id = event_id, status = status.status, event = status.event, occurrence = status.occurrence,
        ambiguous = status.ambiguous, sequence = status.sequence, claimed_epoch = status.claimed_epoch, rejected_reason = status.rejected_reason})
end
-- hook_queue: the queued and committed submissions of a binding in order,
-- for the carrier that will commit them and for proofs. Fields only.
function M.hook_queue(binding: Binding): Reply
    local db, open_failure = open()
    if not db then return open_failure end
    local rows, err = hook_store.queue(db, binding.binding_id)
    db:release()
    if err or not rows then return fail("STORAGE", "read hooks") end
    local list: {HookQueueItem} = {}
    for index, row in ipairs(rows) do
        local base, base_error = hook_record(row)
        local stored = bounds.object(row)
        local status = stored and bounds.text(stored.status, 16)
        local claimed_epoch = stored and bounds.count(stored.claimed_epoch)
        local rejected_reason, reason_valid = optional_text(stored and stored.rejected_reason, 120)
        if not base or not stored or (status ~= "queued" and status ~= "committed" and status ~= "rejected")
            or claimed_epoch == nil or not reason_valid then
            return fail("STORAGE", base_error or "hook queue row is corrupt")
        end
        list[index] = {event_id = base.event_id, event = base.event, occurrence = base.occurrence, ambiguous = base.ambiguous,
            digest = base.digest, fields = base.fields, provenance = base.provenance, status = status, sequence = base.sequence,
            created_at = base.created_at, claimed_epoch = claimed_epoch, rejected_reason = rejected_reason}
    end
    return succeed({hooks = list})
end
-- The binding admission and every hook mutation serialize this comparison in
-- one gateway-store transaction. The thread carrier epoch still fences the
-- record commit; this only prevents a preflight read from letting an old
-- gateway claim or acknowledgment race a later admission.
local function intake_epoch(tx: sql.Transaction, attempt_id: string, carrier_epoch: integer): Reply?
    local rows, err = binding_store.intake_carrier_epoch(tx, attempt_id)
    if err or not rows or #rows ~= 1 then return fail("STORAGE", "read bindings") end
    local row = bounds.object(rows[1])
    local highest = row and bounds.count(row.highest)
    if highest == nil or highest == 0 then return fail("STORAGE", "binding carrier epoch is corrupt") end
    if carrier_epoch < highest then
        return fail("CONFLICT", "carrier epoch " .. tostring(carrier_epoch) .. " is below the highest epoch " .. tostring(highest) .. " admitted for attempt " .. attempt_id)
    end
    return nil
end
local function intake_binding(tx: sql.Transaction, binding_id: string): (Binding?, Reply?)
    local rows, err = binding_store.intake_binding(tx, binding_id)
    if err or not rows then return nil, fail("STORAGE", "read binding") end
    if #rows == 0 then return nil, fail("NOT_FOUND", "binding does not exist") end
    local binding, decode_error = binding_of(rows[1])
    if not binding then return nil, fail("STORAGE", decode_error or "binding is corrupt") end
    return binding, nil
end
local function intake_generation(tx: sql.Transaction): (Generation?, Reply?)
    local rows, err = listener_store.epoch(tx)
    if err or not rows then return nil, fail("STORAGE", "read listener") end
    if #rows == 0 then return nil, fail("UNAVAILABLE", "the gateway listener has not been opened") end
    if #rows ~= 1 then return nil, fail("STORAGE", "listener row is duplicated") end
    local count, count_error = restarts()
    if not count then return nil, fail("UNAVAILABLE", count_error or "listener restarts unknown") end
    local row = bounds.object(rows[1])
    local epoch = row and bounds.count(row.epoch)
    if not epoch or epoch == 0 then return nil, fail("STORAGE", "listener epoch is corrupt") end
    return {epoch = epoch, restarts = count}, nil
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
    if not object or not binding or not db or not carrier_epoch then return assert(refusal) end
    local limit = M.MAX_HOOK_CLAIM
    if object.limit ~= nil then
        local declared = bounds.integer(object.limit)
        if not declared or declared < 1 or declared > M.MAX_HOOK_CLAIM then db:release(); return fail("INVALID", "limit must be between 1 and " .. tostring(M.MAX_HOOK_CLAIM)) end
        limit = declared
    end
    local tx, begin_error = db:begin()
    if not tx then db:release(); return fail("STORAGE", "begin hook claim") end
    local current_binding, binding_failure = intake_binding(tx, binding.binding_id)
    if not current_binding then tx:rollback(); db:release(); return binding_failure end
    local generation, generation_failure = intake_generation(tx)
    if not generation then tx:rollback(); db:release(); return generation_failure end
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
        local _, reject_error = hook_store.reject_unclaimed_for_binding(tx, current_binding.binding_id, reason, at)
        if reject_error then tx:rollback(); db:release(); return fail("STORAGE", "reject unclaimed hooks") end
        recovery_only = true
    end
    local rows, err = hook_store.queued_ids(tx, current_binding.binding_id, carrier_epoch, recovery_only, limit)
    if err or not rows then tx:rollback(); db:release(); return fail("STORAGE", "read queued hooks") end
    local claimed: {HookRecord} = {}
    for _, row in ipairs(rows) do
        local event_id = bounds.id((row).event_id)
        if not event_id then tx:rollback(); db:release(); return fail("STORAGE", "queued hook identity is corrupt") end
        local result, claim_error = hook_store.claim(tx, event_id, carrier_epoch, at)
        if claim_error then tx:rollback(); db:release(); return fail("STORAGE", "claim hook") end
        local affected = result and bounds.count(result.rows_affected)
        if affected == nil or affected > 1 then tx:rollback(); db:release(); return fail("STORAGE", "hook claim result is corrupt") end
        if affected == 1 then
            local detail, detail_error = hook_store.claimed_row(tx, event_id)
            if detail_error or not detail or #detail ~= 1 then tx:rollback(); db:release(); return fail("STORAGE", "read claimed hook") end
            local item, item_error = hook_record(detail[1])
            if not item or item.event_id ~= event_id then
                tx:rollback(); db:release(); return fail("STORAGE", item_error or "claimed hook identity is corrupt")
            end
            claimed[#claimed + 1] = item
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
    local rows, err = hook_store.retained(db, binding_id)
    if err or not rows then return "read retained hooks" end
    local kept = 0
    local bytes = 0
    for _, row in ipairs(rows) do
        kept = kept + 1
        local stored = bounds.object(row)
        local stored_bytes = stored and bounds.count(stored.bytes)
        if stored_bytes == nil then return "retained hook byte count is corrupt" end
        bytes = bytes + stored_bytes
        if kept > M.MAX_RETAINED_HOOKS or bytes > M.MAX_RETAINED_HOOK_BYTES then
            local event_id = stored and bounds.id(stored.event_id)
            if not event_id then return "retained hook identity is corrupt" end
            local _, delete_error = hook_store.delete(db, event_id)
            if delete_error then return "prune retained hooks" end
        end
    end
    return nil
end
-- hook_ack: the carrier reports that the named claimed submissions are
-- thread records; only the epoch that claimed them may say so.
function M.hook_ack(value: unknown): Reply
    local object, binding, db, carrier_epoch, refusal = intake_request(value, {"event_ids"})
    if not object or not binding or not db or not carrier_epoch then return assert(refusal) end
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
        local result, ack_error = hook_store.acknowledge(tx, at, event_id, binding.binding_id, carrier_epoch)
        if ack_error then tx:rollback(); db:release(); return fail("STORAGE", "acknowledge hook") end
        local affected = result and bounds.count(result.rows_affected)
        if affected == nil or affected > 1 then tx:rollback(); db:release(); return fail("STORAGE", "hook acknowledgment result is corrupt") end
        if affected == 1 then acknowledged = acknowledged + 1 end
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
    if not object or not binding or not db or not carrier_epoch then return assert(refusal) end
    local reason = bounds.line(object.reason, 120)
    if not reason or reason == "" then db:release(); return fail("INVALID", "reason is required") end
    local tx, begin_error = db:begin()
    if not tx then db:release(); return fail("STORAGE", "begin hook rejection") end
    local epoch_refusal = intake_epoch(tx, binding.attempt_id, carrier_epoch)
    if epoch_refusal then tx:rollback(); db:release(); return epoch_refusal end
    local result, reject_error = hook_store.reject_binding(tx, stamp(now_ms()), reason, binding.binding_id)
    if reject_error then tx:rollback(); db:release(); return fail("STORAGE", "reject queued hooks") end
    local rejected = result and bounds.count(result.rows_affected)
    if rejected == nil then tx:rollback(); db:release(); return fail("STORAGE", "hook rejection result is corrupt") end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then return fail("STORAGE", "commit hook rejection") end
    return succeed({binding_id = binding.binding_id, rejected = rejected})
end


function M.managed_binding(binding_id: string): (Binding?, Reply?)
    if not actor() or not security.can(M.MANAGE, "bindings") then return nil, fail("DENIED", "caller does not manage bindings") end
    local db, failure = open()
    if not db then return nil, failure end
    local binding, missing = binding_by_id(db, binding_id)
    db:release()
    return binding, missing
end
function M.admit_call(binding: Binding, name: string): Reply
    local db, failure = open()
    if not db then return failure or fail("STORAGE","open call authority") end
    local tx, err = db:begin({isolation = sql.isolation.SERIALIZABLE})
    if not tx then db:release(); return fail("STORAGE","begin call admission") end
    local rows = binding_store.surface_authority(tx,binding.binding_id)
    local row = rows and #rows == 1 and bounds.object(rows[1]) or nil
    local now = now_ms()
    if not row or row.revoked_at ~= nil or row.sealed_at ~= nil or row.credential_generation ~= binding.credential_generation or type(row.expires_at) ~= "string" or row.expires_at <= stamp(now) then tx:rollback(); db:release(); return fail("DENIED","binding no longer admits calls") end
    local stored, stored_error = surface_store.read(tx,binding.binding_id)
    local declaration = stored and bounds.object(json.decode(stored.surface_json))
    if not declaration then tx:rollback(); db:release(); return fail("STORAGE",stored_error and stored_error.message or "invalid call surface") end
    local id, authority_error = surface_store.call_authority(tx,binding.binding_id,binding.workspace_id,declaration,name,now)
    if authority_error then tx:rollback(); db:release(); return fail("DENIED",authority_error.message) end
    if id then
        local grant, read_error = grant_store.read(tx,id)
        if not grant or read_error or grant.workspace_id ~= (binding.workspace_id or "legacy:unscoped") or grant_store.state(grant,now) ~= "active" then tx:rollback(); db:release(); return fail("DENIED","consent grant no longer admits calls") end
        local effect = assert(uuid.v7())
        local digest = assert(hash.sha256(assert(canonical.encode({binding_id = binding.binding_id,tool = name}))))
        local reserved, reserve_error = grant_store.use(tx,grant,"reserve",effect,digest,grant.revision,binding.subject,now)
        if reserved == nil then tx:rollback(); db:release(); return fail("DENIED",reserve_error or "call reservation denied") end
        local admitted, admission_error = grant_store.use(tx,grant,"admit",effect,digest,grant.revision,binding.subject,now)
        if admitted == nil then tx:rollback(); db:release(); return fail("DENIED",admission_error or "call admission denied") end
    end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then return fail("STORAGE","commit call admission") end
    return succeed({grant_id = id})
end
function M.record_external_call(binding: Binding, name: string): Reply
    local db, failure = open()
    if not db then return failure or fail("STORAGE", "open external clients") end
    local rows, err = external_store.by_binding(db, binding.binding_id)
    db:release()
    if not rows or err then return fail("STORAGE", "read external client") end
    if #rows == 0 then return succeed({}) end
    local reference_id = mcp.TOOL_POLICY_REFS.message
    local policy, policy_error = subject_call.linked(reference_id, "thread record policy")
    if not policy then return policy_error or fail("UNAVAILABLE", "thread record policy is unavailable") end
    local id, id_error = uuid.v7()
    if not id then return fail("STORAGE", tostring(id_error)) end
    return subject_call.call(binding, {policy}, "bee.threads.binding:record", {thread_id = binding.thread_id,
        idempotency_key = id, kind = "message", body = {message_id = id, message_kind = "progress", recipient_ids = {}, content = {text = "MCP tool: " .. name}}})
end
return M
