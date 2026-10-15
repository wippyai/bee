-- MIT. Approval service authority.
local test = require("test")
local events = require("events")
local principals = require("principals")
local bounds = require("bounds")
local registry = require("registry")
local process = require("process")
local service = require("service")
local fixture = require("fixture").new()
local REQUESTER = fixture.REQUESTER
local OTHER_REQUESTER = fixture.OTHER_REQUESTER
local ALICE = fixture.ALICE
local key = fixture.key
local scope = fixture.scope
local requester = fixture.requester
local value = fixture.value
local code = fixture.code
local open_test_store = fixture.open_test_store
local executed = fixture.executed
local proposal = fixture.proposal
local request_of = fixture.request_of
local retire_owned_effects = fixture.retire_owned_effects

local function define_tests()
    test.describe("Approval owner authority", function()
        fixture.setup("bee.tests.approvals:service_authority_db", false)
        test.after_all(retire_owned_effects)
        test.it("serves no request before the authority establishes its incarnation and advances it per start", function()
            local store = open_test_store()
            local before = service.execute(store, REQUESTER, "request", request_of("ws-" .. key()), nil, requester)
            test.eq(before.ok, false)
            test.eq(before.code, "UNAVAILABLE")
            test.eq(assert(service.establish(store)), 1)
            test.eq(assert(service.establish(store)), 2)
            local created = executed(service.execute(store, REQUESTER, "request", request_of("ws-" .. key()), nil, requester))
            test.eq(created.owner_incarnation, 2)
            store:release()
            local pid = process.registry.lookup(service.AUTHORITY_NAME)
            test.eq(pid ~= nil, true)
        end)
        test.it("scopes restored approval snapshots and catch-up to their native owner with or without authority rows", function()
            local db = open_test_store()
            local workspace = "ws-restored-" .. key()
            local old = executed(service.execute(db, REQUESTER, "request", request_of(workspace), nil, requester))
            local current = executed(service.execute(db, REQUESTER, "request", request_of(workspace), nil, requester))
            assert(db:execute("UPDATE bee_approval_requests SET owner_node = ? WHERE approval_id = ?", {"previous-owner", old.approval_id}))
            local authorities = assert(db:query("SELECT owner_node, incarnation, established_at FROM bee_approval_authority"))
            for _, omitted in ipairs({false, true}) do
                if omitted then assert(db:execute("DELETE FROM bee_approval_authority")) end
                local snapshot = executed(service.execute(db, ALICE, "feed_snapshot", {workspace_id = workspace}, nil, nil))
                local page = executed(service.execute(db, ALICE, "feed_read_after", {workspace_id = workspace, cursor = 0,
                    expected_scope_revision = snapshot.scope_revision}, nil, nil))
                if omitted then
                    for _, authority in ipairs(authorities) do
                        assert(db:execute("INSERT INTO bee_approval_authority(owner_node, incarnation, established_at) VALUES (?, ?, ?)",
                            {authority.owner_node, authority.incarnation, authority.established_at}))
                    end
                end
                local items, events = principals.objects(snapshot.items), principals.objects(page.events)
                test.eq(#items, 1)
                test.eq(items[1].key, current.approval_id)
                test.eq(#events, 1)
                test.eq(events[1].projection_key, current.approval_id)
                test.eq(snapshot.complete, true)
                test.eq(page.more, false)
            end
            assert(db:execute("DELETE FROM bee_approval_inbox WHERE approval_id = ?", {current.approval_id}))
            local missing = service.execute(db, ALICE, "feed_snapshot", {workspace_id = workspace}, nil, nil)
            test.eq(missing.ok, false)
            test.eq(missing.code, "STORAGE")
            db:release()
        end)
        test.it("fails closed on a corrupt authority incarnation for requests and restart", function()
            local store = open_test_store()
            local owner_node, node_error = service.node()
            if not owner_node then error("read native node identity: " .. tostring(node_error)) end
            local rows, read_error = store:query("SELECT incarnation FROM bee_approval_authority WHERE owner_node = ?", {owner_node})
            if read_error or not rows or #rows == 0 then error("read authority incarnation: " .. tostring(read_error)) end
            local previous = rows[1].incarnation
            local _, corrupt_error = store:execute("UPDATE bee_approval_authority SET incarnation = 'broken' WHERE owner_node = ?", {owner_node})
            test.eq(corrupt_error, nil)
            local request = service.execute(store, REQUESTER, "request", request_of("ws-" .. key()), nil, requester)
            test.eq(request.ok, false)
            test.eq(request.code, "STORAGE")
            local established, establish_error = service.establish(store)
            test.eq(established, nil)
            test.is_true((establish_error or ""):find("corrupt", 1, true) ~= nil)
            local _, restore_error = store:execute("UPDATE bee_approval_authority SET incarnation = ? WHERE owner_node = ?", {previous, owner_node})
            test.eq(restore_error, nil)
            store:release()
        end)
        test.it("rejects corrupt persisted approval effect metadata", function()
            local store = open_test_store()
            local created = executed(service.execute(store, REQUESTER, "request", request_of("ws-" .. key()), nil, requester))
            local _, corrupt_error = store:execute("UPDATE bee_approval_requests SET validated_incarnation = 'broken' WHERE approval_id = ?", {created.approval_id})
            test.eq(corrupt_error, nil)
            local result = service.execute(store, REQUESTER, "read", {approval_id = created.approval_id}, nil, nil)
            test.eq(result.ok, false)
            test.eq(result.code, "STORAGE")
            local _, restore_error = store:execute("UPDATE bee_approval_requests SET validated_incarnation = NULL WHERE approval_id = ?", {created.approval_id})
            test.eq(restore_error, nil)
            local _, version_error = store:execute("UPDATE bee_approval_requests SET contract_version = 99 WHERE approval_id = ?", {created.approval_id})
            test.eq(version_error, nil)
            test.eq(service.execute(store, REQUESTER, "read", {approval_id = created.approval_id}, nil, nil).code, "STORAGE")
            local _, reset_error = store:execute("UPDATE bee_approval_requests SET contract_version = ? WHERE approval_id = ?", {created.contract_version, created.approval_id})
            test.eq(reset_error, nil)
            store:release()
        end)
        test.it("fences stale authority: consumption after a restart needs revalidation under the current incarnation", function()
            local store = open_test_store()
            local before = assert(service.establish(store))
            local created = executed(service.execute(store, REQUESTER, "request", request_of("ws-" .. key()), nil, requester))
            local approval_id, digest = created.approval_id, created.proposal_digest
            executed(service.execute(store, ALICE, "decide", {approval_id = approval_id, expected_revision = 1, decision = "approved", proposal_digest = digest}, nil, nil))
            local after = assert(service.establish(store))
            test.eq(after, before + 1)
            local stale = service.execute(store, REQUESTER, "consume", {approval_id = approval_id, proposal_digest = digest, effect_key = "e1", owner_incarnation = before}, nil, nil)
            test.eq(stale.code, "REVALIDATE")
            test.eq((assert(bounds.object(stale.value))).current_incarnation, after)
            local unvalidated = service.execute(store, REQUESTER, "consume", {approval_id = approval_id, proposal_digest = digest, effect_key = "e1", owner_incarnation = after}, nil, nil)
            test.eq(unvalidated.code, "REVALIDATE")
            test.eq(service.execute(store, REQUESTER, "revalidate", {approval_id = approval_id, proposal_digest = digest, owner_incarnation = before}, nil, nil).code, "REVALIDATE")
            local validated = executed(service.execute(store, REQUESTER, "revalidate", {approval_id = approval_id, proposal_digest = digest, owner_incarnation = after}, nil, nil))
            test.eq(validated.validated_incarnation, after)
            test.eq(validated.validated_by, REQUESTER)
            test.eq(service.execute(store, REQUESTER, "revalidate", {approval_id = approval_id, proposal_digest = digest, owner_incarnation = after}, nil, nil).replayed, true)
            local consumed = executed(service.execute(store, REQUESTER, "consume", {approval_id = approval_id, proposal_digest = digest, effect_key = "e1", owner_incarnation = after}, nil, nil))
            test.eq(consumed.consumed_effect, "e1")
            local again = assert(service.establish(store))
            local fenced = service.execute(store, REQUESTER, "consume", {approval_id = approval_id, proposal_digest = digest, effect_key = "e1", owner_incarnation = again}, nil, nil)
            test.eq(fenced.code, "REVALIDATE")
            store:release()
        end)
        test.it("replays upgraded callers against unchanged legacy authority without recreating requests", function()
            local db = open_test_store()
            local asked = request_of("ws-legacy-replay-" .. key(), {ttl_ms = 10,
                proposal = {kind = "operation", ref = "bee.test:effect", revision = "1", payload = {target = "same"}}})
            local created = executed(service.execute(db, REQUESTER, "request", asked, 1000, nil))
            local _, legacy_error = db:execute([[UPDATE bee_approval_requests SET contract_version = 1,
                reviewed_digest = proposal_digest, effect_admission_ms = expires_ms,
                contract_json = json_set(contract_json, '$.provenance', json_object('kind','legacy'))
                WHERE approval_id = ?]], {created.approval_id})
            test.eq(legacy_error, nil)
            asked.contract_version = 2
            asked.subject = {principal_id = REQUESTER}
            asked.origin = {action_id = "legacy-action"}
            asked.continuation = {destination = "fixture.effect", effect_id = "upgraded-effect", context = {}}
            local replay = service.execute(db, REQUESTER, "request", asked, 1001, nil)
            local original = executed(replay)
            test.eq(replay.replayed, true)
            test.eq(original.approval_id, created.approval_id)
            test.eq(original.request_digest, created.request_digest)
            test.eq(original.contract_version, 1)
            test.eq(original.effect_admission_ms, 1010)
            test.eq(assert(bounds.object(original.effect)).effect_id, assert(bounds.object(created.effect)).effect_id)
            asked.subject = {principal_id = OTHER_REQUESTER}
            test.eq(service.execute(db, REQUESTER, "request", asked, 1001, nil).code, "CONFLICT")
            asked.subject = {principal_id = REQUESTER}
            asked.scope = {type = "exact", parameters = {target = "different"}}
            test.eq(service.execute(db, REQUESTER, "request", asked, 1001, nil).code, "CONFLICT")
            asked.scope = nil
            asked.evidence = {{ref = "test:preflight", digest = string.rep("a",64)}}
            test.eq(service.execute(db, REQUESTER, "request", asked, 1001, nil).code, "CONFLICT")
            asked.evidence = nil
            asked.effect_admission_ms = 1011
            test.eq(service.execute(db, REQUESTER, "request", asked, 1001, nil).code, "CONFLICT")
            test.eq(assert(db:query("SELECT COUNT(*) AS count FROM bee_approval_requests WHERE requester_key = ?", {asked.idempotency_key}))[1].count, 1)
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
