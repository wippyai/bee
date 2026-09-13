-- MIT. Carrier operations: an epoch fences earlier carriers, a commit
-- lands records and checkpoint together or not at all, replayed records
-- deduplicate by key while the checkpoint still advances, and nothing
-- moves on an ended attempt or without carrier authority.
local test = require("test")
local harness = require("harness")
local CARRIER = {"bee:thread_create_policy", "bee:thread_observe_policy", "bee:thread_lifecycle_policy", "bee:thread_carrier_policy"}
local function checkpoint(consumed: integer): {[string]: unknown}
    return {schema_revision = "bee.carrier.checkpoint@1", consumed = {stdout = consumed, stderr = 0}, carry = {stdout = "", stderr = ""}, envelope_index = consumed,
        normalizer_state = {answer = "partial"}, binding_ref = "b", binding_digest = "d", profile_id = "batch", profile_digest = "p", attachment_generation = 1}
end
local function provenance(envelope: integer, event: integer, first: integer, last: integer): {[string]: unknown}
    return {schema_revision = "bee.carrier.provenance@1", stream_id = "stdout", source_first_sequence = first, source_last_sequence = last, envelope_index = envelope, event_index = event}
end
local function text(envelope: integer, content: string, first: integer?, last: integer?): {[string]: unknown}
    return {source = "stream", provenance = provenance(envelope, 0, first or 1, last or 1), body = {type = "text", event_key = "ignored",
        data = {type = "text", segment_id = "seg", operation = "append", text = content, channel = "answer"}}}
end
local function control(write_id: string, phase: string): {[string]: unknown}
    return {source = "bee", body = {type = "extension", event_key = "write:" .. write_id .. ":" .. phase,
        data = {type = "extension", event_name = "bee.carrier.write", event_revision = "1",
            payload_json = '{"write_id":"' .. write_id .. '","phase":"' .. phase .. '","attachment_generation":1}'}}}
