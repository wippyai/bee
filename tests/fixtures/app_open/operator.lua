-- SPDX-License-Identifier: MIT
-- The fixture's human-side operator. It is deliberately separate from the
-- seed's MCP subject: it reads the durable approval inbox and decides only
-- the exact runtime-trait request for the signalled thread.
local process = require("process")
local channel = require("channel")
local time = require("time")
local funcs = require("funcs")
local bounds = require("bounds")
local json = require("json")
local registry = require("registry")
local thread_binding = require("thread_binding")

type Object = {[string]: unknown}

local NAME = "bee.app.open.probe:operator"
local SIGNAL = "bee.app.open.probe.operator.signal"
local POLICY = "app-open-runtime"
local THREAD = "open-probe-thread"
local AGENT = "bee.app.open.probe:managed_agent"
local APPLICATION = "bee.app_journey_demo:app"
local RESULT = "bee.app.open.probe.operator.result"
local RECHECK = "bee.app.journey.probe.recheck"
local RECHECK_RESULT = "bee.app.journey.probe.recheck.result"
local CREDENTIALS = "bee.app.open.probe.credentials"
local CREDENTIALS_GET = "bee.app.open.probe.credentials.get"
local CREDENTIALS_RESULT = "bee.app.open.probe.credentials.result"
local ACCESS_REVOKE = "bee.app.open.probe.access.revoke"
local ACCESS_REVOKE_RESULT = "bee.app.open.probe.access.revoke.result"

local function object(value: unknown): Object?
    return bounds.object(value)
end

local function call(target: string, request: Object): (Object?, string?)
    local raw, call_error = funcs.call(target, request)
    if call_error then return nil, tostring(call_error) end
    local reply = object(raw)
    if not reply then return nil, "missing reply from " .. target end
    if reply.ok ~= true then return nil, tostring(reply.error or reply.message or "operation refused") end
    local value = object(reply.value)
    if not value then return nil, "missing value from " .. target end
    return value, nil
end

local function open_gateway()
    local selected, address_error = funcs.call("bee.gateway:address", {})
    local endpoint = object(selected)
    if address_error or not endpoint or type(endpoint.address) ~= "string" then
        error("resolve managed gateway: " .. tostring(address_error or "missing address"))
    end
    local opened, open_error = call("bee.gateway.binding:open", {address = endpoint.address})
    if not opened then error("open managed gateway: " .. tostring(open_error)) end
end

local function exact_request(request: Object, workspace_id: string, thread_id: string, actor_id: string,
    action_id: string, attempt_id: string): string?
    if request.workspace_id ~= workspace_id or request.policy ~= POLICY or request.request_kind ~= "permission"
        or request.requester_id ~= actor_id or request.thread_id ~= thread_id or request.state ~= "pending" then
        return "request envelope differs"
    end
    local proposal = object(request.proposal)
    local payload = proposal and object(proposal.payload)
    local traits = payload and bounds.ids(payload.traits, true)
    if not proposal or not payload or proposal.kind ~= "attempt" or proposal.revision ~= "bee.mcp-access@1"
        or proposal.action_id ~= action_id or proposal.ref ~= attempt_id or not traits or #traits ~= 1
        or traits[1] ~= "bee.application:runtime" then
        return "proposal differs"
    end
    if bounds.fields(payload, {"binding_id", "subject", "thread_id", "configuration_digest", "traits", "fixed_context"})
        or payload.subject ~= actor_id or payload.thread_id ~= thread_id or not bounds.id(payload.binding_id)
        or type(payload.configuration_digest) ~= "string" or #(payload.configuration_digest :: string) ~= 64
        or not (payload.configuration_digest :: string):match("^[0-9a-f]+$")
        or type(payload.fixed_context) ~= "table" then
        return "proposal payload differs"
    end
    return nil
end

local function carrier_report(): string
    local page = call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 64})
    local records = page and page.records
    if type(records) ~= "table" then return "no error" end
    for _, raw in ipairs(records :: {unknown}) do
        local record = object(raw)
        local body = record and object(record.body)
        local data = body and object(body.data)
        local content = data and object(data.content)
        if data and data.code == "stderr" and content and type(content.text) == "string" then
            return content.text :: string
        end
    end
    return "no error"
end

