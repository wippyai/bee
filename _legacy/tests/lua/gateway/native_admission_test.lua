-- MIT. Native gateway admission uses the host-selected listener identity:
-- admission can initialize an unopened port-zero listener only when the
-- caller is admitted, repeated work on the same execution keeps the stored
-- generation and drain state, and explicit open records that identity too.
local test = require("test")
local app_caller = require("app_caller")
local bounds = require("bounds")
local registry = require("registry")
local funcs = require("funcs")
local security = require("security")
local sql = require("sql")
local json = require("json")
local time = require("time")
local configuration = require("configuration")
local protocol = require("protocol")

local ENDPOINT_REF = "bee.gateway.env:endpoint_ref"
local ENDPOINT = "bee.gateway:native_admission_endpoint"
local LISTENER_REF = "bee.gateway.env:listener_ref"
local DATABASE_REF = "bee.gateway.env:database_ref"
local DATABASE = "bee.gateway:native_admission_db"
local LISTENER = "bee.gateway:ephemeral_listener"
local ACTOR = "bee.test.native_gateway_admission"

type Object = {[string]: unknown}
type RegistryState = {endpoint_ref: Object, endpoint: Object, listener: Object, database: Object}
type Reply = {ok: boolean, error: Object?, value: unknown}


type RegistryInput = {id: string, kind: string, meta: {[string]: unknown}, data: unknown, dependency_root: boolean}
local function registry_input(value: {[string]: unknown}): RegistryInput
    local id, kind, meta, dependency_root = value.id, value.kind, value.meta, value.dependency_root
    assert(type(id) == "string" and type(kind) == "string", "fixture registry entry identity")
    local metadata: {[string]: unknown} = {}
    if meta ~= nil then
        assert(type(meta) == "table", "fixture registry metadata")
        for key, item in pairs(meta) do metadata[key] = item end
    end
    assert(dependency_root == nil or type(dependency_root) == "boolean", "fixture registry dependency root")
    return {id = id, kind = kind, meta = metadata, data = value.data, dependency_root = dependency_root == true}
end

local function clone(value: unknown): Object
    local encoded, encode_error = json.encode(value)
    if not encoded then error(tostring(encode_error or "encode registry value")) end
    local decoded, decode_error = json.decode(encoded)
    if type(decoded) ~= "table" then error(tostring(decode_error or "decode registry value")) end
    return assert(bounds.object(decoded))
end

local function entry(id: string): Object
    local found, err = registry.get(id)
    if err or not found then error(id .. ": " .. tostring(err or "missing")) end
    return assert(bounds.object(found))
end

local function state(): RegistryState
    return {
        endpoint_ref = clone((assert(bounds.object(entry(ENDPOINT_REF).data)))),
        endpoint = clone((assert(bounds.object(entry(ENDPOINT).data)))),
        listener = clone((assert(bounds.object(entry(LISTENER_REF).data)))),
        database = clone((assert(bounds.object(entry(DATABASE_REF).data)))),
    }
end

local function apply(entries: {Object})
    local changes = registry.snapshot():changes()
    for _, value in ipairs(entries) do changes:update(registry_input(value)) end
    local applied, err = changes:apply()
    if not applied then error("registry update: " .. tostring(err)) end
end

local function configure()
    local endpoint_ref = entry(ENDPOINT_REF)
    endpoint_ref.data = {resource_ref = ENDPOINT}
    local endpoint = entry(ENDPOINT)
    endpoint.data = {address = "127.0.0.1:0"}
    local listener = entry(LISTENER_REF)
    listener.data = {resource_ref = LISTENER}
    local database = entry(DATABASE_REF)
    database.data = {resource_ref = DATABASE}
    apply({endpoint_ref, endpoint, listener, database})
end

local function restore(saved: RegistryState)
    local endpoint_ref = entry(ENDPOINT_REF)
    endpoint_ref.data = clone(saved.endpoint_ref)
    local endpoint = entry(ENDPOINT)
    endpoint.data = clone(saved.endpoint)
    local listener = entry(LISTENER_REF)
    listener.data = clone(saved.listener)
    local database = entry(DATABASE_REF)
    database.data = clone(saved.database)
    apply({endpoint_ref, endpoint, listener, database})
end

local function policy(name: string): security.Policy
    local found, err = security.policy(name)
    if err or not found then error("policy " .. name .. ": " .. tostring(err)) end
    return found
end

