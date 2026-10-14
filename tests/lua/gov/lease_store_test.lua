-- MIT. Lease persistence: bounded grant, atomic use, revocation and audit rows.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local uuid = require("uuid")
local store = require("lease_store")
local common_grants = require("common_grants")
local clock = require("clock")

type Object = {[string]: unknown}

local WIDE: Object = {capability = "workspace.files.write", template_revision = 1, operation = "files.write",
    resource = "workspace", scope = {subpath = "alpha"}, parameters = {subpath = "alpha"}}
local NARROW: Object = {capability = "workspace.files.write", template_revision = 1, operation = "files.write",
    resource = "workspace", scope = {subpath = "alpha/child"}, parameters = {subpath = "alpha/child"}}
local OUTSIDE: Object = {capability = "workspace.files.write", template_revision = 1, operation = "files.write",
    resource = "workspace", scope = {subpath = "beta"}, parameters = {subpath = "beta"}}

local function ok(result: Object): Object
    test.is_true(result.ok == true, tostring(result.code) .. ": " .. tostring(result.message))
    return assert(bounds.object(result.value))
end

local function grant_input(key: string, lease_id: string, approval: string, extra: Object?): Object
    local input: Object = {operation = "grant", idempotency_key = key, lease_id = lease_id, target = "bee.gov:overlay",
        envelope = {WIDE}, source_approval_id = approval, source_approval_proposal_digest = string.rep("a", 64),
        source_approval_owner_incarnation = 3, granted_by = "person-a", ttl_seconds = 3600}
    for name, value in pairs(extra or {}) do input[name] = value end
    return input
end

local function open(): store.Store
    return assert(store.open("bee:db", "node-lease", assert(uuid.v7())))
end

local function define_tests()
    test.describe("Governance lease store", function()
        test.it("stores authority on common grants and central revocation fences a reserved use", function()
            local state = open()
            local granted = ok(store.call(state,"actor-a",grant_input("g-common","lease-common","approval-common")))
            local rows = assert(state.db:query("SELECT * FROM bee_approval_grants WHERE workspace_id = ? AND domain = 'governance_lease'",{state.workspace}))
            test.eq(#rows,1)
            test.eq(rows[1].granted_by,"person-a")
            test.eq(granted.grant_id,rows[1].grant_id)
            ok(store.call(state,"actor-a",{operation = "use",idempotency_key = "u-common",lease_id = "lease-common",expected_revision = 1,intent_id = "intent-common",proposal_capabilities = {NARROW}}))
            rows = assert(state.db:query("SELECT used,reserved FROM bee_approval_grants WHERE grant_id = ?",{granted.grant_id}))
            test.eq(rows[1].used,0)
            test.eq(rows[1].reserved,1)
            local tx = assert(state.db:begin())
            local authority = assert(common_grants.read(tx,assert(bounds.id(granted.grant_id))))
            assert(not common_grants.revoke(tx,authority,authority.revision,"person-a",clock.milliseconds()))
            assert(tx:commit())
            test.eq(assert(state.db:query("SELECT state FROM bee_approval_grant_uses WHERE grant_id = ?",{granted.grant_id}))[1].state,"fenced")
            tx = assert(state.db:begin())
            local refused = store.admit_in(tx,state,"intent-common","approval-common",string.rep("a",64))
            test.eq(refused and refused.code,"DENIED")
            assert(tx:rollback())
            assert(store.close(state))
        end)
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
            local leases = principals.objects(listed.leases)
            test.eq(#(principals.objects(leases[1].uses)), 1)
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
            assert(state.db:execute("UPDATE bee_approval_grants SET until_ms = 1"))
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
        test.it("lists leases able to authorize and keeps ended history out of the way", function()
            local state = open()
            ok(store.call(state, "actor-a", grant_input("g-1", "lease-1", "approval-1")))
            ok(store.call(state, "actor-a", grant_input("g-2", "lease-2", "approval-2", {max_applies = 1})))
            ok(store.call(state, "actor-a", {operation = "revoke", idempotency_key = "r-1", lease_id = "lease-2",
                expected_revision = 1, revoked_by = "person-a"}))
            local active = principals.objects(ok(store.list(state, nil)).leases)
            test.eq(#active, 1)
            test.eq(active[1].lease_id, "lease-1")
            local history = principals.objects(ok(store.list(state, nil, true)).leases)
            test.eq(#history, 1)
            test.eq(history[1].state, "revoked")
            test.eq(ok(store.by_approval(state, "approval-2")).lease_id, "lease-2")
            test.eq(store.by_approval(state, "approval-none").code, "NOT_FOUND")
            assert(store.close(state))
        end)
        test.it("counts only active leases against capacity", function()
            local state = open()
            for index = 1, 3 do
                local granted = ok(store.call(state, "actor-a", grant_input("g-" .. index, "lease-" .. index, "approval-" .. index)))
                ok(store.call(state, "actor-a", {operation = "revoke", idempotency_key = "r-" .. index, lease_id = "lease-" .. index,
                    expected_revision = granted.revision, revoked_by = "person-a"}))
            end
            ok(store.call(state, "actor-a", grant_input("g-4", "lease-4", "approval-4")))
            assert(store.close(state))
        end)
        test.it("keeps an exhausted lease with a pending reservation listed and revocable", function()
            local state = open()
            ok(store.call(state, "actor-a", grant_input("g-1", "lease-1", "approval-1", {max_applies = 1})))
            ok(store.call(state, "actor-a", {operation = "use", idempotency_key = "u-1", lease_id = "lease-1",
                expected_revision = 1, intent_id = "intent-1", proposal_capabilities = {NARROW}}))
            local listed = principals.objects(ok(store.list(state, nil)).leases)
            test.eq(#listed, 1)
            test.eq(listed[1].state, "exhausted")
            local uses = principals.objects(listed[1].uses)
            test.eq(uses[1].state, "reserved")
            local revoked = ok(store.call(state, "actor-a", {operation = "revoke", idempotency_key = "r-1", lease_id = "lease-1",
                expected_revision = listed[1].revision, revoked_by = "person-a"}))
            test.eq((principals.strings(revoked.fenced_intents))[1], "intent-1")
            test.eq(#(principals.objects(ok(store.list(state, nil)).leases)), 0)
            assert(store.close(state))
        end)
        test.it("replays a lost revocation reply with the fenced and started intents", function()
            local state = open()
            ok(store.call(state, "actor-a", grant_input("g-1", "lease-1", "approval-1", {max_applies = 3})))
            local used = ok(store.call(state, "actor-a", {operation = "use", idempotency_key = "u-1", lease_id = "lease-1",
                expected_revision = 1, intent_id = "intent-1", proposal_capabilities = {NARROW}}))
            local request = {operation = "revoke", idempotency_key = "r-1", lease_id = "lease-1",
                expected_revision = used.revision, revoked_by = "person-a"}
            local first = ok(store.call(state, "actor-a", request))
            local again = store.call(state, "actor-a", request)
            test.is_true(again.ok == true and again.replayed == true)
            local value = assert(bounds.object(again.value))
            test.eq((principals.strings(value.fenced_intents))[1], "intent-1")
            test.eq(#(principals.strings(value.started_effects)), #(principals.strings(first.started_effects)))
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
