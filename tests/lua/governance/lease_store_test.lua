-- MIT. Lease persistence: bounded grant, atomic use, revocation and audit rows.
local test = require("test")
local uuid = require("uuid")
local store = require("lease_store")

type Object = {[string]: unknown}

local WIDE: Object = {capability = "workspace.files.write", template_revision = 1, operation = "files.write",
    resource = "workspace", scope = {subpath = "alpha"}, parameters = {subpath = "alpha"}}
local NARROW: Object = {capability = "workspace.files.write", template_revision = 1, operation = "files.write",
    resource = "workspace", scope = {subpath = "alpha/child"}, parameters = {subpath = "alpha/child"}}
local OUTSIDE: Object = {capability = "workspace.files.write", template_revision = 1, operation = "files.write",
    resource = "workspace", scope = {subpath = "beta"}, parameters = {subpath = "beta"}}

local function ok(result: Object): Object
    test.is_true(result.ok == true, tostring(result.code) .. ": " .. tostring(result.message))
    return result.value :: Object
end

local function grant_input(key: string, lease_id: string, approval: string, extra: Object?): Object
    local input: Object = {operation = "grant", idempotency_key = key, lease_id = lease_id, target = "bee.gov:overlay",
        envelope = {WIDE}, source_approval_id = approval, source_approval_proposal_digest = string.rep("a", 64),
        source_approval_owner_incarnation = 3, granted_by = "person-a", ttl_seconds = 3600}
    for name, value in pairs(extra or {}) do input[name] = value end
    return input
end

local function open(): store.Store
    return assert(store.open("bee.gov:activation_test_db", "node-lease", assert(uuid.v7())))
end

local function define_tests()
    test.describe("Governance lease store", function()
        test.it("refuses a lease with neither an expiry nor a use limit", function()
            local state = open()
            local input = grant_input("g-1", "lease-1", "approval-1")
            input.ttl_seconds = nil
            test.eq(store.call(state, "actor-a", input).code, "INVALID")
            assert(store.close(state))
        end)
        test.it("grants once per approval and replays an identical request", function()
            local state = open()
            local granted = ok(store.call(state, "actor-a", grant_input("g-1", "lease-1", "approval-1")))
            test.eq(granted.state, "active")
            test.eq(granted.revision, 1)
            test.eq(granted.applies_used, 0)
            local replayed = store.call(state, "actor-a", grant_input("g-1", "lease-1", "approval-1"))
            test.is_true(replayed.ok == true and replayed.replayed == true)
            local second = store.call(state, "actor-a", grant_input("g-2", "lease-2", "approval-1"))
            test.eq(second.code, "CONFLICT")
            assert(store.close(state))
        end)
        test.it("authorizes a contained proposal, counts the use and records its snapshot", function()
            local state = open()
            ok(store.call(state, "actor-a", grant_input("g-1", "lease-1", "approval-1", {max_applies = 2})))
            local used = ok(store.call(state, "actor-a", {operation = "use", idempotency_key = "u-1", lease_id = "lease-1",
                expected_revision = 1, intent_id = "intent-1", proposal_capabilities = {NARROW}}))
            test.eq(used.applies_used, 1)
            test.eq(used.revision, 2)
            local listed = ok(store.list(state, "bee.gov:overlay"))
            local leases = listed.leases :: {Object}
            test.eq(#(leases[1].uses :: {Object}), 1)
            assert(store.close(state))
        end)
        test.it("refuses a proposal outside the envelope without consuming the lease", function()
            local state = open()
            ok(store.call(state, "actor-a", grant_input("g-1", "lease-1", "approval-1")))
            local refused = store.call(state, "actor-a", {operation = "use", idempotency_key = "u-1", lease_id = "lease-1",
                expected_revision = 1, intent_id = "intent-1", proposal_capabilities = {NARROW, OUTSIDE}})
            test.eq(refused.code, "DENIED")
            test.eq(ok(store.get(state, "lease-1")).applies_used, 0)
            assert(store.close(state))
        end)
        test.it("stops authorizing after max_applies", function()
            local state = open()
            ok(store.call(state, "actor-a", grant_input("g-1", "lease-1", "approval-1", {max_applies = 1})))
            ok(store.call(state, "actor-a", {operation = "use", idempotency_key = "u-1", lease_id = "lease-1",
                expected_revision = 1, intent_id = "intent-1", proposal_capabilities = {NARROW}}))
            local again = store.call(state, "actor-a", {operation = "use", idempotency_key = "u-2", lease_id = "lease-1",
                expected_revision = 2, intent_id = "intent-2", proposal_capabilities = {NARROW}})
            test.eq(again.code, "DENIED")
            test.eq(ok(store.get(state, "lease-1")).state, "exhausted")
            assert(store.close(state))
        end)
        test.it("stops authorizing after expiry", function()
            local state = open()
            ok(store.call(state, "actor-a", grant_input("g-1", "lease-1", "approval-1")))
            assert(state.db:execute("UPDATE bee_governance_leases SET expires_at = '2000-01-01T00:00:00.000Z'"))
            local refused = store.call(state, "actor-a", {operation = "use", idempotency_key = "u-1", lease_id = "lease-1",
                expected_revision = 1, intent_id = "intent-1", proposal_capabilities = {NARROW}})
            test.eq(refused.code, "DENIED")
            test.eq(ok(store.get(state, "lease-1")).state, "expired")
            assert(store.close(state))
        end)
        test.it("fences a use after revocation and rejects a stale revision", function()
            local state = open()
            ok(store.call(state, "actor-a", grant_input("g-1", "lease-1", "approval-1")))
            local stale = store.call(state, "actor-a", {operation = "revoke", idempotency_key = "r-0", lease_id = "lease-1",
                expected_revision = 9, revoked_by = "person-a"})
            test.eq(stale.code, "CONFLICT")
            local revoked = ok(store.call(state, "actor-a", {operation = "revoke", idempotency_key = "r-1",
                lease_id = "lease-1", expected_revision = 1, revoked_by = "person-a"}))
            test.eq(revoked.state, "revoked")
            local refused = store.call(state, "actor-a", {operation = "use", idempotency_key = "u-1", lease_id = "lease-1",
                expected_revision = 2, intent_id = "intent-1", proposal_capabilities = {NARROW}})
            test.eq(refused.code, "DENIED")
            test.is_nil(store.find_active(state, "bee.gov:overlay", {NARROW}))
            assert(store.close(state))
        end)
        test.it("finds only an active lease that covers the proposal", function()
            local state = open()
            ok(store.call(state, "actor-a", grant_input("g-1", "lease-1", "approval-1")))
            test.is_true(store.find_active(state, "bee.gov:overlay", {NARROW}) ~= nil)
            test.is_nil(store.find_active(state, "bee.gov:overlay", {OUTSIDE}))
            test.is_nil(store.find_active(state, "bee.gov:other", {NARROW}))
            assert(store.close(state))
        end)
    end)
end
return test.run_cases(define_tests)