local function approve(workspace_id: string, thread_id: string, actor_id: string, action_id: string,
    attempt_id: string, carrier: string): (boolean, string?)
    local events = assert(process.events())
    local cursor = 0
    local deadline = time.after("60s")
    while true do
        local tick = time.after("100ms")
        local selected = channel.select({events:case_receive(), tick:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then return false, "operator approval timed out" end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then return false, "operator was cancelled" end
            if selected.value.kind == process.event.EXIT and tostring(selected.value.from) == carrier then
                local result = selected.value.result
                return false, "managed application opener exited before approval: "
                    .. tostring(result and result.error or carrier_report())
            end
        else
            local inbox, inbox_error = call("bee.approvals.binding:inbox", {workspace_id = workspace_id, after_seq = cursor, limit = 64})
            if inbox then
                local changes = inbox.changes
                if type(changes) ~= "table" then return false, "approval inbox changes are missing" end
                for _, raw in ipairs(changes :: {unknown}) do
                    local change = object(raw)
                    local request = change and object(change.request)
                    if request and request.workspace_id == workspace_id and request.policy == POLICY and request.state == "pending" then
                        local mismatch = exact_request(request, workspace_id, thread_id, actor_id, action_id, attempt_id)
                        if mismatch then
                            return false, "operator found an unexpected app-open approval request (" .. mismatch .. "): " .. json.encode(request)
                                .. " expected=" .. json.encode({workspace_id = workspace_id, thread_id = thread_id,
                                    actor_id = actor_id, action_id = action_id, attempt_id = attempt_id})
                        end
                        local decided, decide_error = call("bee.approvals.binding:decide", {
                            approval_id = request.approval_id, expected_revision = request.revision,
                            proposal_digest = request.proposal_digest, decision = "approved"})
                        if not decided then return false, "decide app-open approval: " .. tostring(decide_error) end
                        return true, nil
                    end
                end
                local next_cursor = bounds.count(inbox.next_seq)
                if not next_cursor then return false, "approval inbox cursor is missing" end
                cursor = next_cursor
            elseif inbox_error and inbox_error ~= "disconnected" then
                -- The authority may still be booting with the disposable
                -- fixture. Keep the bounded retry; a persistent failure is
                -- reported by the timeout with its original cause omitted.
            end
        end
        tick = nil
    end
    return false, "operator stopped"
end

local function start_agent(workspace_id: string, view_id: string, instance_id: string): Object
    open_gateway()
    local created, create_error = call("bee.threads.service:create", {thread_id = THREAD,
        idempotency_key = "create-open-probe-thread", title = "Open Probe Thread"})
    if not created then error("create application thread: " .. tostring(create_error)) end
    if created.thread_id ~= THREAD or created.owner_id ~= "bee.app_open.operator" then
        error("application thread has the wrong owner")
    end
    local owner_view, owner_error = funcs.call("bee.threads.service:get", {thread_id = THREAD})
    local application_actor = thread_binding.actor(workspace_id, instance_id)
    local head = application_actor and thread_binding.owner_get(owner_view, {instance_id = instance_id,
        thread_id = THREAD, actor_id = application_actor, role = "participant",
        initiating_owner_id = "bee.app_open.operator"}, workspace_id)
    if not head then
        error("application thread owner proof failed: " .. tostring(owner_error) .. " " .. json.encode(owner_view))
    end
    local plan, plan_error = call("bee.harness.launch:resolve", {definition_ref = AGENT})
    if not plan then error("resolve managed application opener: " .. tostring(plan_error)) end
    local started, start_error = call("bee.harness.launch:start", {request_id = "managed-app-open",
        definition_ref = AGENT, workspace_id = workspace_id, thread_id = THREAD,
        brief = "Open the reviewed application through your scoped Bee MCP tools.",
        expected_plan_digest = plan.plan_digest, origin_view = {view_id = view_id, instance_id = instance_id}})
    if not started then error("start managed application opener: " .. tostring(start_error)) end
    return started
end

local function wait_carrier(pid: string)
    local events = assert(process.events())
    local deadline = time.after("60s")
    while true do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("managed application opener did not finish") end
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == pid then
            if event.result and event.result.error then error("managed application opener failed: " .. tostring(event.result.error)) end
            return
        end
        if event.kind == process.event.CANCEL then error("operator was cancelled") end
    end
end

local function await_proofs(workspace_id: string, action_id: string, attempt_id: string): Object
    local cursor = 0
    local managed: Object? = nil
    local applications: {[string]: Object} = {}
    for _ = 1, 200 do
        local page, page_error = call("bee.threads.service:read_after", {thread_id = THREAD, cursor = cursor, limit = 64})
        if not page then error("read application thread: " .. tostring(page_error)) end
        local records = page.records
        if type(records) ~= "table" then error("application thread records are missing") end
        for _, raw in ipairs(records :: {unknown}) do
            local record = object(raw)
            local body = record and object(record.body)
            local content = body and object(body.content)
            if record and body and content and record.kind == "message" and record.thread_id == THREAD
                and type(content.text) == "string" then
                local decoded = object(json.decode(content.text))
                if body.message_id == "managed-app-open-proof" and record.producer_id == "bee.app_open.operator"
                    and record.action_id == action_id and record.attempt_id == attempt_id and decoded
                    and decoded.schema == "managed-app-open.v1" then managed = decoded end
                if decoded and decoded.schema == "app-thread-proof.v1" then
                    local expected = "bee.application:" .. workspace_id .. ":" .. tostring(decoded.instance_id)
                    if record.producer_id == expected and body.sender_id == expected and decoded.thread_id == THREAD
                        and decoded.subscribe == "ok" and decoded.post == "ok" and decoded.read == "ok"
                        and decoded.page == "ok" and decoded.ack_page == "ok" then
                        applications[tostring(decoded.instance_id)] = decoded
                    end
                end
            end
        end
        local first = managed and applications[tostring(managed.first_instance)] or nil
        local second = managed and applications[tostring(managed.second_instance)] or nil
        if managed and first and second then
            local window_instance = bounds.id(managed.window_instance)
            local window_view = bounds.id(managed.window_view)
            if managed.first_instance == managed.second_instance or managed.first_view == managed.second_view
                or managed.unapproved_refused ~= true
                or managed.selected ~= true or not bounds.id(managed.approval_id)
                or managed.window_definition ~= "bee.harness.window:app" or not window_instance or not window_view then
                error("managed application proof does not match the opened apps")
            end
            return {approval_id = managed.approval_id, first_view = managed.first_view, second_view = managed.second_view,
                first_instance = managed.first_instance, second_instance = managed.second_instance,
                window_view = window_view, window_instance = window_instance,
                unapproved_refused = managed.unapproved_refused, agent_exited = true,
                managed_proof = managed, first_thread_proof = first, second_thread_proof = second}
        end
        if page.has_more == true then
            local next_cursor = bounds.count(page.scanned_through)
            if not next_cursor or next_cursor <= cursor then error("application thread page did not advance") end
            cursor = next_cursor
        else time.sleep("25ms") end
    end
    local proof_count = 0
    for _ in pairs(applications) do proof_count = proof_count + 1 end
    error("managed agent or application thread proof did not arrive: managed=" .. tostring(managed ~= nil)
        .. " applications=" .. tostring(proof_count) .. " carrier=" .. carrier_report())
end

local function revoke_first_and_recheck(workspace_id: string, proof: Object): Object
    local first = object(proof.first_thread_proof)
    local second = object(proof.second_thread_proof)
    local first_instance, second_instance = first and bounds.id(first.instance_id), second and bounds.id(second.instance_id)
    local first_pid, second_pid = first and bounds.id(first.execution_pid), second and bounds.id(second.execution_pid)
    if not first_instance or not second_instance or not first_pid or not second_pid then
        error("application recheck identities are missing")
    end
    local owner = assert(call("bee.threads.service:get", {thread_id = THREAD}))
    local summary = object(owner.summary)
    local revision = summary and bounds.count(summary.revision)
    if not revision or revision < 1 then error("application thread head is missing") end
    local actor = assert(thread_binding.actor(workspace_id, first_instance))
    local left, leave_error = call("bee.threads.service:leave", {thread_id = THREAD,
        idempotency_key = "remove-first-application", member_id = actor, expected_revision = revision})
    if not left then error("remove first application member: " .. tostring(leave_error)) end

    local replies = assert(process.listen(RECHECK_RESULT, {message = true}))
    assert(process.send(first_pid, RECHECK, {}))
    assert(process.send(second_pid, RECHECK, {}))
    local found: {[string]: Object} = {}
    local deadline = time.after("10s")
    while not found[first_instance] or not found[second_instance] do
        local selected = channel.select({replies:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then
            process.unlisten(replies)
            error("application membership rechecks timed out")
        end
        local value = object(selected.value:payload():data())
        local instance_id = value and bounds.id(value.instance_id)
        if instance_id and (tostring(selected.value:from()) == first_pid or tostring(selected.value:from()) == second_pid) then
            found[instance_id] = value
        end
    end
    process.unlisten(replies)
    if found[first_instance].access ~= "denied" or found[first_instance].code ~= "DENIED"
        or found[second_instance].access ~= "active" or found[second_instance].code ~= "" then
        error("application membership rechecks differ: " .. json.encode(found))
    end
    proof.removed_instance = first_instance
    proof.surviving_instance = second_instance
    proof.removed_actor = actor
    proof.removed_access = "denied"
    proof.surviving_access = "active"
    return proof
end

local function execute(workspace_id: string, view_id: string, instance_id: string): Object
    local started = start_agent(workspace_id, view_id, instance_id)
    local action_id, attempt_id = bounds.id(started.action_id), bounds.id(started.attempt_id)
    local carrier = bounds.id(started.carrier)
    if not action_id or not attempt_id or not carrier or started.thread_id ~= THREAD then
        error("managed application opener returned incomplete identity")
    end
    local monitored, monitor_error = process.monitor(carrier)
    if not monitored then error("monitor managed carrier: " .. tostring(monitor_error)) end
    local approved, approval_error = approve(workspace_id, THREAD, "bee.app_open.operator", action_id, attempt_id, carrier)
    if not approved then error(tostring(approval_error or "app-open approval failed")) end
    wait_carrier(carrier)
    return revoke_first_and_recheck(workspace_id, await_proofs(workspace_id, action_id, attempt_id))
end

local function main()
    local registered, register_error = process.registry.register(NAME)
    if not registered then error("register app-open operator: " .. tostring(register_error)) end
    local signals = assert(process.listen(SIGNAL, {message = true}))
    local credentials = assert(process.listen(CREDENTIALS, {message = true}))
    local credential_requests = assert(process.listen(CREDENTIALS_GET, {message = true}))
    local access_revocations = assert(process.listen(ACCESS_REVOKE, {message = true}))
    local events = assert(process.events())
    local completed: {[string]: boolean} = {}
    local saved_credentials: {[string]: Object} = {}
    while true do
        local selected = channel.select({signals:case_receive(), credentials:case_receive(),
            credential_requests:case_receive(), access_revocations:case_receive(), events:case_receive()})
        if not selected.ok then break end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then break end
        elseif selected.channel == credentials or selected.channel == credential_requests then
            local recipient = tostring(selected.value:from())
            local value = object(selected.value:payload():data())
            local instance_id = value and bounds.id(value.instance_id)
            if not instance_id then error("app-open operator received invalid credential signal") end
            if selected.channel == credentials then
                local launch_token = value and bounds.id(value.launch_token)
                local execution_generation = value and bounds.count(value.execution_generation)
                if not launch_token or not execution_generation or execution_generation < 1 then
                    error("app-open operator received invalid launch credentials")
                end
                local previous = saved_credentials[instance_id]
                saved_credentials[instance_id] = {instance_id = instance_id, launch_token = launch_token,
                    execution_generation = execution_generation,
                    previous_launch_token = previous and previous.launch_token or nil,
                    previous_execution_generation = previous and previous.execution_generation or nil,
                    execution_pid = recipient}
            else
                local saved = saved_credentials[instance_id]
                if saved then
                    assert(process.send(recipient, CREDENTIALS_RESULT, {instance_id = instance_id,
                        launch_token = saved.launch_token, execution_generation = saved.execution_generation,
                        previous_launch_token = saved.previous_launch_token,
                        previous_execution_generation = saved.previous_execution_generation}))
                else
                    assert(process.send(recipient, CREDENTIALS_RESULT, {instance_id = instance_id, error = "credentials unavailable"}))
                end
            end
        elseif selected.channel == access_revocations then
            local recipient = tostring(selected.value:from())
            local value = object(selected.value:payload():data())
            local instance_id = value and bounds.id(value.instance_id)
            local saved = instance_id and saved_credentials[instance_id] or nil
            if not instance_id or not saved or saved.execution_pid ~= recipient then
                error("access revocation sender is not the current application execution")
            end
            local entry = assert(registry.get("bee.security:application_admission"))
            local data = object(entry.data)
            local bindings = data and data.bindings
            if type(bindings) ~= "table" then error("application admission bindings are unavailable") end
            local found = false
            for _, raw in ipairs(bindings :: {unknown}) do
                local binding = object(raw)
                if binding and binding.definition_id == APPLICATION then
                    binding.thread_access = "none"; found = true
                end
            end
            if not found then error("journey application admission is unavailable") end
            local changes = registry.snapshot():changes()
            assert(changes:update(entry))
            local applied, apply_error = changes:apply()
            if not applied then error("revoke application access: " .. tostring(apply_error)) end
            assert(process.send(recipient, ACCESS_REVOKE_RESULT, {instance_id = instance_id, ok = true}))
        else
            local recipient = tostring(selected.value:from())
            local value = object(selected.value:payload():data())
            local workspace_id = value and bounds.id(value.workspace_id)
            local view_id = value and bounds.id(value.view_id)
            local instance_id = value and bounds.id(value.instance_id)
            if not workspace_id or not view_id or not instance_id or not recipient then
                error("app-open operator received an invalid signal")
            end
            local key = workspace_id .. ":" .. view_id
            if not completed[key] then
                local ok, outcome = pcall(execute, workspace_id, view_id, instance_id)
                local proof: Object = ok and (outcome :: Object) or {error = tostring(outcome)}
                proof.workspace_id = workspace_id
                local delivered, delivery_error = process.send(recipient, RESULT, proof)
                if not delivered then error("deliver app-open result: " .. tostring(delivery_error)) end
                if ok then completed[key] = true end
            end
        end
    end
    process.unlisten(signals)
    process.unlisten(credentials)
    process.unlisten(credential_requests)
    process.unlisten(access_revocations)
    process.registry.unregister(NAME, process.registry.LOCAL)
end

return {main = main}
