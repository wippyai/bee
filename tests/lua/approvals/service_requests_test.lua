-- MIT. Approval service requests.
local test = require("test")
local events = require("events")
local principals = require("principals")
local bounds = require("bounds")
local json = require("json")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local time = require("time")
local service = require("service")
local resources = require("resources")
local schema = require("schema")
local fixture = require("fixture").new()
local REQUESTER = fixture.REQUESTER
local ALICE = fixture.ALICE
local BOB = fixture.BOB
local POLICY = fixture.POLICY
local key = fixture.key
local scope = fixture.scope
local caller = fixture.caller
local requester = fixture.requester
local other_requester = fixture.other_requester
local alice = fixture.alice
local bob = fixture.bob
local carol = fixture.carol
local outsider = fixture.outsider
local INBOX_ACTOR = fixture.INBOX_ACTOR
local inbox_app = fixture.inbox_app
local other_app = fixture.other_app
local call = fixture.call
local value = fixture.value
local code = fixture.code
local open_test_store = fixture.open_test_store
local executed = fixture.executed
local replace_approvers = fixture.replace_approvers
local proposal = fixture.proposal
local request_of = fixture.request_of
local retire_owned_effects = fixture.retire_owned_effects

local function define_tests()
    test.describe("Approval owner requests", function()
        fixture.setup("bee.tests.approvals:service_requests_db", true)
        test.after_all(retire_owned_effects)
        test.it("exports pinned snapshots and scoped catch-up from the existing approval ledger", function()
            local workspace = "ws-feed-" .. key()
            local created = value(call(requester, "request", request_of(workspace)))
            value(call(requester, "request", request_of(workspace)))
            test.eq(code(call(outsider, "feed_snapshot", {workspace_id = workspace})), "DENIED")
            local first = value(call(alice, "feed_snapshot", {workspace_id = workspace, limit = 1}))
            test.eq(first.schema, "bee.sync-snapshot@1")
            test.eq(first.complete, false)
            test.eq(first.reset_required, false)
            local tail = value(call(alice, "feed_snapshot", {workspace_id = workspace, limit = 1,
                after_key = first.next_key, expected_cursor = first.cursor, expected_scope_revision = first.scope_revision}))
            test.eq(tail.complete, true)
            test.eq(tail.reset_required, false)
            local empty = value(call(alice, "feed_read_after", {workspace_id = workspace, cursor = first.cursor,
                expected_scope_revision = first.scope_revision}))
            test.eq(#(principals.items(empty.events)), 0)
            value(call(alice, "decide", {approval_id = created.approval_id, expected_revision = created.revision,
                proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "approved"}))
            test.eq(code(call(alice, "feed_snapshot", {workspace_id = workspace, limit = 1,
                after_key = first.next_key, expected_cursor = first.cursor, expected_scope_revision = first.scope_revision})), "RESET_REQUIRED")
            local changed = value(call(alice, "feed_read_after", {workspace_id = workspace, cursor = first.cursor,
                expected_scope_revision = first.scope_revision}))
            local events = principals.objects(changed.events)
            test.eq(#events, 1)
            test.eq(events[1].event_type, "approval.changed")
            test.eq(events[1].projection_key, created.approval_id)
            test.eq(code(call(alice, "feed_read_after", {workspace_id = workspace, cursor = first.cursor,
                expected_scope_revision = string.rep("0", 64)})), "RESET_REQUIRED")
            test.eq(code(call(alice, "feed_read_after", {workspace_id = workspace, cursor = first.cursor,
                expected_scope_revision = {}})), "INVALID_ARGUMENT")
            test.eq(code(call(alice, "feed_snapshot", {workspace_id = workspace, expected_scope_revision = 7})), "INVALID_ARGUMENT")
        end)
        test.it("serves request, read and consume to an executor scoped like the activation owner", function()
            local activation = funcs.new():with_actor(security.new_actor("bee.gov.activation"))
                :with_scope(scope({"bee.security.approvals:approval_request_policy", "bee.security.approvals:approval_consume_policy"}))
            local workspace = "ws-activation-scope-" .. key()
            local created = value(call(activation, "request", request_of(workspace)))
            test.eq(value(call(activation, "read", {approval_id = created.approval_id})).state, "pending")
        end)
        test.it("admits grant administration only for the issuer with workspace decision authority", function()
            local workspace = "ws-window-admission-" .. key()
            local created = value(call(requester, "request", request_of(workspace)))
            local granted = value(call(alice, "decide", {approval_id = created.approval_id, expected_revision = created.revision,
                proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "approved", window_ttl_ms = 60000}))
            local grant = assert(bounds.object(granted.window_grant))
            test.eq(code(call(outsider, "grant_window", {operation = "list", workspace_id = workspace})), "DENIED")
            local owned = value(call(alice, "grant_window", {operation = "list", workspace_id = workspace}))
            test.eq(#principals.items(owned.grants), 1)
            test.eq(#principals.items(value(call(bob, "grant_window", {operation = "list", workspace_id = workspace})).grants), 0)
            test.eq(code(call(bob, "grant_window", {operation = "revoke", grant_id = grant.grant_id})), "DENIED")
            test.eq(code(call(alice, "grant_window", {operation = "revoke", grant_id = grant.grant_id, workspace_id = "another-workspace"})), "DENIED")
            value(call(alice, "grant_window", {operation = "revoke", grant_id = grant.grant_id}))
            test.eq(value(call(requester, "request", request_of(workspace))).state, "pending")
        end)
        test.it("binds a request to its proposal digest under the host policy and replays or conflicts on its key", function()
            local workspace = "ws-" .. key()
            test.eq(code(call(outsider, "request", request_of(workspace))), "DENIED")
            test.eq(code(call(requester, "request", request_of(workspace, {policy = "nope"}))), "NOT_FOUND")
            test.eq(code(call(requester, "request", request_of(workspace, {ttl_ms = 60001}))), "FORBIDDEN")
            test.eq(code(call(requester, "request", request_of(workspace, {proposal = {kind = "attempt", ref = "x", revision = "r1", payload = {big = string.rep("x", 9000)}}}))), "INVALID_ARGUMENT")
            local first_request = request_of(workspace)
            local created = value(call(requester, "request", first_request))
            test.eq(created.state, "pending")
            test.eq(created.revision, 1)
            test.eq(created.requester_id, REQUESTER)
            test.eq(#(created.proposal_digest), 64)
            test.eq(created.owner_incarnation ~= nil, true)
            local replayed = call(requester, "request", first_request)
            test.eq(value(replayed).approval_id, created.approval_id)
            test.eq(replayed.replayed, true)
            first_request.prompt = {text = "changed"}
            test.eq(code(call(requester, "request", first_request)), "CONFLICT")
            local listed = value(call(requester, "list", {workspace_id = workspace}))
            test.eq(#(principals.items(listed.requests)), 1)
            test.eq(#(principals.items(value(call(other_requester, "list", {workspace_id = workspace})).requests)), 0)
        end)
        test.it("admits a host-selected application definition while retaining its private actor", function()
            local workspace = "ws-" .. key()
            local created = value(call(requester, "request", request_of(workspace, {
                proposal = proposal({definition_id = "bee.approvals.inbox.app:app"})})))
            local approval_id, digest = created.approval_id, created.proposal_digest
            test.eq(code(call(other_app, "read", {approval_id = approval_id})), "DENIED")
            test.eq(value(call(inbox_app, "read", {approval_id = approval_id})).approval_id, approval_id)
            local decided = value(call(inbox_app, "decide", {approval_id = approval_id,
                expected_revision = 1, decision = "approved", proposal_digest = digest}))
            test.eq(decided.decider_id, INBOX_ACTOR)
            test.eq(decided.state, "decided")
        end)
        test.it("rejects malformed application definition selectors", function()
            local valid: {unknown} = {ALICE, BOB, "bee.test.carol", {definition_id = "bee.approvals.inbox.app:app"}}
            for _, invalid in ipairs({{{}}, {{definition_id = ""}},
                    {{definition_id = "bee.approvals.inbox.app:app", extra = true}}}) do
                replace_approvers(principals.items(invalid))
                local decoded, decode_error = resources.policies()
                test.eq(decoded, nil)
                test.eq(type(decode_error), "string")
            end
            replace_approvers(valid)
            local decoded, decode_error = resources.policies()
            test.eq(decode_error, nil)
            test.eq(decoded ~= nil, true)
        end)
        test.it("rejects malformed policy envelopes, sparse lists, duplicate names and fractional TTLs", function()
            local entry = assert(registry.get("bee.security.approvals:approver_policies"))
            local original, encode_error = json.encode(entry.data)
            if not original then error("encode approver policy fixture: " .. tostring(encode_error)) end
            local function write(data: {[string]: unknown})
                local current = assert(registry.get("bee.security.approvals:approver_policies"))
                current.data = data
                local changes = registry.snapshot():changes()
                assert(changes:update(current))
                local applied, apply_error = changes:apply()
                if not applied then error("write approver policy fixture: " .. tostring(apply_error)) end
            end
            local function mutated(change: ({[string]: unknown}) -> ())
                local data = assert(bounds.object(json.decode(original)))
                change(data)
                write(data)
                local policies, decode_error = resources.policies()
                test.eq(policies, nil)
                test.eq(type(decode_error), "string")
            end
            mutated(function(data)
                data.unexpected = true
            end)
            mutated(function(data)
                local policies = principals.objects(data.policies)
                data.policies = policies
                local selected: {[string]: unknown}? = nil
                for _, policy in ipairs(policies) do
                    if policy.name == POLICY then selected = policy; break end
                end
                assert(selected)
                local invalid: unknown = {[1] = ALICE, [3] = BOB}
                selected.approvers = invalid
            end)
            mutated(function(data)
                local policies = principals.objects(data.policies)
                data.policies = policies
                local selected: {[string]: unknown}? = nil
                for _, policy in ipairs(policies) do
                    if policy.name == POLICY then selected = policy; break end
                end
                assert(selected)
                local duplicate: {[string]: unknown} = {}
                for name, value in pairs(selected) do duplicate[name] = value end
                policies[#policies + 1] = duplicate
            end)
            mutated(function(data)
                local policies = principals.objects(data.policies)
                for _, policy in ipairs(policies) do
                    if policy.name == POLICY then policy.max_ttl_ms = 1.5; break end
                end
            end)
            write(assert(bounds.object(json.decode(original))))
            local decoded, decode_error = resources.policies()
            test.eq(decode_error, nil)
            test.eq(decoded ~= nil, true)
        end)
        test.it("binds subject, scope and reviewed evidence to an immutable request", function()
            local db = open_test_store()
            local asked = request_of("ws-contract-" .. key(), {contract_version = 2, subject = {principal_id = "subject-test"},
                scope = {type = "exact", parameters = {target = "one"}}, presentation = "inline",
                evidence = {{ref = "test:preflight", digest = string.rep("a", 64)}}})
            local created = executed(service.execute(db, REQUESTER, "request", asked, 1000, nil))
            test.eq(created.contract_version, 2)
            local contract = assert(bounds.object(created.contract))
            test.eq(assert(bounds.object(contract.requester)).actor_id, REQUESTER)
            test.eq(assert(bounds.object(contract.subject)).principal_id, "subject-test")
            test.eq(service.execute(db, REQUESTER, "withdraw", {approval_id = created.approval_id, expected_revision = 1,
                proposal_digest = created.proposal_digest}, 1001, nil).code, "CONFLICT")
            local fence: {[string]: unknown} = {approval_id = created.approval_id, expected_revision = 1, proposal_digest = created.proposal_digest,
                reviewed_digest = string.rep("0", 64), decision = "approved"}
            test.eq(service.execute(db, ALICE, "decide", fence, 1001, nil).code, "CONFLICT")
            fence.reviewed_digest = created.reviewed_digest
            executed(service.execute(db, ALICE, "decide", fence, 1001, nil))
            asked.evidence = {{ref = "test:preflight", digest = string.rep("b", 64)}}
            test.eq(service.execute(db, REQUESTER, "request", asked, 1002, nil).code, "CONFLICT")
            local records = assert(db:query("SELECT kind, reviewed_digest FROM bee_approval_decisions WHERE approval_id = ?", {created.approval_id}))
            test.eq(records[1].kind, "allow_once")
            test.eq(records[1].reviewed_digest, created.reviewed_digest)
            db:release()
        end)
        test.it("shows approvers a bounded inbox of the requests their policy covers and nothing to anyone else", function()
            local workspace = "ws-" .. key()
            local created = value(call(requester, "request", request_of(workspace)))
            test.eq(code(call(outsider, "inbox", {workspace_id = workspace})), "DENIED")
            test.eq(code(call(alice, "inbox", {workspace_id = workspace, limit = 65})), "INVALID_ARGUMENT")
            local page = value(call(alice, "inbox", {workspace_id = workspace, limit = 1}))
            local changes = principals.objects(page.changes)
            test.eq(#changes, 1)
            test.eq(changes[1].approval_id, created.approval_id)
            test.eq(changes[1].revision, 1)
            value(call(carol, "decide", {approval_id = created.approval_id, expected_revision = 1, decision = "denied", proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest}))
            local rest = value(call(bob, "inbox", {workspace_id = workspace, after_seq = page.next_seq}))
            local later = principals.objects(rest.changes)
            test.eq(#later, 1)
            test.eq(later[1].revision, 2)
            test.eq((assert(bounds.object(later[1].request))).decision, "denied")
        end)
        test.it("counts node pending approvals through the public binding without granting request access", function()
            local reader = caller("node-summary-reader", {"bee.tests.approvals:summary_test_policy"})
            test.eq(code(call(outsider, "node_summary", {})), "DENIED")
            local before = value(call(reader, "node_summary", {}))
            local baseline = before.pending_approvals
            if type(baseline) ~= "number" then error("invalid pending approval count") end
            local created = value(call(requester, "request", request_of("summary-" .. key())))
            test.eq(code(call(reader, "read", {approval_id = created.approval_id})), "DENIED")
            local pending = value(call(reader, "node_summary", {}))
            test.eq(pending.pending_approvals, baseline + 1)
            test.eq(pending.items, nil)
            test.eq(pending.requests, nil)
            test.eq(code(call(reader, "node_summary", {workspace_id = "not-admitted"})), "INVALID_ARGUMENT")
            value(call(alice, "decide", {approval_id = created.approval_id, expected_revision = 1,
                decision = "denied", proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest}))
            test.eq(value(call(reader, "node_summary", {})).pending_approvals, before.pending_approvals)
            value(call(requester, "request", request_of("summary-expiry-" .. key(), {ttl_ms = 1})))
            time.sleep("5ms")
            test.eq(value(call(reader, "node_summary", {})).pending_approvals, before.pending_approvals)
        end)
    end)
end
return test.run_cases(define_tests)
