-- MIT. Native gateway admission uses the host-selected listener identity:
-- admission can initialize an unopened port-zero listener only when the
-- caller is admitted, repeated work on the same execution keeps the stored
-- generation and drain state, and explicit open records that identity too.
local test = require("test")
local registry = require("registry")
local funcs = require("funcs")
local security = require("security")
local sql = require("sql")
local json = require("json")
local time = require("time")
local configuration = require("configuration")

local ENDPOINT = "bee:gateway_endpoint"
local LISTENER_REF = "bee.gateway:listener_ref"
local DATABASE_REF = "bee.gateway:database_ref"
local DATABASE = "bee.gateway:native_admission_db"
local LISTENER = "bee.gateway:ephemeral_listener"
local ACTOR = "bee.test.native_gateway_admission"

type Object = {[string]: unknown}
type RegistryState = {endpoint: Object, listener: Object, database: Object}
type Reply = {ok: boolean, error: Object?, value: unknown}

local function clone(value: unknown): Object
    local encoded, encode_error = json.encode(value)
    if not encoded then error(tostring(encode_error or "encode registry value")) end
    local decoded, decode_error = json.decode(encoded)
    if type(decoded) ~= "table" then error(tostring(decode_error or "decode registry value")) end
    return decoded :: Object
end

local function entry(id: string): Object
    local found, err = registry.get(id)
    if err or not found then error(id .. ": " .. tostring(err or "missing")) end
    return found :: Object
end

local function state(): RegistryState
    return {endpoint = clone((entry(ENDPOINT).data :: Object)), listener = clone((entry(LISTENER_REF).data :: Object)), database = clone((entry(DATABASE_REF).data :: Object))}
end

local function apply(entries: {Object})
    local changes = registry.snapshot():changes()
    for _, value in ipairs(entries) do changes:update(value) end
    local applied, err = changes:apply()
    if not applied then error("registry update: " .. tostring(err)) end
end

local function configure()
    local endpoint = entry(ENDPOINT)
    endpoint.data = {address = "127.0.0.1:0"}
    local listener = entry(LISTENER_REF)
    listener.data = {resource_ref = LISTENER}
    local database = entry(DATABASE_REF)
    database.data = {resource_ref = DATABASE}
    apply({endpoint, listener, database})
end

local function restore(saved: RegistryState)
    local endpoint = entry(ENDPOINT)
    endpoint.data = clone(saved.endpoint)
    local listener = entry(LISTENER_REF)
    listener.data = clone(saved.listener)
    local database = entry(DATABASE_REF)
    database.data = clone(saved.database)
    apply({endpoint, listener, database})
end

local function policy(name: string): security.Policy
    local found, err = security.policy(name)
    if err or not found then error("policy " .. name .. ": " .. tostring(err)) end
    return found
end

