-- MIT
local test = require("test")
local system = require("system")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local uuid = require("uuid")
local principals = require("principals")
local bounds = require("bounds")
local protocol = require("protocol")
local process = require("process")
local channel = require("channel")
local time = require("time")

type Object = {[string]: unknown}

local POLICY = "test-hive"
local PEER_PREFIX = "bee.approvals.peer."

local function key(): string
    local id, err = uuid.v4()
    if err or not id then error("uuid: " .. tostring(err)) end
    return id
end

local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end

local function caller(id: string, grants: {string}): funcs.Executor
    local names: {string} = {"bee.approvals:client_test_policy"}
    for _, grant in ipairs(grants) do names[#names + 1] = grant end
    return funcs.new():with_actor(security.new_actor(id)):with_scope(scope(names))
end

local requester = caller("bee.test.hive_requester", {"bee.security.approvals:approval_request_policy"})

local function direct(method: string, value: unknown): Object
    local reply, err = requester:call("bee.approvals.binding:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    local typed = principals.replayed_reply(reply)
    if not typed.ok then
        error(method .. ": " .. tostring(typed.error and typed.error.code) .. ": " .. tostring(typed.error and typed.error.message))
    end
    return assert(bounds.object(typed.value))
end

local function forward(op: string, args: Object): Object
    local reply, err = protocol.call(assert(system.node.id()), "approvals." .. op, args, "10s")
    if not reply then error(op .. ": " .. tostring(err)) end
    if not reply.ok then error(op .. " transport failed: " .. tostring(reply.error)) end
    return assert(bounds.object(reply.value))
end

local function code_of(answer: Object): string
    if answer.ok == true then error("expected a refusal, got success") end
    return tostring(assert(bounds.object(answer.error)).code)
end

local function install_policy(approvers: {unknown})
    local entry = registry.get("bee.security.approvals:approver_policies")
    if not entry then error("approver policies entry") end
    local data = assert(bounds.object(entry.data))
    local policies = principals.objects(data.policies)
    data.policies = policies
    local selected: Object? = nil
    for _, policy in ipairs(policies) do
        if policy.name == POLICY then selected = policy; break end
    end
    if selected then selected.approvers = approvers
    else policies[#policies + 1] = {name = POLICY, approvers = approvers, max_ttl_ms = 60000} end
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("install approver policy: " .. tostring(err)) end
end

local function request_of(workspace: string): Object
    return {workspace_id = workspace, idempotency_key = key(), request_kind = "permission", policy = POLICY,
        proposal = {kind = "operation", ref = "bee.harness.binding:start", revision = "r1", payload = {profile = "claude", argv = {"--print"}}},
        prompt = {text = "Launch claude in " .. workspace .. "?"}}
end

local function define_tests()
    test.describe("Approvals hive route", function()
        local node = assert(system.node.id())
        local peer = PEER_PREFIX .. node
        local workspace = "ws-hive-" .. key()
        install_policy({"bee.test.hive_nobody"})
        local created = direct("request", request_of(workspace))

        test.it("refuses operations the route does not map", function()
            local reply, err = protocol.call(node, "approvals.frobnicate", {}, "10s")
            if not reply then error("frobnicate: " .. tostring(err)) end
            test.is_false(reply.ok)
            test.contains(tostring(reply.error), "unknown approvals operation")
        end)

        test.it("reads and decides nothing for a peer the approver policy does not name", function()
            test.eq(code_of(forward("read", {approval_id = created.approval_id})), "DENIED")
            test.eq(code_of(forward("decide", {approval_id = created.approval_id, expected_revision = created.revision,
                proposal_digest = created.proposal_digest, decision = "approved"})), "DENIED")
            local snapshot = forward("feed_snapshot", {workspace_id = workspace, limit = 64})
            test.is_true(snapshot.ok == true)
            test.eq(#principals.items(assert(bounds.object(snapshot.value)).items), 0)
        end)

        test.it("does not accept a forwarded decision from a caller posing as the supervisor", function()
            local service = assert(process.registry.lookup("bee.approvals", process.registry.LOCAL))
            local topic = "bee.tests.approvals.reply." .. key()
            local replies = assert(process.listen(topic, {message = true}))
            assert(process.send(tostring(service), protocol.FORWARD, {op = "decide", caller = tostring(process.pid()),
                reply_topic = topic, expires = time.now():unix_nano() + 1000000000,
                args = {approval_id = created.approval_id, expected_revision = created.revision,
                    proposal_digest = created.proposal_digest, decision = "approved"}}))
            local deadline = time.after("100ms")
            local selected = channel.select({replies:case_receive(), deadline:case_receive()})
            process.unlisten(replies)
            test.eq(selected.channel, deadline)
        end)

        test.it("serves an inbox read and decide through the supervisor as the authenticated peer", function()
            install_policy({peer})
            local seen = forward("read", {approval_id = created.approval_id})
            test.is_true(seen.ok == true)
            test.eq(assert(bounds.object(seen.value)).state, "pending")
            local snapshot = forward("feed_snapshot", {workspace_id = workspace, limit = 64})
            test.is_true(snapshot.ok == true)
            test.eq(#principals.items(assert(bounds.object(snapshot.value)).items), 1)
            test.eq(code_of(forward("decide", {approval_id = created.approval_id, expected_revision = created.revision,
                proposal_digest = string.rep("0", 64), decision = "approved"})), "CONFLICT")
            test.eq(code_of(forward("decide", {approval_id = created.approval_id, expected_revision = 9,
                proposal_digest = created.proposal_digest, decision = "approved"})), "CONFLICT")
            local settled = forward("decide", {approval_id = created.approval_id, expected_revision = created.revision,
                proposal_digest = created.proposal_digest, decision = "approved"})
            test.is_true(settled.ok == true)
            test.eq(assert(bounds.object(settled.value)).decision, "approved")
            test.eq(assert(bounds.object(settled.value)).decider_id, peer)
            local replayed = forward("decide", {approval_id = created.approval_id, expected_revision = created.revision,
                proposal_digest = created.proposal_digest, decision = "approved"})
            test.is_true(replayed.ok == true)
            test.is_true(replayed.replayed == true)
        end)

        test.it("settles a remote batch in one owner transaction", function()
            local first = direct("request", request_of(workspace))
            local second = direct("request", request_of(workspace))
            local settled = forward("decide_batch", {decisions = {
                {approval_id = first.approval_id, expected_revision = first.revision,
                    proposal_digest = first.proposal_digest, decision = "approved"},
                {approval_id = second.approval_id, expected_revision = second.revision,
                    proposal_digest = second.proposal_digest, decision = "denied"}}})
            test.is_true(settled.ok == true)
            local views = principals.objects(assert(bounds.object(settled.value)).decisions)
            test.eq(#views, 2)
            test.eq(views[1].decision, "approved")
            test.eq(views[2].decision, "denied")
        end)

        test.it("keeps withdrawal with the requester", function()
            test.eq(code_of(forward("withdraw", {approval_id = created.approval_id})), "DENIED")
        end)

        test.it("lists and revokes only windows owned by the destination-authorized peer", function()
            local pending = direct("request", request_of(workspace))
            local settled = forward("decide", {approval_id = pending.approval_id, expected_revision = pending.revision,
                proposal_digest = pending.proposal_digest, decision = "approved", window_ttl_ms = 30000})
            test.is_true(settled.ok == true)
            local grant = assert(bounds.object(assert(bounds.object(settled.value)).window_grant))
            local listed = forward("grant_window", {operation = "list", workspace_id = workspace})
            test.is_true(listed.ok == true)
            test.eq(#principals.items(assert(bounds.object(listed.value)).grants), 1)
            local revoked = forward("grant_window", {operation = "revoke", grant_id = grant.grant_id})
            test.is_true(revoked.ok == true)
            test.is_true(assert(bounds.object(revoked.value)).revoked == true)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