local function caller(admit: boolean, manage: boolean, workspace_read: boolean?): funcs.Executor
    local policies: {security.Policy} = {policy("bee.gateway:native_admission_test_policy")}
    if admit then policies[#policies + 1] = policy("bee.security.gateway:gateway_admit_policy") end
    if manage then policies[#policies + 1] = policy("bee.security.gateway:gateway_manage_policy") end
    if workspace_read then policies[#policies + 1] = policy("bee.security.storage:workspace_catalog_read_policy") end
    return funcs.new():with_actor(security.new_actor(ACTOR)):with_scope(security.new_scope(policies))
end

local function raw_call(client: funcs.Executor, target: string, request: unknown): Reply
    local result, err = client:call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return assert(app_caller.decode(result))
end

local function row(db: sql.DB): Object
    local rows, err = db:query("SELECT epoch, address, secret, drained, native_key FROM bee_gateway_listener WHERE singleton = 1")
    if err or not rows or #rows ~= 1 then error("listener row: " .. tostring(err or (rows and #rows) or 0)) end
    return assert(bounds.object(rows[1]))
end

local function listener_count(db: sql.DB): integer
    local tables, table_error = db:query("SELECT COUNT(*) AS count FROM sqlite_master WHERE type = 'table' AND name = 'bee_gateway_listener'")
    if table_error or not tables or #tables ~= 1 then error("listener schema: " .. tostring(table_error)) end
    if math.floor(tonumber((assert(bounds.object(tables[1]))).count) or 0) == 0 then return 0 end
    local rows, err = db:query("SELECT COUNT(*) AS count FROM bee_gateway_listener")
    if err or not rows or #rows ~= 1 then error("listener count: " .. tostring(err)) end
    return math.floor(tonumber((assert(bounds.object(rows[1]))).count) or 0)
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

                local denied = raw_call(caller(false, false), "bee.gateway.binding:admit", admit_request("unauthorized"))
                test.is_false(denied.ok)
                test.eq((assert(bounds.object(denied.error))).code, "DENIED")
                test.eq(listener_count(db), 0)

                local selected = wait_for_listener()
                local admitted = raw_call(caller(true, false), "bee.gateway.binding:admit", admit_request("authorized"))
                if not admitted.ok then error("authorized admission: " .. tostring(admitted.error and (assert(bounds.object(admitted.error))).message)) end
                local session_request = admit_request("session-ref")
                local canonical_ref = "bs:" .. string.rep("n", 36) .. ":" .. string.rep("a", 32) .. ":" .. string.rep("s", 36)
                session_request.subject, session_request.action_id = canonical_ref, canonical_ref
                local long = raw_call(caller(true, false), "bee.gateway.binding:admit", session_request)
                if not long.ok then error("SessionRef admission refused") end
                local decoded, decode_error = protocol.admitted_binding(long.value)
                if not decoded then error(tostring(decode_error)) end
                test.eq(decoded.subject, canonical_ref)
                test.is_true(#decoded.workspace_name <= 80)
                local first_name = admit_request("named-one")
                first_name.workspace_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                first_name.workspace_name = "Builder"
                test.is_true(raw_call(caller(true, false), "bee.gateway.binding:admit", first_name).ok)
                local collision = admit_request("named-two")
                collision.workspace_id = first_name.workspace_id
                collision.workspace_name = "Builder"
                local refused_name = raw_call(caller(true, false), "bee.gateway.binding:admit", collision)
                test.is_false(refused_name.ok)
                test.eq((assert(bounds.object(refused_name.error))).code, "CONFLICT")
                local first = row(db)
                test.eq(first.epoch, 1)
                test.eq(first.address, selected.address)
                test.is_true(type(first.secret) == "string" and #(first.secret) > 0)
                test.is_true(type(first.native_key) == "string" and #(first.native_key) > 0)
                test.eq(first.native_key, selected.native_key)
                test.eq(first.drained, 0)

                local hook_request = admit_request("hooks-only")
                hook_request.tools = {}
                hook_request.hooks = {"SessionStart"}
                local hook_admitted = raw_call(caller(true, false), "bee.gateway.binding:admit", hook_request)
                if not hook_admitted.ok then error("hook-only admission: " .. tostring(hook_admitted.error and hook_admitted.error.message)) end
                local stored_hooks, stored_error = db:query("SELECT tools_json, hooks_json FROM bee_gateway_bindings WHERE action_id = ?", {"native-action-hooks-only"})
                if not stored_hooks or stored_error or #stored_hooks ~= 1 then error("missing hook-only binding") end
                local binding = assert(bounds.object(stored_hooks[1]))
                local tool_names = json.decode(tostring(binding.tools_json))
                local hook_names = json.decode(tostring(binding.hooks_json))
                if type(tool_names) ~= "table" or type(hook_names) ~= "table" then error("invalid stored gateway catalog") end
                test.eq(#tool_names, 0)
                test.eq(hook_names[1], "SessionStart")
                local empty_request = admit_request("empty")
                empty_request.tools = {}
                local empty = raw_call(caller(true, false), "bee.gateway.binding:admit", empty_request)
                test.eq(empty.error and empty.error.code, "INVALID")
                -- The bound fits every shipped launch policy and still
                -- refuses a binding beyond it.
                local oversized_request = admit_request("oversized-tools")
                local many_tools: {string} = {}
                for _ = 1, 33 do many_tools[#many_tools + 1] = "thread_read" end
                oversized_request.tools = many_tools
                local oversized = raw_call(caller(true, false), "bee.gateway.binding:admit", oversized_request)
                test.is_false(oversized.ok)
                test.eq((assert(bounds.object(oversized.error))).code, "INVALID")

                local replay_request = admit_request("origin-replay")
                replay_request.idempotency_key = "origin-replay-key"
                replay_request.origin_view = {view_id = "view-origin", instance_id = "instance-origin"}
                local first_origin = raw_call(caller(true, false), "bee.gateway.binding:admit", replay_request)
                if not first_origin.ok then error("origin admission: " .. tostring(first_origin.error and first_origin.error.message)) end
                local first_binding = assert(bounds.object((assert(bounds.object(first_origin.value))).binding))
                test.eq(((assert(bounds.object(first_binding.origin_view))).view_id), "view-origin")
                local stored_origin, stored_origin_error = db:query("SELECT origin_view_json FROM bee_gateway_bindings WHERE binding_id = ?", {first_binding.binding_id})
                if stored_origin_error or not stored_origin or #stored_origin ~= 1 then error("missing stored origin view") end
                local stored_view = json.decode(tostring((assert(bounds.object(stored_origin[1]))).origin_view_json))
                test.eq((assert(bounds.object(stored_view))).instance_id, "instance-origin")
                local replayed_origin = raw_call(caller(true, false), "bee.gateway.binding:admit", replay_request)
                if not replayed_origin.ok then error("origin replay: " .. tostring(replayed_origin.error and replayed_origin.error.message)) end
                test.is_true((assert(bounds.object(replayed_origin.value))).replayed == true)
                local replayed_binding = assert(bounds.object((assert(bounds.object(replayed_origin.value))).binding))
                test.eq(((assert(bounds.object(replayed_binding.origin_view))).view_id), "view-origin")
                test.eq(((assert(bounds.object(replayed_binding.origin_view))).instance_id), "instance-origin")

                local before_epoch = first.epoch
                local before_secret = first.secret
                local before_key = first.native_key
                local _, drain_error = db:execute("UPDATE bee_gateway_listener SET drained = 1 WHERE singleton = 1")
                if drain_error then error("mark listener drained: " .. tostring(drain_error)) end
                local still_denied = raw_call(caller(true, false), "bee.gateway.binding:admit", admit_request("same-execution"))
                test.is_false(still_denied.ok)
                test.eq((assert(bounds.object(still_denied.error))).code, "STORAGE")
                local preserved = row(db)
                test.eq(preserved.epoch, before_epoch)
                test.eq(preserved.secret, before_secret)
                test.eq(preserved.native_key, before_key)
                test.eq(preserved.drained, 1)

                local opened = raw_call(caller(false, true), "bee.gateway.binding:open", {address = selected.address})
                if not opened.ok then error("explicit open: " .. tostring(opened.error and (assert(bounds.object(opened.error))).message)) end
                local reopened = row(db)
                test.eq(reopened.native_key, before_key)
                test.eq(reopened.epoch, 2)
                test.eq(reopened.drained, 0)
                test.is_true(reopened.secret ~= before_secret)

                local stale_key = "previous-native-listener-execution"
                local _, stale_error = db:execute("UPDATE bee_gateway_listener SET native_key = ? WHERE singleton = 1", {stale_key})
                if stale_error then error("mark previous listener execution: " .. tostring(stale_error)) end
                raw_call(caller(true, false), "bee.gateway.binding:check", {attempt_id = first_name.attempt_id, carrier_epoch = 1})
                local described = raw_call(caller(true, false, true), "bee.gateway.binding:describe", {workspace_id = first_name.workspace_id})
                if not described.ok then error("describe after listener restart: " .. tostring(described.error and described.error.message)) end
                test.eq((assert(bounds.object(described.value))).title, "Agent sessions")
                test.eq((assert(bounds.object(described.value))).total, 0)
                local reconciled = row(db)
                test.eq(reconciled.epoch, assert(bounds.integer(reopened.epoch)) + 1)
                test.eq(reconciled.address, selected.address)
                test.eq(reconciled.native_key, selected.native_key)
                test.is_true(reconciled.secret ~= reopened.secret)
                db:release()
            end)
            local restored, restore_error = pcall(restore, saved)
            if not restored then error("restore registry: " .. tostring(restore_error)) end
            if not ok then error(tostring(failure)) end
        end)
    end)
end

return test.run_cases(define_tests)
