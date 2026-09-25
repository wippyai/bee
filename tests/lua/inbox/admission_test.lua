-- MIT. The inbox application's admitted scope, composed exactly as the
-- broker composes it from the base policies and the admission binding,
-- run in a spawned process: the approval store is denied before and after
-- an owner call, only the four owner methods answer and only under the
-- owner's own authorization, unlisted owner operations and the service
-- library stay out of reach, and the actor the process runs under decides
-- eligibility: a listed approver sees and decides, an actor the approver
-- policy does not list sees nothing and is refused, however admitted the
-- application is.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local REQUESTER, ALICE, STRANGER = "bee.test.inbox_requester", "bee.test.inbox_alice", "bee.test.inbox_stranger"
local POLICY = "inbox-test"
local SELECTOR_POLICY = "inbox-selector-test"
local BASE = {"bee.security:base_app_policy", "bee.security:app_boundary_policy", "bee.security:core_spawn_boundary", "bee.security.storage:workspace_storage_boundary"}
type Object = {[string]: unknown}
local function key(): string
    local id, err = uuid.v4()
    if err or not id then error("uuid: " .. tostring(err)) end
    return id
end
local function policies_of(names: {string}): {security.Policy}
    local list: {security.Policy} = {}
    for _, name in ipairs(names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        list[#list + 1] = policy
    end
    return list
end
-- The admitted scope, from the admission entry the broker reads.
local function admitted_scope(): security.Scope
    local entry = registry.get("bee.security:application_admission")
    if not entry then error("admission entry") end
    local names: {string} = {}
    for _, item in ipairs(BASE) do names[#names + 1] = item end
    local found = false
    for _, binding in ipairs((entry.data :: Object).bindings :: {Object}) do
        if binding.definition_id == "bee.inbox:app" then
            found = true
            for _, name in ipairs(binding.policies :: {string}) do names[#names + 1] = name end
        end
    end
    if not found then error("the inbox application is not admitted") end
    return security.new_scope(policies_of(names))
end
local function install_policy()
    local entry = registry.get("bee:approver_policies")
    if not entry then error("approver policies entry") end
    local data = entry.data :: Object
    local policies = data.policies :: {Object}
    local found_policy, found_selector = false, false
    for _, policy in ipairs(policies) do
        if policy.name == POLICY then found_policy = true end
        if policy.name == SELECTOR_POLICY then found_selector = true end
    end
    if found_policy and found_selector then return end
    if not found_policy then
        policies[#policies + 1] = {name = POLICY, approvers = {ALICE, "bee.test.inbox_bob"}, max_ttl_ms = 60000}
    end
    if not found_selector then
        policies[#policies + 1] = {name = SELECTOR_POLICY, approvers = {{definition_id = "bee.inbox:app"}}, max_ttl_ms = 60000}
    end
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("install approver policy: " .. tostring(err)) end
end
local function requester(): funcs.Executor
    return funcs.new():with_actor(security.new_actor(REQUESTER)):with_scope(security.new_scope(policies_of({"bee.inbox:client_test_policy", "bee.security.approvals:approval_request_policy"})))
end
local function file(workspace: string, policy: string?): string
    local reply, err = requester():call("bee.approvals.binding:request", {workspace_id = workspace, idempotency_key = key(), request_kind = "permission", policy = policy or POLICY,
        proposal = {kind = "attempt", ref = "attempt-" .. key(), revision = "r1", action_id = "action-1", payload = {tool_name = "Bash"}}, prompt = {text = "touch proof.txt"}})
    if err then error("request: " .. tostring(err)) end
    local typed = reply :: {ok: boolean, error: {code: string}?, value: Object}
    if not typed.ok then error("request: " .. tostring(typed.error and typed.error.code)) end
    return tostring(typed.value.approval_id)
end
-- probe: the process under the admitted scope as the given actor.
local function probe(actor: string, input: Object, metadata: Object?): Object
    local spawner = process.with_context({}):with_actor(security.new_actor(actor, metadata)):with_scope(admitted_scope())
    local pid, err = spawner:spawn_monitored("bee.inbox:admission_probe", "bee:workers", input)
    if not pid then error("spawn probe: " .. tostring(err)) end
    local events = assert(process.events())
    local deadline = time.after("30s")
    local report: Object? = nil
    while not report do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("probe did not finish") end
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == tostring(pid) then
            local result = event.result or {}
            if result.error then error("probe failed: " .. tostring(result.error)) end
            report = result.value :: Object
        end
    end
    return report :: Object
end
local function starts(value: unknown, prefix: string): boolean
    return tostring(value):sub(1, #prefix) == prefix
end
local function define_tests()
    test.describe("Inbox admission scope", function()
        install_policy()
        test.it("denies the approval store before and after owner calls and reaches only the four owner methods", function()
            local workspace = "ws-" .. key():sub(1, 8)
            local approval_id = file(workspace)
            local report = probe(ALICE, {workspace_id = workspace, approval_id = approval_id})
            test.is_true(starts(report.store_before, "denied"))
            test.eq(report.inbox, "ok")
            test.eq(report.visible, 1)
            test.eq(report.read, "ok")
            test.is_true(starts(report.list, "error"))
            test.is_true(starts(report.consume, "error"))
            test.is_true(starts(report.service, "error"))
            test.is_true(starts(report.store_after, "denied"))
        end)
        test.it("lets only an actor the approver policy lists see and decide, whatever the application's admission grants", function()
            local workspace = "ws-" .. key():sub(1, 8)
            local approval_id = file(workspace)
            local stranger = probe(STRANGER, {workspace_id = workspace, approval_id = approval_id, decide = true, decision = "approved"})
            test.eq(stranger.inbox, "ok")
            test.eq(stranger.visible, 0)
            test.eq(stranger.read, "refused: DENIED")
            test.eq(stranger.decide, "refused: DENIED")
            test.is_true(starts(stranger.store_after_decide, "denied"))
            local approver = probe(ALICE, {workspace_id = workspace, approval_id = approval_id, decide = true, decision = "denied"})
            test.eq(approver.visible, 1)
            test.eq(approver.decide, "ok")
            test.is_true(starts(approver.store_after_decide, "denied"))
            local record = requester():call("bee.approvals.binding:read", {approval_id = approval_id}) :: {ok: boolean, value: Object}
            test.eq(record.value.decision, "denied")
            test.eq(record.value.decider_id, ALICE)
        end)
        test.it("uses the host-selected definition selector, refusing a sibling and forged decision metadata", function()
            local workspace = "ws-" .. key():sub(1, 8)
            local approval_id = file(workspace, SELECTOR_POLICY)
            local workspace_id = string.rep("a", 32)
            local app_actor = "bee.application:" .. workspace_id .. ":inbox-instance"
            local app_metadata = {workspace_id = workspace_id, definition_id = "bee.inbox:app",
                definition_revision = "1", execution_generation = 1}
            local sibling = probe("bee.application:" .. workspace_id .. ":timeline-instance",
                {workspace_id = workspace, approval_id = approval_id},
                {workspace_id = workspace_id, definition_id = "bee.timeline:app",
                    definition_revision = "1", execution_generation = 1})
            test.eq(sibling.visible, 0)
            test.eq(sibling.read, "refused: DENIED")
            local forged = probe(app_actor,
                {workspace_id = workspace, approval_id = approval_id, decide = true, decision = "approved", forge = true},
                app_metadata)
            test.eq(forged.decide, "refused: INVALID")
            local approver = probe(app_actor, {workspace_id = workspace, approval_id = approval_id, decide = true, decision = "approved"}, app_metadata)
            test.eq(approver.visible, 1)
            test.eq(approver.decide, "ok")
            local record = requester():call("bee.approvals.binding:read", {approval_id = approval_id}) :: {ok: boolean, value: Object}
            test.eq(record.value.decider_id, app_actor)
        end)
    end)
end
return test.run_cases(define_tests)