end
local function define_tests()
    test.describe("Thread carrier", function()
        local carrier = harness.principal("carrier", CARRIER)
        local runner = harness.principal("runner-only", harness.ALL)
        local function prepared_attempt(): string
            local thread_id = harness.thread(carrier, "Carrier")
            harness.value(carrier:call("admit_action", {thread_id = thread_id, idempotency_key = harness.key(), action_id = "a1", admitted = harness.admitted()}))
            harness.value(carrier:call("prepare_attempt", {thread_id = thread_id, idempotency_key = harness.key(), action_id = "a1", attempt_id = "t1", prepared = harness.prepared()}))
            return thread_id
        end
        test.it("reads placement from preparation even before a checkpoint and ignores checkpoint replacement", function()
            local thread_id = harness.thread(carrier, "Recorded placement")
            harness.value(carrier:call("admit_action", {thread_id = thread_id, idempotency_key = harness.key(), action_id = "a1", admitted = harness.admitted()}))
            local plan = harness.prepared()
            plan.placement_binding = "fixture.docker:binding"
            plan.placement_attempt_id = "container-attempt"
            harness.value(carrier:call("prepare_attempt", {thread_id = thread_id, idempotency_key = harness.key(), action_id = "a1", attempt_id = "t1", prepared = plan}))
            local before = harness.value(carrier:call("carrier_checkpoint", {thread_id = thread_id, attempt_id = "t1"}))
            test.is_nil(before.checkpoint)
            test.eq(before.placement_binding, "fixture.docker:binding")
            test.eq(before.placement_attempt_id, "container-attempt")
            harness.value(carrier:call("carrier_claim", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1"}))
            local point = checkpoint(1)
            point.placement_binding = "bee.placement.native:binding"
            point.placement_attempt_id = "another-attempt"
            harness.value(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1", carrier_epoch = 1, expected_revision = 0, checkpoint = point, records = {}}))
            local after = harness.value(carrier:call("carrier_checkpoint", {thread_id = thread_id, attempt_id = "t1"}))
            test.eq(after.placement_binding, before.placement_binding)
            test.eq(after.placement_attempt_id, before.placement_attempt_id)
            test.eq(after.checkpoint.placement_binding, "bee.placement.native:binding")
            test.eq(harness.code(runner:call("carrier_checkpoint", {thread_id = thread_id, attempt_id = "t1"})), "DENIED")
        end)
        test.it("fences earlier carriers by epoch and advances revisions only from the expected one", function()
            local thread_id = prepared_attempt()
            local key = harness.key()
            local first = harness.value(carrier:call("carrier_claim", {thread_id = thread_id, idempotency_key = key, attempt_id = "t1"}))
            test.eq(first.carrier_epoch, 1)
            test.eq(first.checkpoint_revision, 0)
            test.eq(first.attempt_state, "prepared")
            test.is_true(carrier:call("carrier_claim", {thread_id = thread_id, idempotency_key = key, attempt_id = "t1"}).replayed)
            local second = harness.value(carrier:call("carrier_claim", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1"}))
            test.eq(second.carrier_epoch, 2)
            test.eq(harness.code(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1", carrier_epoch = 1, expected_revision = 0, checkpoint = checkpoint(1), records = {text(1, "hello")}})), "CONFLICT")
            local commit_key = harness.key()
            local committed = harness.value(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = commit_key, attempt_id = "t1", carrier_epoch = 2, expected_revision = 0, checkpoint = checkpoint(1), records = {text(1, "hello"), control("w1", "intended")}}))
            test.eq(committed.checkpoint_revision, 1)
            test.eq(#committed.records, 2)
            test.is_false(committed.records[1].replayed)
            test.is_true(committed.records[2].sequence > committed.records[1].sequence)
            test.is_true(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = commit_key, attempt_id = "t1", carrier_epoch = 2, expected_revision = 0, checkpoint = checkpoint(1), records = {text(1, "hello"), control("w1", "intended")}}).replayed)
            test.eq(harness.code(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1", carrier_epoch = 2, expected_revision = 0, checkpoint = checkpoint(2), records = {}})), "CONFLICT")
            local again = harness.value(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1", carrier_epoch = 2, expected_revision = 1, checkpoint = checkpoint(2), records = {text(1, "hello", 2, 2), text(2, " world")}}))
            test.eq(again.checkpoint_revision, 2)
            test.is_true(again.records[1].replayed)
            test.eq(again.records[1].record_id, committed.records[1].record_id)
            test.is_false(again.records[2].replayed)
            test.eq(harness.code(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1", carrier_epoch = 2, expected_revision = 2, checkpoint = checkpoint(3), records = {text(1, "changed")}})), "CONFLICT")
            local stored = harness.value(carrier:call("carrier_checkpoint", {thread_id = thread_id, attempt_id = "t1"}))
            test.eq(stored.carrier_epoch, 2)
            test.eq(stored.checkpoint_revision, 2)
            test.eq(stored.checkpoint.consumed.stdout, 2)
            test.eq(stored.checkpoint.normalizer_state.answer, "partial")
            local page = harness.value(carrier:call("read_after", {thread_id = thread_id, cursor = 0, filter = {kinds = {"observation"}}}))
            test.eq(#page.records, 3)
            test.eq(page.records[1].source, "stream")
            test.eq(page.records[1].attempt_id, "t1")
            test.is_nil(page.records[1].body.raw_ref)
            test.eq(page.records[1].body.event_key, "carrier:t1:stdout:1:0")
            local db = harness.open()
            local mapped = harness.query(db, "SELECT stream_id, envelope_index, event_index, source_first_sequence, source_last_sequence, record_id FROM bee_thread_carrier_events WHERE thread_id = ? ORDER BY envelope_index", {thread_id})
            db:release()
            test.eq(#mapped, 2)
            test.eq(mapped[1].record_id, committed.records[1].record_id)
            test.eq(mapped[1].source_last_sequence, 1)
            test.eq(mapped[2].envelope_index, 2)
            test.eq(page.records[2].source, "bee")
            test.eq(page.records[2].body.data.event_name, "bee.carrier.write")
        end)
        test.it("reads the committed attempt outcome independently of the provider checkpoint", function()
            for _, outcome in ipairs({"succeeded", "failed", "cancelled", "uncertain"}) do
                local thread_id = prepared_attempt()
                harness.value(carrier:call("carrier_claim", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1"}))
                local point = checkpoint(1)
                point.terminal = {outcome = "succeeded", resume_ref = "provider-session"}
                harness.value(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1", carrier_epoch = 1, expected_revision = 0, checkpoint = point, records = {}}))
                local active = harness.value(carrier:call("carrier_checkpoint", {thread_id = thread_id, attempt_id = "t1"}))
                test.is_nil(active.attempt_outcome)
                local receipt: {[string]: unknown} = {scope = "attempt", outcome = outcome, evidence_refs = {}}
                if outcome ~= "succeeded" then receipt.error = {code = outcome, message = outcome, retryable = false} end
                harness.value(carrier:call("receipt", {thread_id = thread_id, idempotency_key = harness.key(), action_id = "a1", attempt_id = "t1", carrier_epoch = 1, receipt = receipt}))
                local ended = harness.value(carrier:call("carrier_checkpoint", {thread_id = thread_id, attempt_id = "t1"}))
                test.eq(ended.attempt_state, "ended")
                test.eq(ended.attempt_outcome, outcome)
                test.eq(ended.checkpoint.terminal.outcome, "succeeded")
            end
        end)
        test.it("refuses malformed records, foreign turns, ended attempts and callers without carrier authority", function()
            local thread_id = prepared_attempt()
            test.eq(harness.code(runner:call("carrier_claim", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1"})), "DENIED")
            test.eq(harness.code(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1", carrier_epoch = 1, expected_revision = 0, checkpoint = checkpoint(1), records = {}})), "CONFLICT")
            harness.value(carrier:call("carrier_claim", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1"}))
            local foreign = {source = "bee", body = {type = "extension", event_key = "x", data = {type = "extension", event_name = "vendor.thing", event_revision = "1", payload_json = "{}"}}}
            test.eq(harness.code(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1", carrier_epoch = 1, expected_revision = 0, checkpoint = checkpoint(1), records = {foreign}})), "INVALID_ARGUMENT")
            local bad_checkpoint = checkpoint(1)
            bad_checkpoint.schema_revision = "bee.carrier.checkpoint@2"
            test.eq(harness.code(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1", carrier_epoch = 1, expected_revision = 0, checkpoint = bad_checkpoint, records = {}})), "INVALID_ARGUMENT")
            local vendor_control = control("w2", "intended")
            local vendor_data = (vendor_control.body :: {[string]: unknown}).data :: {[string]: unknown}
            vendor_data.event_name = "bee.other.thing"
            test.eq(harness.code(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1", carrier_epoch = 1, expected_revision = 0, checkpoint = checkpoint(1), records = {vendor_control}})), "INVALID_ARGUMENT")
            local evidenced = text(3, "x")
            local evidenced_body = evidenced.body :: {[string]: unknown}
            evidenced_body.raw_ref = "artifact:1"
            test.eq(harness.code(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1", carrier_epoch = 1, expected_revision = 0, checkpoint = checkpoint(1), records = {evidenced}})), "INVALID_ARGUMENT")
            local unprovenanced = text(4, "x")
            unprovenanced.provenance = nil
            test.eq(harness.code(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1", carrier_epoch = 1, expected_revision = 0, checkpoint = checkpoint(1), records = {unprovenanced}})), "INVALID_ARGUMENT")
            local turned = text(9, "x")
            turned.turn_id = "u-missing"
            test.eq(harness.code(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1", carrier_epoch = 1, expected_revision = 0, checkpoint = checkpoint(1), records = {turned}})), "INVALID_ARGUMENT")
            harness.value(carrier:call("request_turn", {thread_id = thread_id, idempotency_key = harness.key(), action_id = "a1", attempt_id = "t1", turn_id = "u1", turn = {input_message_ids = {}, input = {text = "go"}, delivery_ids = {}}}))
            turned.turn_id = "u1"
            local on_turn = harness.value(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1", carrier_epoch = 1, expected_revision = 0, checkpoint = checkpoint(1), records = {turned}}))
            test.eq(on_turn.checkpoint_revision, 1)
            local page = harness.value(carrier:call("read_after", {thread_id = thread_id, cursor = 0, filter = {kinds = {"observation"}}}))
            test.eq(page.records[1].turn_id, "u1")
            test.eq(harness.code(carrier:call("end_turn", {thread_id = thread_id, idempotency_key = harness.key(), action_id = "a1", attempt_id = "t1", turn_id = "u1", carrier_epoch = 2, turn_end = {outcome = "succeeded", answer_message_ids = {}, evidence_refs = {}}})), "CONFLICT")
            harness.value(carrier:call("end_turn", {thread_id = thread_id, idempotency_key = harness.key(), action_id = "a1", attempt_id = "t1", turn_id = "u1", carrier_epoch = 1, turn_end = {outcome = "succeeded", answer_message_ids = {}, evidence_refs = {}}}))
            test.eq(harness.code(carrier:call("receipt", {thread_id = thread_id, idempotency_key = harness.key(), action_id = "a1", attempt_id = "t1", carrier_epoch = 7, receipt = {scope = "attempt", outcome = "succeeded", evidence_refs = {}}})), "CONFLICT")
            harness.value(carrier:call("receipt", {thread_id = thread_id, idempotency_key = harness.key(), action_id = "a1", attempt_id = "t1", carrier_epoch = 1, receipt = {scope = "attempt", outcome = "succeeded", evidence_refs = {}}}))
            test.eq(harness.code(carrier:call("carrier_commit", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1", carrier_epoch = 1, expected_revision = 1, checkpoint = checkpoint(2), records = {}})), "INVALID_STATE")
            test.eq(harness.code(carrier:call("carrier_claim", {thread_id = thread_id, idempotency_key = harness.key(), attempt_id = "t1"})), "INVALID_STATE")
            local final = harness.value(carrier:call("carrier_checkpoint", {thread_id = thread_id, attempt_id = "t1"}))
            test.eq(final.attempt_state, "ended")
            test.eq(final.checkpoint_revision, 1)
        end)
    end)
end
return test.run_cases(define_tests)
