-- MIT. A lease is proposed, decided as an ordinary approval, granted once and
-- then bounds later authorizations, through the real Approvals bindings.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local uuid = require("uuid")
local capability_model = require("capability_model")
local lease_grants = require("lease_grants")
local lease_store = require("lease_store")

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
local executor = {call = function(_self: any, target: string, input: unknown): (unknown?, unknown?)
    local result, problem = activation:call(target, input)
    return result, problem and tostring(problem) or nil
end}

local function install_policy()
    local entry = assert(registry.get("bee:approver_policies"))
    local data = entry.data :: Object
    local policies = data.policies :: {Object}
    for _, policy in ipairs(policies) do if policy.name == POLICY then return end end
    policies[#policies + 1] = {name = POLICY, approvers = {ALICE}, max_ttl_ms = 60000}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    assert(changes:apply())
end

local function ok(result: Object): Object
    test.is_true(result.ok == true, tostring(result.code) .. ": " .. tostring(result.message))
    return result.value :: Object
end

local function define_tests()
    test.describe("Lease grant flow", function()
        test.it("grants a lease from one decided approval and bounds its later use", function()
            install_policy()
            local vocabulary = assert(capability_model.decode(assert(registry.get("bee:capability_catalog"))))
            local installed = assert(capability_model.resolve(vocabulary, "workspace.files.write", {subpath = "alpha"}))
            local narrow = assert(capability_model.resolve(vocabulary, "workspace.files.write", {subpath = "alpha/child"}))
            local widened = assert(capability_model.resolve(vocabulary, "workspace.files.write", {subpath = "beta/child"}))
            local outside = assert(capability_model.resolve(vocabulary, "workspace.files.write", {subpath = "gamma"}))
            local workspace = "ws-lease-flow-" .. assert(uuid.v4())
            local profile = {overlay_owner = "bee.gov:lease-flow", approval_policy = POLICY, source_workspace = "app-a"}
            local db = assert(lease_store.open("bee.gov:activation_test_db", "node-lease-flow", workspace))

            local proposed = ok(lease_grants.propose(executor, vocabulary, installed, profile, workspace,
                {extras = {{capability = "workspace.files.write", parameters = {subpath = "beta"}}}, max_applies = 1}, "propose-1"))
            local approval = proposed.approval :: Object
            local approval_id, digest = approval.approval_id :: string, approval.proposal_digest :: string

            local early = lease_grants.grant(executor, db, vocabulary, profile, workspace, ACTOR, {approval_id = approval_id}, "grant-early")
            test.eq(early.code, "DENIED")

            local decided = alice:call("bee.approvals.binding:decide", {approval_id = approval_id,
                expected_revision = approval.revision, proposal_digest = digest, decision = "approved"})
            test.is_true((decided :: Object).ok == true)
            local granted = ok(lease_grants.grant(executor, db, vocabulary, profile, workspace, ACTOR,
                {approval_id = approval_id}, "grant-1"))
            test.eq(granted.state, "active")
            local again = lease_grants.grant(executor, db, vocabulary, profile, workspace, ACTOR,
                {approval_id = approval_id}, "grant-2")
            test.is_false(again.ok == true)

            local covered = lease_store.find_active(db, profile.overlay_owner, {narrow[1], widened[1]})
            test.is_true(covered ~= nil)
            test.is_nil(lease_store.find_active(db, profile.overlay_owner, {narrow[1], outside[1]}))
            local lease = covered :: Object
            ok(lease_store.call(db, ACTOR, {operation = "use", idempotency_key = "use-1", lease_id = lease.lease_id,
                expected_revision = lease.revision, intent_id = "intent-1", proposal_capabilities = {narrow[1], widened[1]}}))
            test.is_nil(lease_store.find_active(db, profile.overlay_owner, {narrow[1]}))
            test.eq(ok(lease_store.get(db, lease.lease_id :: string)).state, "exhausted")

            local second = ok(lease_grants.propose(executor, vocabulary, installed, profile, workspace,
                {ttl_seconds = 3600}, "propose-2")).approval :: Object
            alice:call("bee.approvals.binding:decide", {approval_id = second.approval_id,
                expected_revision = second.revision, proposal_digest = second.proposal_digest, decision = "approved"})
            local live = ok(lease_grants.grant(executor, db, vocabulary, profile, workspace, ACTOR,
                {approval_id = second.approval_id}, "grant-3"))
            test.is_true(lease_store.find_active(db, profile.overlay_owner, {narrow[1]}) ~= nil)
            ok(lease_store.call(db, ACTOR, {operation = "revoke", idempotency_key = "revoke-1", lease_id = live.lease_id,
                expected_revision = live.revision, revoked_by = ALICE}))
            test.is_nil(lease_store.find_active(db, profile.overlay_owner, {narrow[1]}))
            assert(lease_store.close(db))
        end)
    end)
end
return test.run_cases(define_tests)
