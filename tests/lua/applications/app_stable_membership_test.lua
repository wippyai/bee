-- MIT. An app follows the threads it created across restarts: it creates a
-- run thread, closes, reopens as a new instance, reads the thread and
-- records on it. Another app in the same workspace is refused, and after
-- the app is uninstalled its stable family is fenced out of every thread.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local process = require("process")
local channel = require("channel")
local security = require("security")
local funcs = require("funcs")
local time = require("time")
local registry = require("registry")
local catalog = require("catalog")
local appearance = require("appearance")
local fixture = require("fixture")
local ADMISSION_ID = "bee.security:application_admission"
local DEFINITION = "bee.harness.app:app"
local OTHER_DEFINITION = "bee.apps:welcome"
local RUN_THREAD = "stable-run-thread"
local BACKFILL_THREAD = "stable-backfill-run-thread"
local ATTEMPT = "stable-run-attempt-1"
local THREADS_POLICY = "bee.security.threads:thread_authority_client_policy"
local WORKSPACE = string.rep("a", 32)


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

local function unwrap(raw: unknown): {[string]: unknown}
    local reply = assert(bounds.object(raw))
    if reply.ok ~= true then
        local fault = (bounds.object(reply.error)) or {}
        error("call failed: " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return assert(bounds.object(reply.value))
end

local CREATE_POLICY = "bee.security.threads:thread_create_policy"
local function as_app(instance_id: string, target: string, request: unknown): {[string]: unknown}
    local actor = assert(security.new_actor("bee.application:" .. WORKSPACE .. ":" .. instance_id))
    local policy = assert(security.policy(THREADS_POLICY))
    local create_policy = assert(security.policy(CREATE_POLICY))
    local executor = assert(funcs.new():with_actor(actor):with_scope(security.new_scope({policy, create_policy})))
    local raw, call_error = executor:call(target, request)
    if call_error then error(target .. ": " .. tostring(call_error)) end
    return unwrap(raw)
end

local function app_code(instance_id: string, target: string, request: unknown): string
    local actor = assert(security.new_actor("bee.application:" .. WORKSPACE .. ":" .. instance_id))
    local policy = assert(security.policy(THREADS_POLICY))
    local executor = assert(funcs.new():with_actor(actor):with_scope(security.new_scope({policy})))
    local raw, call_error = executor:call(target, request)
    if call_error then error(target .. ": " .. tostring(call_error)) end
    local reply = assert(bounds.object(raw))
    assert(reply.ok ~= true, target .. " unexpectedly succeeded")
    return tostring((assert(bounds.object(reply.error))).code)
end

local function run_code(instance_id: string, thread_id: string?): string?
    local actor = assert(security.new_actor("bee.application:" .. WORKSPACE .. ":" .. instance_id))
    local policy = assert(security.policy(THREADS_POLICY))
    local executor = assert(funcs.new():with_actor(actor):with_scope(security.new_scope({policy})))
    local raw, call_error = executor:call("bee.threads.binding:get", {thread_id = thread_id or RUN_THREAD})
    if call_error then error("run thread: " .. tostring(call_error)) end
    local reply = assert(bounds.object(raw))
    if reply.ok == true then return nil end
    return tostring((assert(bounds.object(reply.error))).code)
end

local baseline_bindings: {{[string]: unknown}} = {}
local function preserve_admission(scope: fixture.State)
    local record = assert(bounds.object(assert(registry.snapshot():get(ADMISSION_ID))))
    local data = assert(bounds.object(record.data))
    baseline_bindings = {}
    for _, raw in ipairs(assert(principals.items(data.bindings))) do
        baseline_bindings[#baseline_bindings + 1] = assert(bounds.object(raw))
    end
    scope.cleanup[#scope.cleanup + 1] = function()
        local changes = registry.snapshot():changes()
        changes:update(registry_input(record))
        local restored, restore_error = changes:apply()
        assert(restored, tostring(restore_error))
    end
end

local function set_admission_for(definition_id: string, admitted: boolean)
    local snap = registry.snapshot()
    local record = assert(bounds.object(assert(snap:get(ADMISSION_ID))))
    local bindings = {}
    for _, binding in ipairs(baseline_bindings) do
        if admitted or binding.definition_id ~= definition_id then bindings[#bindings + 1] = binding end
    end
    local changes = snap:changes()
    changes:update({id = ADMISSION_ID, kind = "registry.entry", meta = registry_input(record).meta, data = {bindings = bindings}})
    local applied, apply_error = changes:apply()
    if not applied then error("apply application admission: " .. tostring(apply_error)) end
end

local function set_duplicate_admission()
    local snap = registry.snapshot()
    local record = assert(bounds.object(assert(snap:get(ADMISSION_ID))))
    local bindings: {{[string]: unknown}} = {}
    for _, binding in ipairs(baseline_bindings) do bindings[#bindings + 1] = binding end
    bindings[#bindings + 1] = bindings[1]
    local changes = snap:changes()
    changes:update({id = ADMISSION_ID, kind = "registry.entry", meta = registry_input(record).meta, data = {bindings = bindings}})
    local applied, apply_error = changes:apply()
    if not applied then error("apply duplicate application admission: " .. tostring(apply_error)) end
end

local function set_admission(admitted: boolean)
    set_admission_for(DEFINITION, admitted)
end

local function define_tests()
    test.describe("Application stable membership", function()
        test.it("restores admission and drains brokers after an early case failure", function()
            local original = assert(bounds.object(assert(registry.snapshot():get(ADMISSION_ID))))
            local bindings = assert(principals.items(assert(bounds.object(original.data)).bindings))
            local observed: fixture.State? = nil
            local ok, fault = pcall(fixture.case(function(scope: fixture.State)
                preserve_admission(scope)
                observed = scope
                local owner = tostring(process.pid())
                local catalogs = scope.catalogs
                local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner,
                    ["bee.workspace_id"] = WORKSPACE}):with_scope(security.new_scope({
                        assert(security.policy("bee.security.desktop:broker_policy")),
                        assert(security.policy("bee.security:core_spawn_boundary"))}))
                    :spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults(), {})))
                scope.brokers[broker] = true
                assert(tostring(catalogs:receive():from()) == broker)
                set_duplicate_admission()
                error("intentional fixture failure")
            end))
            test.is_false(ok)
            test.is_true(tostring(fault):find("intentional fixture failure", 1, true) ~= nil)
            test.is_true(next(assert(observed).brokers) == nil)
            local restored = assert(bounds.object(assert(registry.snapshot():get(ADMISSION_ID))))
            local actual = assert(principals.items(assert(bounds.object(restored.data)).bindings))
            test.eq(#actual, #bindings)
            for index, binding in ipairs(bindings) do
                test.eq(assert(bounds.object(actual[index])).definition_id, assert(bounds.object(binding)).definition_id)
            end
        end)
        test.it("follows its runs across restarts and loses them on uninstall", fixture.case(function(scope: fixture.State)
            preserve_admission(scope)
            local owner = tostring(process.pid())
            local catalogs = scope.catalogs
            local replies = scope.replies
            local broker_ready = scope.ready
            local events = scope.events
            local broker_pid, broker_error = process.with_context({["bee.workspace_owner"] = owner,
                ["bee.workspace_id"] = WORKSPACE}):with_scope(security.new_scope({assert(security.policy("bee.security.desktop:broker_policy")),
                assert(security.policy("bee.security:core_spawn_boundary"))}))
                :spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults(), {})
            if not broker_pid then error("broker spawn failed: " .. tostring(broker_error)) end
            local broker = tostring(broker_pid)
            scope.brokers[broker] = true
            assert(catalogs:receive():from() == broker)
            local function open(definition_id: string, tag: string): (string, string)
                local request_id = tag .. "-open"
                assert(process.send(broker, "bee.app.request", {version = 1, request_id = request_id, op = "open",
                    workspace_id = WORKSPACE, thread_id = "open-membership-thread", definition_id = definition_id,
                    arguments = {}}))
                local deadline = time.after("30s")
                while true do
                    local received = channel.select({replies:case_receive(), deadline:case_receive()})
                    assert(received.ok and received.channel == replies, tag .. " open reply timed out")
                    local message = received.value
                    if tostring(message:from()) == broker then
                        local data: unknown = message:payload():data()
                        if type(data) == "table" then
                            local reply = assert(bounds.object(data))
                            if reply.request_id == request_id and reply.op == "open" then
                                assert(reply.error_code == "", tag .. " did not become ready: " .. tostring(reply.error))
                                return tostring(reply.instance_id), tostring(reply.id)
                            end
                        end
                    end
                end
                error(tag .. " open reply loop ended")
            end
            local function close(view_id: unknown)
                local request_id = tostring(view_id) .. "-close"
                assert(process.send(broker, "bee.app.request", {version = 1, request_id = request_id, op = "close",
                    workspace_id = WORKSPACE, id = tostring(view_id)}))
                local deadline = time.after("30s")
                while true do
                    local received = channel.select({replies:case_receive(), deadline:case_receive()})
                    assert(received.ok and received.channel == replies, request_id .. " timed out")
                    local message = received.value
                    if tostring(message:from()) == broker then
                        local data: unknown = message:payload():data()
                        if type(data) == "table" then
                            local reply = assert(bounds.object(data))
                            if reply.request_id == request_id and reply.op == "close" then
                                assert(reply.error_code == "", request_id .. " failed: " .. tostring(reply.error))
                                return
                            end
                        end
                    end
                end
            end
            local launched, launch_error = funcs.call("bee.threads.binding:create",
                {thread_id = "open-membership-thread", idempotency_key = "open-membership-thread-create", title = "Open membership"})
            if launch_error then error("create launch thread: " .. tostring(launch_error)) end
            unwrap(launched)
            local first, first_view = open(DEFINITION, "stable-view-1")
            local created = as_app(first, "bee.threads.binding:create",
                {thread_id = thread_id or RUN_THREAD, idempotency_key = RUN_THREAD .. "-create", title = "Stable run"})
            test.eq(created.thread_id, RUN_THREAD)
            test.is_nil(run_code(first))
            close(first_view)
            local second, _ = open(DEFINITION, "stable-view-2")
            test.is_nil(run_code(second))
            local steered = as_app(second, "bee.threads.binding:record",
                {thread_id = RUN_THREAD, idempotency_key = "stable-steer-1", kind = "message",
                    body = {message_id = "stable-steer-1", message_kind = "progress",
                        recipient_ids = {}, content = {text = "continue"}}})
            test.eq(steered.sequence, 1)
            local reread = as_app(second, "bee.threads.binding:read_after",
                {thread_id = RUN_THREAD, cursor = 0, limit = 8})
            test.eq(#(principals.items(reread.records)), 1)
            local other, _ = open(OTHER_DEFINITION, "stable-view-3")
            test.eq(run_code(other), "DENIED")
            test.eq(app_code(other, "bee.threads.binding:get", {thread_id = RUN_THREAD}), "DENIED")
            set_admission(false)
            local function revoked_refused()
                local deadline = time.after("15s")
                while true do
                    if run_code(second) == "DENIED" then break end
                    local tick = channel.select({deadline:case_receive(), time.after("200ms"):case_receive()})
                    assert(tick.ok and tick.channel ~= deadline, "revoked app kept its runs")
                end
                test.eq(app_code(second, "bee.threads.binding:record",
                    {thread_id = RUN_THREAD, idempotency_key = "stable-steer-2", kind = "message",
                        body = {message_id = "stable-steer-2", message_kind = "progress",
                            recipient_ids = {}, content = {text = "after revoke"}}}), "DENIED")
            end
            local fenced_ok, fence_error = pcall(revoked_refused)
            set_admission(true)
            assert(fenced_ok, tostring(fence_error))

            -- Boot can read its initial catalog before governance has
            -- reapplied a retained definition. Backfill must preserve this
            -- app family until the admitted definition returns.
            local backfill_created = as_app(other, "bee.threads.binding:create",
                {thread_id = BACKFILL_THREAD, idempotency_key = BACKFILL_THREAD .. "-create", title = "Backfill run"})
            test.eq(backfill_created.thread_id, BACKFILL_THREAD)
            assert(process.cancel(broker, "restart retained alias probe"))
            fixture.join(scope, broker)

            local restarted_broker: string? = nil
            local backfill_ok, backfill_error = pcall(function()
                set_admission_for(OTHER_DEFINITION, false)
                local restart_pid, restart_error = process.with_context({["bee.workspace_owner"] = owner,
                    ["bee.workspace_id"] = WORKSPACE}):with_scope(security.new_scope({assert(security.policy("bee.security.desktop:broker_policy")),
                    assert(security.policy("bee.security:core_spawn_boundary"))}))
                    :spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults(),
                        {{instance_id = other, definition_id = OTHER_DEFINITION}})
                if not restart_pid then error("restart broker spawn failed: " .. tostring(restart_error)) end
                restarted_broker = tostring(restart_pid)
                scope.brokers[restarted_broker] = true
                local ready_deadline = time.after("30s")
                local backfill_ready = false
                while not backfill_ready do
                    local received = channel.select({broker_ready:case_receive(), ready_deadline:case_receive()})
                    assert(received.ok and received.channel == broker_ready, "restarted broker did not finish alias backfill")
                    backfill_ready = tostring(received.value:from()) == restarted_broker
                end

                -- Simulate the overlay becoming available after the broker's
                -- initial catalog. The same retained instance must still see the
                -- thread it created before restart.
                local previous_revision = catalog.revision(WORKSPACE)
                set_admission_for(OTHER_DEFINITION, true)
                test.is_true(catalog.revision(WORKSPACE) ~= previous_revision,
                    "application admission overlay did not change its catalog revision")
                local catalog_deadline = time.after("30s")
                local definition_returned = false
                while not definition_returned do
                    local received = channel.select({catalogs:case_receive(), catalog_deadline:case_receive()})
                    assert(received.ok and received.channel == catalogs, "restored definition did not return to catalog")
                    local message = received.value
                    if tostring(message:from()) == restarted_broker then
                        local data: unknown = message:payload():data()
                        if type(data) == "table" then
                            for _, raw in ipairs((principals.items((assert(bounds.object(data))).items or {})) or {}) do
                                if type(raw) == "table" and (assert(bounds.object(raw))).definition_id == OTHER_DEFINITION then
                                    definition_returned = true
                                end
                            end
                        end
                    end
                end
                as_app(other, "bee.threads.binding:get", {thread_id = BACKFILL_THREAD})
            end)
            set_admission_for(OTHER_DEFINITION, true)
            if restarted_broker then
                pcall(process.cancel, restarted_broker, "finish retained alias probe")
                fixture.join(scope, restarted_broker)
            end
            assert(backfill_ok, "startup backfill fenced a temporarily absent app family: " .. tostring(backfill_error))
        end))

        test.it("fences a removed application family when an earlier refresh was refused", fixture.case(function(scope: fixture.State)
            preserve_admission(scope)
            local owner = tostring(process.pid())
            local catalogs = scope.catalogs
            local replies = scope.replies
            local events = scope.events
            local broker_pid, broker_error = process.with_context({["bee.workspace_owner"] = owner,
                ["bee.workspace_id"] = WORKSPACE}):with_scope(security.new_scope({assert(security.policy("bee.security.desktop:broker_policy")),
                assert(security.policy("bee.security:core_spawn_boundary"))}))
                :spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults(), {})
            if not broker_pid then error("broker spawn failed: " .. tostring(broker_error)) end
            local broker = tostring(broker_pid)
            scope.brokers[broker] = true
            local function open(definition_id: string, request_id: string): {[string]: unknown}
                assert(process.send(broker, "bee.app.request", {version = 1, request_id = request_id, op = "open",
                    workspace_id = WORKSPACE, thread_id = "refused-refresh-thread", definition_id = definition_id, arguments = {}}))
                local deadline = time.after("30s")
                while true do
                    local received = channel.select({replies:case_receive(), deadline:case_receive()})
                    assert(received.ok and received.channel == replies, request_id .. " reply timed out")
                    local data: unknown = received.value:payload():data()
                    if tostring(received.value:from()) == broker and type(data) == "table"
                        and (assert(bounds.object(data))).request_id == request_id then
                        return assert(bounds.object(data))
                    end
                end
                error("reply loop ended")
            end
            local ok, scenario_error = pcall(function()
                assert(catalogs:receive():from() == broker)
                local launched, launch_error = funcs.call("bee.threads.binding:create",
                    {thread_id = "refused-refresh-thread", idempotency_key = "refused-refresh-thread-create", title = "Refused refresh"})
                if launch_error then error("create launch thread: " .. tostring(launch_error)) end
                unwrap(launched)
                local opened = open(DEFINITION, "refused-refresh-open")
                test.eq(opened.error_code, "", "application did not become ready")
                local instance = tostring(opened.instance_id)
                as_app(instance, "bee.threads.binding:create",
                    {thread_id = "refused-refresh-run", idempotency_key = "refused-refresh-run-create", title = "Refused run"})
                test.is_nil(run_code(instance, "refused-refresh-run"))

                set_duplicate_admission()
                test.eq(open(OTHER_DEFINITION, "refused-refresh-open-2").error_code, "not_admitted")
                set_admission(false)
                test.eq(open(OTHER_DEFINITION, "refused-refresh-open-3").error_code, "")
                test.eq(run_code(instance, "refused-refresh-run"), "DENIED")
            end)
            set_admission(true)
            pcall(process.cancel, broker, "finish refused refresh probe")
            fixture.join(scope, broker)
            assert(ok, tostring(scenario_error))
        end))

        test.it("retries a refused admission refresh at the next revision check", fixture.case(function(scope: fixture.State)
            preserve_admission(scope)
            local follower = catalog.follower("r1")
            local attempts = 0
            local function refused(): boolean attempts = attempts + 1; return false end
            local function accepted(): boolean attempts = attempts + 1; return true end
            test.is_false(catalog.follow(follower, "r1", refused))
            test.eq(attempts, 0)
            test.is_true(catalog.follow(follower, "r2", refused))
            test.eq(follower.observed, "r1")
            test.is_true(catalog.follow(follower, "r2", refused))
            test.eq(attempts, 2)
            test.is_true(catalog.follow(follower, "r2", accepted))
            test.eq(follower.observed, "r2")
            test.is_false(catalog.follow(follower, "r2", accepted))
            test.eq(attempts, 3)
        end))

        test.it("retries a request-driven refresh failure at the same revision", fixture.case(function(scope: fixture.State)
            preserve_admission(scope)
            local follower = catalog.follower("r1")
            local attempts = 0
            local function request_refresh(): boolean
                attempts = attempts + 1
                catalog.invalidate(follower)
                return false
            end
            local function recovered(): boolean attempts = attempts + 1; return true end

            test.is_false(request_refresh())
            test.eq(follower.observed, nil)
            test.is_true(catalog.follow(follower, "r1", recovered))
            test.eq(attempts, 2)
            test.eq(follower.observed, "r1")
        end))

        -- A malformed admission makes refresh_admission fail closed. Once the
        -- record is repaired, the periodic follower must run again and publish
        -- the catalog left by that repair.
        test.it("retries the admission poll after a refused refresh", fixture.case(function(scope: fixture.State)
            preserve_admission(scope)
            local owner = tostring(process.pid())
            local catalogs = scope.catalogs
            local events = scope.events
            local broker_pid, broker_error = process.with_context({["bee.workspace_owner"] = owner,
                ["bee.workspace_id"] = WORKSPACE}):with_scope(security.new_scope({assert(security.policy("bee.security.desktop:broker_policy")),
                assert(security.policy("bee.security:core_spawn_boundary"))}))
                :spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults(), {})
            if not broker_pid then error("broker spawn failed: " .. tostring(broker_error)) end
            local broker = tostring(broker_pid)
            scope.brokers[broker] = true
            local ok, scenario_error = pcall(function()
                repeat until tostring(catalogs:receive():from()) == broker
                set_duplicate_admission()
                local deadline = time.after("15s")
                local refused = false
                while not refused do
                    local received = channel.select({catalogs:case_receive(), events:case_receive(), deadline:case_receive()})
                    assert(received.ok, "broker refresh wait was interrupted")
                    if received.channel == events then
                        local event = received.value
                        if event.kind == process.event.EXIT and tostring(event.from) == broker then
                            scope.brokers[broker] = nil
                            local result: unknown = event.result
                            local failure = type(result) == "table" and tostring((assert(bounds.object(result))).error) or "unknown exit"
                            error("broker exited during refused refresh: " .. failure)
                        end
                    elseif received.channel == deadline then
                        error("broker did not fail closed on the invalid admission")
                    else
                        local message = received.value
                        if tostring(message:from()) == broker then
                            local data: unknown = message:payload():data()
                            local items = type(data) == "table" and (assert(bounds.object(data))).items or nil
                            if type(items) == "table" and #items == 0 then refused = true end
                        end
                    end
                end
                local refused_revision = catalog.revision(WORKSPACE)
                set_admission_for(OTHER_DEFINITION, false)
                test.is_true(catalog.revision(WORKSPACE) ~= refused_revision,
                    "repair did not advance the application catalog revision")
                local converged = false
                while not converged do
                    local received = channel.select({catalogs:case_receive(), events:case_receive(), deadline:case_receive()})
                    assert(received.ok, "broker convergence wait was interrupted")
                    if received.channel == events then
                        local event = received.value
                        if event.kind == process.event.EXIT and tostring(event.from) == broker then
                            scope.brokers[broker] = nil
                            local result: unknown = event.result
                            local failure = type(result) == "table" and tostring((assert(bounds.object(result))).error) or "unknown exit"
                            error("broker exited before catalog convergence: " .. failure)
                        end
                    elseif received.channel == deadline then
                        error("broker never converged on the repaired admission")
                    else
                        local message = received.value
                        if tostring(message:from()) == broker then
                            local data: unknown = message:payload():data()
                            if type(data) == "table" then
                                local items = (principals.items((assert(bounds.object(data))).items or {})) or {}
                                local has_definition = false
                                local has_other = false
                                for _, raw in ipairs(items) do
                                    if type(raw) == "table" then
                                        local definition_id = (assert(bounds.object(raw))).definition_id
                                        if definition_id == DEFINITION then has_definition = true end
                                        if definition_id == OTHER_DEFINITION then has_other = true end
                                    end
                                end
                                if has_definition and not has_other then converged = true end
                            end
                        end
                    end
                end
            end)
            set_admission_for(OTHER_DEFINITION, true)
            pcall(process.cancel, broker, "finish admission convergence probe")
            fixture.join(scope, broker)
            assert(ok, tostring(scenario_error))
        end))

        test.it("converges after an observed refusal without accepting stale catalog messages", fixture.case(function(scope: fixture.State)
            preserve_admission(scope)
            local owner = tostring(process.pid())
            local catalogs = scope.catalogs
            local replies = scope.replies
            local events = scope.events
            local broker_pid, broker_error = process.with_context({["bee.workspace_owner"] = owner,
                ["bee.workspace_id"] = WORKSPACE}):with_scope(security.new_scope({assert(security.policy("bee.security.desktop:broker_policy")),
                assert(security.policy("bee.security:core_spawn_boundary"))}))
                :spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults(), {})
            if not broker_pid then error("broker spawn failed: " .. tostring(broker_error)) end
            local broker = tostring(broker_pid)
            scope.brokers[broker] = true
            local function has_definition(data: {[string]: unknown}, definition_id: string): boolean
                for _, raw in ipairs((principals.items(data.items or {})) or {}) do
                    if type(raw) == "table" and (assert(bounds.object(raw))).definition_id == definition_id then return true end
                end
                return false
            end
            local function open(request_id: string)
                assert(process.send(broker, "bee.app.request", {version = 1, request_id = request_id, op = "open",
                    workspace_id = WORKSPACE, thread_id = "catalog-convergence-thread", definition_id = OTHER_DEFINITION, arguments = {}}))
            end
            local ok, scenario_error = pcall(function()
                local initial_deadline = time.after("10s")
                local initial: {[string]: unknown}? = nil
                while not initial do
                    local received = channel.select({catalogs:case_receive(), initial_deadline:case_receive()})
                    assert(received.ok and received.channel == catalogs, "broker did not publish its initial catalog")
                    if tostring(received.value:from()) == broker then
                        local data: unknown = received.value:payload():data()
                        if type(data) == "table" then initial = assert(bounds.object(data)) end
                    end
                end
                test.is_true(has_definition(initial, OTHER_DEFINITION), "initial catalog lacks the definition under test")
                local retained_definition: string? = nil
                for _, raw in ipairs((principals.items(initial.items or {})) or {}) do
                    if type(raw) == "table" and (assert(bounds.object(raw))).definition_id ~= OTHER_DEFINITION then
                        retained_definition = tostring((assert(bounds.object(raw))).definition_id)
                        break
                    end
                end
                if not retained_definition then error("initial catalog has no other definition to distinguish the final state") end

                set_duplicate_admission()
                open("catalog-refused-open")
                local refusal_catalog, refusal_reply = false, false
                local refusal_deadline = time.after("10s")
                while not refusal_catalog or not refusal_reply do
                    local received = channel.select({catalogs:case_receive(), replies:case_receive(), refusal_deadline:case_receive()})
                    assert(received.ok and received.channel ~= refusal_deadline, "broker did not report the admission refusal")
                    if received.channel == catalogs and tostring(received.value:from()) == broker then
                        local data: unknown = received.value:payload():data()
                        if type(data) == "table" then
                            local catalog_data = assert(bounds.object(data))
                            test.is_false(has_definition(catalog_data, OTHER_DEFINITION))
                            test.is_false(has_definition(catalog_data, retained_definition))
                            refusal_catalog = true
                        end
                    elseif received.channel == replies and tostring(received.value:from()) == broker then
                        local data: unknown = received.value:payload():data()
                        if type(data) == "table" and (assert(bounds.object(data))).request_id == "catalog-refused-open" then
                            test.eq((assert(bounds.object(data))).error_code, "not_admitted")
                            refusal_reply = true
                        end
                    end
                end

                set_admission_for(OTHER_DEFINITION, false)
                open("catalog-final-open")
                local final_catalog, final_reply = false, false
                local final_deadline = time.after("10s")
                while not final_catalog or not final_reply do
                    local received = channel.select({catalogs:case_receive(), replies:case_receive(), final_deadline:case_receive()})
                    assert(received.ok and received.channel ~= final_deadline, "broker never published the final catalog")
                    if received.channel == catalogs and tostring(received.value:from()) == broker then
                        local data: unknown = received.value:payload():data()
                        if type(data) == "table" then
                            local catalog_data = assert(bounds.object(data))
                            if has_definition(catalog_data, retained_definition) and not has_definition(catalog_data, OTHER_DEFINITION) then
                                final_catalog = true
                            end
                        end
                    elseif received.channel == replies and tostring(received.value:from()) == broker then
                        local data: unknown = received.value:payload():data()
                        if type(data) == "table" and (assert(bounds.object(data))).request_id == "catalog-final-open" then
                            test.eq((assert(bounds.object(data))).error_code, "not_admitted")
                            final_reply = true
                        end
                    end
                end
            end)
            set_admission_for(OTHER_DEFINITION, true)
            pcall(process.cancel, broker, "finish admission convergence probe")
            fixture.join(scope, broker)
            assert(ok, tostring(scenario_error))
        end))
    end)
end

return test.run_cases(define_tests)
