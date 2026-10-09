-- MIT. A lease is proposed, decided as an ordinary approval, granted once and
-- then bounds later authorizations, through the real Approvals bindings.
local test = require("test")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local uuid = require("uuid")
local bounds = require("bounds")
local capability_model = require("capability_model")
local lease_grants = require("lease_grants")
local lease_store = require("lease_store")
local service = require("service")

type Object = {[string]: unknown}
local ALICE, POLICY, ACTOR = "bee.test.lease_alice", "lease-flow-test", "bee.gov.activation"

local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
local activation = funcs.new():with_actor(security.new_actor(ACTOR))
    :with_scope(scope({"bee.security.approvals:approval_request_policy", "bee.security.approvals:approval_consume_policy"}))
local alice = funcs.new():with_actor(security.new_actor(ALICE))
    :with_scope(scope({"bee.security.approvals:approval_decide_policy", "bee.approvals:client_test_policy"}))
local executor: lease_grants.Executor = {call = function(_self: lease_grants.Executor, target: string, input: unknown): (unknown?, unknown?)
    local reply, problem = activation:call(target, input)
    local result = bounds.object(reply)
    return result, problem and tostring(problem) or nil
end}

local function install_policy()
    local entry = assert(registry.get("bee.security.approvals:approver_policies"))
    local data = assert(bounds.object(entry.data))
    local policies = principals.objects(data.policies)
    data.policies = policies
    for _, policy in ipairs(policies) do if policy.name == POLICY then return end end
    policies[#policies + 1] = {name = POLICY, approvers = {ALICE}, max_ttl_ms = 60000}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    assert(changes:apply())
end

local function ok(result: Object): Object
    test.is_true(result.ok == true, tostring(result.code) .. ": " .. tostring(result.message))
    return assert(bounds.object(result.value))
end

local function define_tests()
    test.describe("Lease grant flow", function()
        test.it("grants a lease from one decided approval and bounds its later use", function()
            install_policy()
            local vocabulary = assert(capability_model.decode(assert(registry.get("bee.capability:catalog"))))
            local installed = assert(capability_model.resolve(vocabulary, "workspace.files.write", {subpath = "alpha"}))
            local narrow = assert(capability_model.resolve(vocabulary, "workspace.files.write", {subpath = "alpha/child"}))
            local widened = assert(capability_model.resolve(vocabulary, "workspace.files.write", {subpath = "beta/child"}))
            local outside = assert(capability_model.resolve(vocabulary, "workspace.files.write", {subpath = "gamma"}))
            local workspace = "ws-lease-flow-" .. assert(uuid.v4())
            local profile = {overlay_owner = "bee.gov:lease-flow", approval_policy = POLICY, source_workspace = "app-a"}
            local db = assert(lease_store.open("bee:db", "node-lease-flow", workspace))

            local proposed = ok(lease_grants.propose(executor, vocabulary, installed, profile, workspace,
                {extras = {{capability = "workspace.files.write", parameters = {subpath = "beta"}}}, max_applies = 1}, "propose-1"))
            local approval = assert(bounds.object(proposed.approval))
            local approval_id, digest = approval.approval_id, approval.proposal_digest

            local early = lease_grants.grant(executor, db, vocabulary, profile, workspace, ACTOR, {approval_id = approval_id}, "grant-early")
            test.eq(early.code, "DENIED")

            local decided = alice:call("bee.approvals.binding:decide", {approval_id = approval_id,
                expected_revision = approval.revision, proposal_digest = digest, decision = "approved"})
            test.is_true((assert(bounds.object(decided))).ok == true)
            local granted = ok(lease_grants.grant(executor, db, vocabulary, profile, workspace, ACTOR,
                {approval_id = approval_id}, "grant-1"))
            test.eq(granted.state, "active")
            local again = lease_grants.grant(executor, db, vocabulary, profile, workspace, ACTOR,
                {approval_id = approval_id}, "grant-2")
            test.is_true(again.ok == true and again.replayed == true)
            test.eq((assert(bounds.object(again.value))).lease_id, granted.lease_id)

            local covered = lease_store.find_active(db, profile.overlay_owner, {narrow[1], widened[1]})
            test.is_true(covered ~= nil)
            test.is_nil(lease_store.find_active(db, profile.overlay_owner, {narrow[1], outside[1]}))
            local lease = assert(bounds.object(covered))
            ok(lease_store.call(db, ACTOR, {operation = "use", idempotency_key = "use-1", lease_id = lease.lease_id,
                expected_revision = lease.revision, intent_id = "intent-1", proposal_capabilities = {narrow[1], widened[1]}}))
            test.is_nil(lease_store.find_active(db, profile.overlay_owner, {narrow[1]}))
            test.eq(ok(lease_store.get(db, lease.lease_id)).state, "exhausted")

            local second = assert(bounds.object(ok(lease_grants.propose(executor, vocabulary, installed, profile, workspace,
                {ttl_seconds = 3600}, "propose-2")).approval))
            alice:call("bee.approvals.binding:decide", {approval_id = second.approval_id,
                expected_revision = second.revision, proposal_digest = second.proposal_digest, reviewed_digest = second.reviewed_digest, decision = "approved"})
            -- The approval owner restarts between the decision and the grant: the
            -- real owner answers REVALIDATE and the grant completes under the new incarnation.
            local store = assert(service.open())
            local restarted = assert(service.establish(store))
            store:release()
            test.is_true(restarted > (second.owner_incarnation))
            local live = ok(lease_grants.grant(executor, db, vocabulary, profile, workspace, ACTOR,
                {approval_id = second.approval_id}, "grant-3"))
            test.eq(live.source_approval_owner_incarnation, restarted)
            local retried = lease_grants.grant(executor, db, vocabulary, profile, workspace, ACTOR,
                {approval_id = second.approval_id}, "grant-3")
            test.is_true(retried.ok == true and retried.replayed == true)
            test.is_true(lease_store.find_active(db, profile.overlay_owner, {narrow[1]}) ~= nil)
            ok(lease_store.call(db, ACTOR, {operation = "revoke", idempotency_key = "revoke-1", lease_id = live.lease_id,
                expected_revision = live.revision, revoked_by = ALICE}))
            test.is_nil(lease_store.find_active(db, profile.overlay_owner, {narrow[1]}))
            assert(lease_store.close(db))
        end)
    end)
end
return test.run_cases(define_tests)
