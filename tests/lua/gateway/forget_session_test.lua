-- MIT. Removing a session deletes every gateway binding issued to it with
-- their credentials, surfaces and gateway access grants; bindings of other
-- subjects stay.
local shared_authority = require("shared_authority")
local test = require("test")
local bounds = require("bounds")
local funcs = require("funcs")
local registry = require("registry")
local time = require("time")
local principals = require("principals")
local harness = require("harness")
local ACTOR = "bee.test.forget_session"
local WORKSPACE = string.rep("c", 32)
type Object = {[string]: unknown}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local MANAGER = {"bee.tests.harness:carrier_client_policy", "bee.tests.harness:gateway_client_policy", "bee.harness.security:carrier_policy",
    "bee.threads.security:create", "bee.threads.security:observe", "bee.tests.support:gateway_manage_policy",
    "bee.tests.support:gateway_admit_policy", "bee.security.gateway:gateway_materialize_policy"}
local CARRIER = {"bee.tests.harness:carrier_client_policy", "bee.tests.harness:gateway_client_policy", "bee.harness.security:carrier_policy",
    "bee.tests.support:gateway_admit_policy"}
local function reply(names: {string}, target: string, request: unknown): Object
    local result, err = funcs.new():with_actor(principals.actor(ACTOR, WORKSPACE)):with_scope(shared_authority.scope(names)):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return assert(bounds.object(result))
end
local function call(target: string, request: unknown): Object
    local answered = reply(MANAGER, target, request)
    if answered.ok ~= true then
        local fault = bounds.object(answered.error) or {}
        error(target .. ": " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return assert(bounds.object(answered.value))
end
local function address(): string
    local entry = registry.get("bee.gateway.api:gateway_endpoint")
    if not entry then error("gateway endpoint entry") end
    return tostring((assert(bounds.object(entry.data))).address)
end
local function admit(subject: string, thread_id: string): string
    local attempt_id = fresh("attempt")
    local admitted = call("bee.gateway.binding:admit", {subject = subject, action_id = "action-" .. attempt_id, attempt_id = attempt_id,
        thread_id = thread_id, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read", "app_tools"}, hooks = {"PostToolUse"}})
    local binding_id = tostring((assert(bounds.object(admitted.binding))).binding_id)
    local authorized = call("bee.gateway.binding:authorize_materialization", {attempt_id = attempt_id, carrier_epoch = 1, binding_id = binding_id})
    call("bee.gateway.binding:materialize", {attempt_id = attempt_id, carrier_epoch = 1, binding_id = binding_id,
        materialization_key = authorized.materialization_key})
    return binding_id
end
-- held counts the rows the gateway keeps for a subject.
local function held(subject: string): {[string]: integer}
    local db = harness.open()
    local counts: {[string]: integer} = {}
    local owned = "(SELECT binding_id FROM bee_gateway_bindings WHERE subject = ?)"
    for name, statement in pairs({bindings = "SELECT COUNT(*) AS n FROM bee_gateway_bindings WHERE subject = ?",
        credentials = "SELECT COUNT(*) AS n FROM bee_gateway_credentials WHERE binding_id IN " .. owned,
        surfaces = "SELECT COUNT(*) AS n FROM bee_gateway_surfaces WHERE binding_id IN " .. owned,
        grants = "SELECT COUNT(*) AS n FROM bee_approval_grants WHERE domain = 'gateway_access' AND requester_id = ?"}) do
        counts[name] = math.floor(tonumber(harness.query(db, statement, {subject})[1].n) or 0)
    end
    db:release()
    return counts
end
local function define_tests()
    test.describe("Gateway session removal", function()
        test.it("deletes the bindings issued to a session and keeps other subjects' bindings", function()
            call("bee.gateway.binding:open", {address = address()})
            local thread = call("bee.threads.binding:create", {thread_id = fresh("thread"), idempotency_key = fresh("key"), title = "Forget session"})
            local session = "bs:node:" .. WORKSPACE .. ":" .. fresh("session")
            local other = "bs:node:" .. WORKSPACE .. ":" .. fresh("other")
            admit(session, tostring(thread.thread_id))
            local revoked = admit(session, tostring(thread.thread_id))
            call("bee.gateway.binding:revoke", {binding_id = revoked})
            admit(other, tostring(thread.thread_id))
            local before = held(session)
            test.eq(before.bindings, 2)
            test.is_true(before.credentials > 0, "session credentials " .. tostring(before.credentials))
            test.is_true(before.surfaces > 0, "session surfaces " .. tostring(before.surfaces))
            test.is_true(before.grants > 0, "session grants " .. tostring(before.grants))
            test.eq(call("bee.gateway.binding:forget_session", {session = session}).bindings, 2)
            local after = held(session)
            test.eq(after.bindings, 0)
            test.eq(after.credentials, 0)
            test.eq(after.surfaces, 0)
            test.eq(after.grants, 0)
            local kept = held(other)
            test.eq(kept.bindings, 1)
            test.is_true(kept.surfaces > 0, "kept surfaces " .. tostring(kept.surfaces))
            test.is_true(kept.credentials > 0, "kept credentials " .. tostring(kept.credentials))
            test.is_true(kept.grants > 0, "kept grants " .. tostring(kept.grants))
            test.eq(call("bee.gateway.binding:forget_session", {session = session}).bindings, 0)
        end)
        test.it("refuses a caller that does not manage gateway bindings", function()
            local answered = reply(CARRIER, "bee.gateway.binding:forget_session", {session = "bs:node:" .. WORKSPACE .. ":" .. fresh("denied")})
            test.is_false(answered.ok)
            test.eq((assert(bounds.object(answered.error))).code, "DENIED")
        end)
    end)
end
return test.run_cases(define_tests)
