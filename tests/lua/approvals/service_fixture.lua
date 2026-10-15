-- MIT. Shared approval service principals, stores and delivery fixtures.
local test = require("test")
local support = require("support")
local principals = require("principals")
local bounds = require("bounds")
local funcs = require("funcs")
local registry = require("registry")
local time = require("time")
local process = require("process")
local channel = require("channel")
local sql = require("sql")
local service = require("service")
local demand = require("demand")
local schema = require("schema")
local thread_harness = require("thread_harness")
local function new()
    local TEST_STORE = "bee.tests.approvals:test_db"
    local REQUESTER, OTHER_REQUESTER, ALICE, BOB, OUTSIDER, MANAGER = "bee.test.launcher", "bee.test.other_launcher", "bee.test.alice", "bee.test.bob", "bee.test.outsider", "bee.test.manager"
    local OUTBOX = "bee.test.outbox"
    local POLICY = "test-owner"
    local key, scope, caller = support.key, support.scope, support.caller
    local requester = caller(REQUESTER, {"bee.security.approvals:approval_request_policy", "bee.security.approvals:approval_consume_policy", "bee.threads.security:create", "bee.threads.security:observe", "bee.threads.security:store"})
    local launcher = thread_harness.principal(REQUESTER, thread_harness.ALL)
    local stranger = thread_harness.principal("bee.test.stranger", thread_harness.ALL)
    local other_requester = caller(OTHER_REQUESTER, {"bee.security.approvals:approval_request_policy"})
    local alice = caller(ALICE, {"bee.security.approvals:approval_decide_policy"})
    local bob = caller(BOB, {"bee.security.approvals:approval_decide_policy"})
    local carol = caller("bee.test.carol", {"bee.security.approvals:approval_decide_policy"})
    local outsider = caller(OUTSIDER, {})
    local manager = caller(MANAGER, {"bee.tests.approvals:manage_test_policy"})
    local INBOX_ACTOR = "bee.application:0123456789abcdef0123456789abcdef:inbox-instance"
    local inbox_app = caller(INBOX_ACTOR, {"bee.security.approvals:approval_decide_policy"},
        {definition_id = "bee.approvals.inbox.app:app", workspace_id = "0123456789abcdef0123456789abcdef"})
    local other_app = caller("bee.application:0123456789abcdef0123456789abcdef:other-instance",
        {"bee.security.approvals:approval_decide_policy"}, {definition_id = "bee.settings.app:app"})
    local owner = caller(OUTBOX, {"bee.security.approvals:approval_owner_policy", "bee.threads.security:approval", "bee.threads.security:approval_client", "bee.threads.security:store"})
    local function call(client: funcs.Executor, method: string, value: unknown): service.Reply
        local reply, err = client:call("bee.approvals.binding:" .. method, value)
        if err then error(method .. ": " .. tostring(err)) end
        return principals.replayed_reply(reply)
    end
    local function value(reply: service.Reply): {[string]: unknown}
        if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
        return assert(bounds.object(reply.value))
    end
    local function code(reply: service.Reply): string
        if reply.ok then error("expected a failure, got success") end
        return reply.error and reply.error.code or ""
    end
    local function await(future: funcs.Future): service.Reply
        local channel = future:response()
        local payload, open = channel:receive()
        local result, err = future:result()
        if err then error("async call: " .. tostring(err)) end
        if not open or not payload then error("async call closed without a reply") end
        local data: unknown = result:data()
        if type(data) ~= "table" then error("async call returned " .. type(data)) end
        return principals.replayed_reply(data)
    end
    local function open_test_store(): sql.DB
        return schema.open(TEST_STORE, "bee.approvals.migrations")
    end
    local function executed(result: {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean}): {[string]: unknown}
        if not result.ok then error(tostring(result.code) .. ": " .. tostring(result.message)) end
        return assert(bounds.object(result.value))
    end
    local function fault_value(reply: service.Reply): {[string]: unknown}
        if reply.ok then error("expected a failure, got success") end
        return assert(bounds.object(reply.value))
    end
    local function install_policy()
        local entry = registry.get("bee.security.approvals:approver_policies")
        if not entry then error("approver policies entry") end
        local data = assert(bounds.object(entry.data))
        local policies = principals.objects(data.policies)
        data.policies = policies
        for _, policy in ipairs(policies) do
            if policy.name == POLICY then return end
        end
        policies[#policies + 1] = {name = POLICY,
            approvers = {ALICE, BOB, "bee.test.carol", {definition_id = "bee.approvals.inbox.app:app"}}, max_ttl_ms = 60000}
        local changes = registry.snapshot():changes()
        changes:update(entry)
        local applied, err = changes:apply()
        if not applied then error("install approver policy: " .. tostring(err)) end
    end
    local function replace_approvers(value: {unknown})
        local entry = assert(registry.get("bee.security.approvals:approver_policies"))
        local data = assert(bounds.object(entry.data))
        local policies = principals.objects(data.policies)
        local selected: {[string]: unknown}? = nil
        for _, policy in ipairs(policies) do
            if policy.name == POLICY then selected = policy; break end
        end
        assert(selected, "test approver policy is missing")
        selected.approvers = value
        local changes = registry.snapshot():changes()
        assert(changes:update(entry))
        local applied, apply_error = changes:apply()
        if not applied then error("replace test approvers: " .. tostring(apply_error)) end
    end
    local function proposal(payload: {[string]: unknown}?): {[string]: unknown}
        return {kind = "operation", ref = "bee.tests.harness.admission:start", revision = "r1", payload = payload or {profile = "claude", argv = {"--print"}}}
    end
    local function attempt_proposal(action_id: string?, attempt_id: string): {[string]: unknown}
        return {kind = "attempt", ref = attempt_id, revision = "r1", action_id = action_id, payload = {tool = "Bash", correlation_id = "c-1"}}
    end
    local function request_of(workspace: string, extra: {[string]: unknown}?): {[string]: unknown}
        local request: {[string]: unknown} = {workspace_id = workspace, idempotency_key = key(), request_kind = "permission", policy = POLICY, proposal = proposal(),
            prompt = {text = "Launch claude in " .. workspace .. "?"}}
        if extra then
            for name, item in pairs(extra) do request[name] = item end
        end
        return request
    end
    local function thread(): string
        local thread_id = "thread-" .. key()
        local reply, err = requester:call("bee.threads.binding:create", {thread_id = thread_id, idempotency_key = key(), title = "Approvals"})
        if err then error("create thread: " .. tostring(err)) end
        local typed = principals.replayed_reply(reply)
        if not typed.ok then error("create thread: " .. tostring(typed.error and typed.error.message)) end
        return thread_id
    end
    local function records_of(thread_id: string, kinds: {string}): {{[string]: unknown}}
        local reply, err = requester:call("bee.threads.binding:read_after", {thread_id = thread_id, cursor = 0, filter = {kinds = kinds}})
        if err then error("read thread: " .. tostring(err)) end
        local typed = principals.replayed_reply(reply)
        if not typed.ok then error("read thread: " .. tostring(typed.error and typed.error.message)) end
        local page = assert(bounds.object(typed.value))
        return principals.objects(page.records)
    end
    local function thread_records(thread_id: string): {{[string]: unknown}}
        return records_of(thread_id, {"approval.request", "approval.transition"})
    end
    local function await_records(thread_id: string, kinds: {string}, count: integer): {{[string]: unknown}}
        local guard_ms = math.floor(time.now():unix_nano() / 1000000) + 120000
        local records: {{[string]: unknown}} = {}
        local cursor = 0
        while #records < count do
            local reply, err = requester:call("bee.threads.binding:read_after", {thread_id = thread_id, cursor = cursor,
                limit = 64, filter = {kinds = kinds}})
            if err then error("read thread: " .. tostring(err)) end
            local page = value(principals.replayed_reply(reply))
            for _, item in ipairs(principals.objects(page.records)) do records[#records + 1] = item end
            cursor = math.floor(tonumber(page.scanned_through) or cursor)
            if #records >= count then break end
            if page.has_more ~= true then
                local remaining = guard_ms - math.floor(time.now():unix_nano() / 1000000)
                if remaining <= 0 then error("thread " .. thread_id .. " retained only " .. tostring(#records) .. " of " .. tostring(count) .. " records") end
                local watched, watch_error = requester:call("bee.threads.binding:watch", {thread_id = thread_id,
                    after_sequence = cursor, wait_ms = remaining})
                if watch_error then error("watch thread: " .. tostring(watch_error)) end
                value(principals.replayed_reply(watched))
            end
        end
        return records
    end
    local function until_records(thread_id: string, count: integer): {{[string]: unknown}}
        return await_records(thread_id, {"approval.request", "approval.transition"}, count)
    end
    local function until_notices(thread_id: string, count: integer): {{[string]: unknown}}
        return await_records(thread_id, {"message"}, count)
    end
    local function effect_wake(approval_id: string, destination: string, name: string, mutate: () -> ())
        local wakes = assert(process.listen("bee.test.effect_delivery", {message = true}))
        assert(process.registry.register("bee.test.effect_delivery"))
        local ok, problem = pcall(function()
            mutate()
            local deadline = time.after("1s")
            while true do
                local selected = channel.select({wakes:case_receive(), deadline:case_receive()})
                test.eq(selected.ok, true)
                test.eq(selected.channel, wakes, "committed approval wake is not delivered")
                local supervisor = assert(process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL))
                test.eq(tostring(selected.value:from()), tostring(supervisor))
                local delivered = assert(bounds.object(selected.value:payload():data()))
                for _, raw in ipairs(assert(bounds.array(delivered.requests, 64))) do
                    local request = assert(bounds.object(raw))
                    local data = assert(bounds.object(request.data))
                    local effect = bounds.object(data.effect)
                    if effect and effect.approval_id == approval_id then
                        test.eq(delivered.name, name)
                        test.is_true(type(delivered.pid) == "string")
                        test.is_true(assert(bounds.integer(delivered.generation)) > 0)
                        test.eq(data.topic, service.TOPIC_WAKE)
                        test.eq(data.request_id, effect.event_id)
                        test.eq(effect.contract_version, 2)
                        test.eq(effect.revision, 2)
                        test.eq(effect.destination, destination)
                        return
                    end
                end
            end
        end)
        process.registry.unregister("bee.test.effect_delivery")
        process.unlisten(wakes)
        if not ok then error(tostring(problem)) end
    end
    local function retire_owned_effects()
        local db = assert(sql.get("bee:db"))
        local rows = assert(db:query("SELECT r.approval_id FROM bee_approval_requests r JOIN bee_approval_effects e ON e.approval_id=r.approval_id WHERE r.requester_id=? AND e.destination IN ('gateway.installation','gateway.publication','gov.activation') AND r.state<>'pending' AND r.effect_completed_at IS NULL", {REQUESTER}))
        for _, row in ipairs(rows) do
            local current = value(call(requester, "read", {approval_id = row.approval_id}))
            local effect = assert(bounds.object(current.effect))
            local effect_key = current.consumed_effect or effect.effect_id
            if effect.state == "authorized" then
                value(call(requester, "effect", {operation = "claim", approval_id = row.approval_id,
                    proposal_digest = current.proposal_digest, reviewed_digest = current.reviewed_digest,
                    effect_key = effect_key, owner_incarnation = current.validated_incarnation or current.owner_incarnation}))
            end
            value(call(requester, "effect", {operation = "complete", approval_id = row.approval_id,
                proposal_digest = current.proposal_digest, reviewed_digest = current.reviewed_digest,
                effect_key = effect_key, state = "canceled", result = {closed = true}}))
        end
        local destinations: {[string]: {string}} = {}
        for _, row in ipairs(assert(db:query("SELECT e.event_id,e.destination FROM bee_approval_events e JOIN bee_approval_requests r ON r.approval_id=e.approval_id WHERE r.requester_id=? AND e.acknowledged_at IS NULL AND e.destination IN ('gateway.installation','gateway.publication','gov.activation')", {REQUESTER}))) do
            local destination = assert(bounds.id(row.destination))
            destinations[destination] = destinations[destination] or {}
            table.insert(destinations[destination], assert(bounds.id(row.event_id)))
        end
        db:release()
        for destination, ids in pairs(destinations) do value(call(owner, "events", {destination = destination, acknowledge = ids})) end
    end

    local function setup(store: string, establish: boolean)
        TEST_STORE = store
        install_policy()
        if establish then
            local db = open_test_store()
            assert(service.establish(db))
            db:release()
        end
    end

    return {
        REQUESTER = REQUESTER,
        OTHER_REQUESTER = OTHER_REQUESTER,
        ALICE = ALICE,
        BOB = BOB,
        OUTSIDER = OUTSIDER,
        MANAGER = MANAGER,
        OUTBOX = OUTBOX,
        POLICY = POLICY,
        key = key,
        scope = scope,
        caller = caller,
        requester = requester,
        launcher = launcher,
        stranger = stranger,
        other_requester = other_requester,
        alice = alice,
        bob = bob,
        carol = carol,
        outsider = outsider,
        manager = manager,
        INBOX_ACTOR = INBOX_ACTOR,
        inbox_app = inbox_app,
        other_app = other_app,
        owner = owner,
        call = call,
        value = value,
        code = code,
        await = await,
        open_test_store = open_test_store,
        executed = executed,
        fault_value = fault_value,
        install_policy = install_policy,
        replace_approvers = replace_approvers,
        proposal = proposal,
        attempt_proposal = attempt_proposal,
        request_of = request_of,
        thread = thread,
        records_of = records_of,
        thread_records = thread_records,
        await_records = await_records,
        until_records = until_records,
        until_notices = until_notices,
        effect_wake = effect_wake,
        retire_owned_effects = retire_owned_effects,
        setup = setup,
    }
end

return {new = new}
