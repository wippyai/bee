-- MIT. Probe child-thread messaging through the exact generated app grant.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local capability_grants = require("capability_grants")
local capability_catalog = require("capability_catalog")
local sends = require("sends")


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

local function fresh(prefix: string): string
    local id, err = uuid.v7()
    if err or not id then error("uuid: " .. tostring(err)) end
    return prefix .. "-" .. id
end

local function define_tests()
    test.describe("child-thread message grant", function()
        test.it("allows send, denies record and reports the raw app call error", function()
            local workspace = fresh("steer-workspace")
            local application = "bee.application:" .. workspace .. ":research"
            local app_id = "app.steer_probe:app"
            local owner = "bee.gov.apps:" .. workspace .. ".steer_probe"
            local catalog = assert(capability_catalog.decode(assert(registry.get("bee.security.capability:capability_catalog"))))
            local grant = {id = "app.steer_probe:message", expected_kind = "security.policy", value = nil,
                targets = {app_id}, capability_request = {capability = "threads.message",
                    parameters = {scope = "children"}, catalog_revision = catalog.revision,
                    template_revision = 1, reason = "Message managed child threads",
                    target = app_id, path = ".security.policies +="}}
            local proposed = assert(capability_grants.propose(catalog, owner, app_id, {grant}))
            local changes = registry.snapshot():changes()
            for _, entry in ipairs(proposed.policies) do
                local created, create_error = changes:create(registry_input(entry))
                if not created then error("create generated grant: " .. tostring(create_error)) end
            end
            local applied, apply_error = changes:apply()
            if not applied then error("apply generated grant: " .. tostring(apply_error)) end

            local policy_id = proposed.policies[1].id
            local grant_data = assert(bounds.object(proposed.policies[1].data))
            local generated = principals.strings((assert(bounds.object(grant_data.policy))).resources)
            local methods: {[string]: boolean} = {}
            for _, method in ipairs(generated) do methods[method] = true end
            test.is_true(methods["bee.threads.binding:send"] == true)
            test.is_true(methods["bee.threads.binding:notify"] == true)
            test.is_nil(methods["bee.threads.binding:record"])

            local create_policy = assert(security.policy("bee.security.threads:thread_create_policy"))
            local message_policy = assert(security.policy(policy_id))
            local actor = principals.actor(application, workspace)
            local creator_policies: {security.Policy} = {create_policy, message_policy}
            local creator = funcs.new():with_actor(actor):with_scope(security.new_scope(creator_policies))
            local thread_id = fresh("thread")
            local created, create_error = creator:call("bee.threads.binding:create", {
                thread_id = thread_id, idempotency_key = fresh("create"), title = "Steering probe"})
            if create_error then error("create thread: " .. tostring(create_error)) end
            test.eq((assert(bounds.object(created))).ok, true)
            local caller = funcs.new():with_actor(actor):with_scope(security.new_scope({message_policy}))

            local message = {message_id = fresh("message"), message_kind = "notification",
                recipient_ids = {}, content = {text = "generated child message"}}
            local payload_digest, digest_error = sends.payload_digest(message)
            if not payload_digest then error("message digest: " .. tostring(digest_error)) end
            local spawner = process.with_context({}):with_actor(actor):with_scope(security.new_scope({message_policy}))
            local pid, spawn_error = spawner:spawn_monitored("bee.harness.catalog:steer_grant_actor_probe", "bee:workers",
                thread_id, message, payload_digest, fresh("send"), fresh("record"), "node-steer-probe")
            if not pid then error("spawn app actor probe: " .. tostring(spawn_error)) end
            local events = assert(process.events())
            local deadline = time.after("10s")
            while true do
                local selected = channel.select({events:case_receive(), deadline:case_receive()})
                if not selected.ok or selected.channel == deadline then error("app actor probe did not finish") end
                local event = selected.value
                if event.kind == process.event.EXIT and tostring(event.from) == tostring(pid) then
                    local result = event.result or {}
                    if result.error then error("app actor probe: " .. tostring(result.error)) end
                    local probe = assert(bounds.object(result.value))
                    test.is_nil(probe.send_transport_error)
                    test.eq((assert(bounds.object(probe.send_reply))).ok, true)
                    local record_error = probe.record_transport_error
                    print("RAW_THREADS_MESSAGE_RECORD_FUNCS_CALL_ERROR=" .. tostring(record_error))
                    test.eq(record_error, "not allowed: bee.threads.binding:record")
                    test.is_nil(probe.record_reply)
                    return
                end
            end
        end)
    end)
end

return test.run_cases(define_tests)