local function caller(admit: boolean, manage: boolean): funcs.Executor
    local policies: {security.Policy} = {policy("bee.gateway:native_admission_test_policy")}
    if admit then policies[#policies + 1] = policy("bee:gateway_admit_policy") end
    if manage then policies[#policies + 1] = policy("bee:gateway_manage_policy") end
    return funcs.new():with_actor(security.new_actor(ACTOR)):with_scope(security.new_scope(policies))
end

local function raw_call(client: funcs.Executor, target: string, request: unknown): Reply
    local result, err = client:call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return result :: Reply
end

local function row(db: sql.DB): Object
    local rows, err = db:query("SELECT epoch, address, secret, drained, native_key FROM bee_gateway_listener WHERE singleton = 1")
    if err or not rows or #rows ~= 1 then error("listener row: " .. tostring(err or (rows and #rows) or 0)) end
    return rows[1] :: Object
end

local function listener_count(db: sql.DB): integer
    local tables, table_error = db:query("SELECT COUNT(*) AS count FROM sqlite_master WHERE type = 'table' AND name = 'bee_gateway_listener'")
    if table_error or not tables or #tables ~= 1 then error("listener schema: " .. tostring(table_error)) end
    if math.floor(tonumber((tables[1] :: Object).count) or 0) == 0 then return 0 end
    local rows, err = db:query("SELECT COUNT(*) AS count FROM bee_gateway_listener")
    if err or not rows or #rows ~= 1 then error("listener count: " .. tostring(err)) end
    return math.floor(tonumber((rows[1] :: Object).count) or 0)
end

local function database(): sql.DB
    local db, err = sql.get(DATABASE)
    if not db then error("native admission database: " .. tostring(err)) end
    return db
end

local function wait_for_listener(): configuration.Listener
    for _ = 1, 100 do
        local selected = configuration.current()
        if selected then return selected end
        time.sleep("50ms")
    end
    local selected, err = configuration.current()
    if not selected then error("ephemeral listener did not become ready: " .. tostring(err)) end
    return selected
end

local function admit_request(suffix: string): Object
    return {subject = ACTOR, action_id = "native-action-" .. suffix, attempt_id = "native-attempt-" .. suffix,
        thread_id = "native-thread-" .. suffix, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}}
end

local function define_tests()
    test.describe("Native gateway admission", function()
        test.it("initializes only through authorized admission and fences same-execution state", function()
            local saved = state()
            local ok, failure = pcall(function()
                configure()
                local db = database()
                test.eq(listener_count(db), 0)

                local denied = raw_call(caller(false, false), "bee.gateway:admit", admit_request("unauthorized"))
                test.is_false(denied.ok)
                test.eq((denied.error :: Object).code, "DENIED")
                test.eq(listener_count(db), 0)

                local selected = wait_for_listener()
                local admitted = raw_call(caller(true, false), "bee.gateway:admit", admit_request("authorized"))
                if not admitted.ok then error("authorized admission: " .. tostring(admitted.error and (admitted.error :: Object).message)) end
                local first = row(db)
                test.eq(first.epoch, 1)
                test.eq(first.address, selected.address)
                test.is_true(type(first.secret) == "string" and #(first.secret :: string) > 0)
                test.is_true(type(first.native_key) == "string" and #(first.native_key :: string) > 0)
                test.eq(first.native_key, selected.native_key)
                test.eq(first.drained, 0)

                local hook_request = admit_request("hooks-only")
                hook_request.tools = {}
                hook_request.hooks = {"SessionStart"}
                local hook_admitted = raw_call(caller(true, false), "bee.gateway:admit", hook_request)
                if not hook_admitted.ok then error("hook-only admission: " .. tostring(hook_admitted.error and hook_admitted.error.message)) end
                local stored_hooks, stored_error = db:query("SELECT tools_json, hooks_json FROM bee_gateway_bindings WHERE action_id = ?", {"native-action-hooks-only"})
                if not stored_hooks or stored_error or #stored_hooks ~= 1 then error("missing hook-only binding") end
                local binding = stored_hooks[1] :: Object
                local tool_names = json.decode(tostring(binding.tools_json))
                local hook_names = json.decode(tostring(binding.hooks_json))
                if type(tool_names) ~= "table" or type(hook_names) ~= "table" then error("invalid stored gateway catalog") end
                test.eq(#tool_names, 0)
                test.eq(hook_names[1], "SessionStart")
                local empty_request = admit_request("empty")
                empty_request.tools = {}
                local empty = raw_call(caller(true, false), "bee.gateway:admit", empty_request)
                test.eq(empty.error and empty.error.code, "INVALID")

                local replay_request = admit_request("origin-replay")
                replay_request.idempotency_key = "origin-replay-key"
                replay_request.origin_view = {view_id = "view-origin", instance_id = "instance-origin"}
                local first_origin = raw_call(caller(true, false), "bee.gateway:admit", replay_request)
                if not first_origin.ok then error("origin admission: " .. tostring(first_origin.error and first_origin.error.message)) end
                local first_binding = (first_origin.value :: Object).binding :: Object
                test.eq(((first_binding.origin_view :: Object).view_id), "view-origin")
                local stored_origin, stored_origin_error = db:query("SELECT origin_view_json FROM bee_gateway_bindings WHERE binding_id = ?", {first_binding.binding_id})
                if stored_origin_error or not stored_origin or #stored_origin ~= 1 then error("missing stored origin view") end
                local stored_view = json.decode(tostring((stored_origin[1] :: Object).origin_view_json))
                test.eq((stored_view :: Object).instance_id, "instance-origin")
                local replayed_origin = raw_call(caller(true, false), "bee.gateway:admit", replay_request)
                if not replayed_origin.ok then error("origin replay: " .. tostring(replayed_origin.error and replayed_origin.error.message)) end
                test.is_true((replayed_origin.value :: Object).replayed == true)
                local replayed_binding = (replayed_origin.value :: Object).binding :: Object
                test.eq(((replayed_binding.origin_view :: Object).view_id), "view-origin")
                test.eq(((replayed_binding.origin_view :: Object).instance_id), "instance-origin")

                local before_epoch = first.epoch
                local before_secret = first.secret
                local before_key = first.native_key
                local _, drain_error = db:execute("UPDATE bee_gateway_listener SET drained = 1 WHERE singleton = 1")
                if drain_error then error("mark listener drained: " .. tostring(drain_error)) end
                local still_denied = raw_call(caller(true, false), "bee.gateway:admit", admit_request("same-execution"))
                test.is_false(still_denied.ok)
                test.eq((still_denied.error :: Object).code, "UNAVAILABLE")
                local preserved = row(db)
                test.eq(preserved.epoch, before_epoch)
                test.eq(preserved.secret, before_secret)
                test.eq(preserved.native_key, before_key)
                test.eq(preserved.drained, 1)

                local opened = raw_call(caller(false, true), "bee.gateway:open", {address = selected.address})
                if not opened.ok then error("explicit open: " .. tostring(opened.error and (opened.error :: Object).message)) end
                local reopened = row(db)
                test.eq(reopened.native_key, before_key)
                test.eq(reopened.epoch, 2)
                test.eq(reopened.drained, 0)
                test.is_true(reopened.secret ~= before_secret)
                db:release()
            end)
            local restored, restore_error = pcall(restore, saved)
            if not restored then error("restore registry: " .. tostring(restore_error)) end
            if not ok then error(tostring(failure)) end
        end)
    end)
end

return test.run_cases(define_tests)
