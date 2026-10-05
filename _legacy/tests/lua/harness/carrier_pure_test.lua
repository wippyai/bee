-- MIT. The carrier's pure rules: provenance round-trips and keys ignore
-- chunking; checkpoints decode exactly and only move forward; settlement
-- follows the terminal envelope and never process exit alone.
local test = require("test")
local bounds = require("bounds")
local provenance = require("provenance")
local checkpoint = require("checkpoint")
local settle = require("settle")
local driver_types = require("driver_types")
local hook_records = require("hook_records")
local gateway_hooks = require("gateway_hooks")
local gateway_protocol = require("gateway_protocol")
local canonical = require("canonical")

type Object = {[string]: unknown}

local function make_valid_item(id: string, event: string, ambiguous: boolean): Object
    local fields: Object = {
        event = event,
        session_id = "sess-1",
        turn_id = "turn-1",
        prompt_id = "prompt-1",
        content_sizes = {prompt = 12},
        content_digests = {prompt = string.rep("a", 64)},
    }
    return {
        event_id = id,
        event = event,
        occurrence = ambiguous and "turn:turn-1" or "turn:prompt-1",
        ambiguous = ambiguous,
        provenance = "http",
        sequence = 1,
        fields = fields,
    }
end

local function reference_hook_record(binding_id: string, turn_id: string?, item: Object): {[string]: unknown}
    local key = "hook:" .. tostring(item.event_id)
    if item.ambiguous ~= true then
        key = "hook:" .. binding_id .. ":" .. tostring(item.event) .. ":" .. tostring(item.occurrence)
    end
    local payload = canonical.encode({
        event_id = item.event_id,
        event = item.event,
        occurrence = item.occurrence,
        ambiguous = item.ambiguous == true,
        provenance = item.provenance,
        sequence = item.sequence,
        fields = item.fields,
        binding_id = binding_id,
    }) or "{}"
    local record: {[string]: unknown} = {
        source = "bee",
        body = {
            type = "extension",
            event_key = key,
            data = {
                type = "extension",
                event_name = "bee.harness.hook",
                event_revision = "1",
                payload_json = payload,
            },
        },
    }
    if turn_id ~= nil then record.turn_id = turn_id end
    return record
end

local function define_tests()
    test.describe("Carrier rules", function()
        test.it("encodes provenance once and derives keys that ignore chunking", function()
            local value = {stream_id = "stdout", source_first_sequence = 12, source_last_sequence = 13, envelope_index = 7, event_index = 0}
            local encoded, err = provenance.encode(value)
            if not encoded then error(tostring(err)) end
            test.eq(encoded, "bee.carrier.provenance@1:stdout:12-13:7:0")
            local decoded = provenance.decode(encoded)
            if not decoded then error("decode") end
            test.eq(decoded.source_last_sequence, 13)
            local rechunked = {stream_id = "stdout", source_first_sequence = 13, source_last_sequence = 13, envelope_index = 7, event_index = 0}
            test.eq(provenance.event_key("t1", value), provenance.event_key("t1", rechunked))
            test.neq(provenance.event_key("t1", value), provenance.event_key("t1", {stream_id = "stdout", source_first_sequence = 12, source_last_sequence = 13, envelope_index = 7, event_index = 1}))
            test.is_nil(provenance.decode("bee.carrier.provenance@2:stdout:1-1:0:0"))
            test.is_nil(provenance.encode({stream_id = "std out", source_first_sequence = 1, source_last_sequence = 1, envelope_index = 0, event_index = 0}))
            test.is_nil(provenance.encode({stream_id = "stdout", source_first_sequence = 2, source_last_sequence = 1, envelope_index = 0, event_index = 0}))
        end)
        test.it("decodes checkpoints exactly and refuses backwards continuation", function()
            local pinned = {binding_ref = "b", binding_digest = "d", profile_id = "batch", profile_digest = "p"}
            local first = checkpoint.new(pinned, 1)
            test.eq(first.consumed.stdout, 0)
            local decoded, err = checkpoint.decode(first)
            if not decoded then error(tostring(err)) end
            test.eq(decoded.attachment_generation, 1)
            local next_point = checkpoint.new(pinned, 1)
            next_point.consumed.stdout = 4
            next_point.envelope_index = 2
            next_point.carry.stdout = '{"partial'
            next_point.normalizer_state = {answer = "so far"}
            local redecoded = checkpoint.decode(next_point)
            if not redecoded then error("redecode") end
            test.eq(redecoded.carry.stdout, '{"partial')
            test.is_nil(checkpoint.continues(first, redecoded))
            test.eq(checkpoint.continues(redecoded, first), "consumed positions moved backwards")
            local repinned = checkpoint.new({binding_ref = "b", binding_digest = "other", profile_id = "batch", profile_digest = "p"}, 1)
            repinned.consumed.stdout = 9
            test.eq(checkpoint.continues(redecoded, repinned), "pinned measurements changed")
            local kept = assert(bounds.object(checkpoint.new(pinned, 1)))
            kept.output = "truncated"
            local decoded_kept, kept_error = checkpoint.decode(kept)
            if not decoded_kept then error(tostring(kept_error)) end
            test.eq(decoded_kept.output, "truncated")
            kept.output = "unobserved"
            local _, conclusion_error = checkpoint.decode(kept)
            test.eq(conclusion_error, "output must be open, complete or truncated")
            local ended = assert(bounds.object(checkpoint.new(pinned, 1)))
            ended.stream_ended = true
            local decoded_ended, ended_error = checkpoint.decode(ended)
            if not decoded_ended then error(tostring(ended_error)) end
            test.eq(decoded_ended.stream_ended, true)
            ended.stream_ended = "yes"
            local _, flag_error = checkpoint.decode(ended)
            test.eq(flag_error, "stream_ended must be a boolean")
            local loose = assert(bounds.object(checkpoint.new(pinned, 1)))
            loose.extra = true
            test.is_nil(checkpoint.decode(loose))
            local wrong = checkpoint.new(pinned, 1)
            wrong.schema_revision = "bee.carrier.checkpoint@0"
            test.is_nil(checkpoint.decode(wrong))
            local sparse = assert(bounds.object(checkpoint.new(pinned, 1)))
            sparse.pending_writes = {[1] = {}, [3] = {}}
            local sparse_decoded, sparse_error = checkpoint.decode(sparse)
            test.is_nil(sparse_decoded)
            test.eq(sparse_error, "pending_writes must be a bounded dense list: list keys must be dense")
            local keyed = assert(bounds.object(checkpoint.new(pinned, 1)))
            keyed.pending_writes = {unexpected = {}}
            local keyed_decoded, keyed_error = checkpoint.decode(keyed)
            test.is_nil(keyed_decoded)
            test.eq(keyed_error, "pending_writes must be a bounded dense list: list keys must be dense")
            local too_many = assert(bounds.object(checkpoint.new(pinned, 1)))
            local writes: {[integer]: unknown} = {}
            for index = 1, checkpoint.MAX_PENDING_WRITES + 1 do writes[index] = {} end
            too_many.pending_writes = writes
            local bounded, bounded_error = checkpoint.decode(too_many)
            test.is_nil(bounded)
            test.eq(bounded_error, "pending_writes must be a bounded dense list: list exceeds 8 items")
        end)
        test.it("decodes checkpoint terminals through shared fault and usage types", function()
            local raw: {[string]: unknown} = {outcome = "failed", answer = "failed", resume_ref = "session",
                usage = {input_tokens = 7, cost_decimal = "0.25", currency = "USD"},
                error = {code = "driver_failed", message = "the driver failed", retryable = false}}
            local terminal, terminal_error = checkpoint.decode_terminal(raw)
            if not terminal then error(tostring(terminal_error)) end
            test.eq(terminal.outcome, "failed")
            test.eq(terminal.usage and terminal.usage.input_tokens, 7)
            test.eq(terminal.error and terminal.error.code, "driver_failed")

            local malformed_usage: {[string]: unknown} = {outcome = "succeeded", usage = {unexpected = true}}
            local invalid_usage, usage_error = checkpoint.decode_terminal(malformed_usage)
            test.is_nil(invalid_usage)
            test.eq(usage_error, "terminal usage is malformed: unknown field unexpected")
            local malformed_fault: {[string]: unknown} = {outcome = "failed", error = {code = "driver_failed", message = "failure", retryable = "no"}}
            local invalid_fault, fault_error = checkpoint.decode_terminal(malformed_fault)
            test.is_nil(invalid_fault)
            test.eq(fault_error, "terminal error is malformed: fault retryable must be a boolean")
        end)
        test.it("rejects malformed gateway materialization credentials and nested bindings", function()
            local binding: {[string]: unknown} = {binding_id = "binding", subject = "owner", action_id = "action", attempt_id = "attempt",
                thread_id = "thread", owner_incarnation = 1, carrier_epoch = 2, tools = {}, hooks = {}, epoch = 0,
                credential_generation = 3, expires_at = "2025-01-01T00:00:00.000Z", revoked = false, sealed = false,
                workspace_name = "Workspace"}
            local expected = {attempt_id = "attempt", carrier_epoch = 2, binding_id = "binding"}
            local malformed_token, token_error = gateway_protocol.materialization_reply({ok = true,
                value = {binding = binding, token = 17, generation = 3}}, expected)
            test.is_nil(malformed_token)
            test.eq(token_error, "materialization credentials or generation are malformed")
            local malformed_binding, binding_error = gateway_protocol.materialization_reply({ok = true,
                value = {binding = {}, token = "opaque", generation = 3}}, expected)
            test.is_nil(malformed_binding)
            test.is_true(tostring(binding_error):find("materialization binding", 1, true) ~= nil)
            local accepted, accepted_error = gateway_protocol.materialization_reply({ok = true,
                value = {binding = binding, token = "opaque", generation = 3}}, expected)
            if not accepted then error(tostring(accepted_error)) end
            test.eq(accepted.binding.attempt_id, "attempt")
            test.eq(accepted.generation, 3)
            local checked_value: {[string]: unknown} = {}
            for key, value in pairs(binding) do checked_value[key] = value end
            checked_value.valid = true
            checked_value.generation = {epoch = 2, restarts = 1}
            checked_value.presented_count = 0
            local checked, checked_error = gateway_protocol.checked_binding(checked_value)
            if not checked then error(tostring(checked_error)) end
            test.eq(checked.generation.epoch, 2)
            test.eq(checked.generation.restarts, 1)
            checked_value.generation = {epoch = 2, restarts = 1, unexpected = true}
            local malformed_checked, checked_generation_error = gateway_protocol.checked_binding(checked_value)
            test.is_nil(malformed_checked)
            test.eq(checked_generation_error, "checked binding fields are malformed: generation: unknown field unexpected")
            local readiness, readiness_error = gateway_protocol.readiness({generation = {epoch = 2, restarts = 1}, address = "127.0.0.1:4312",
                listening = true, binding = binding, binding_valid = true}, "binding")
            if not readiness then error(tostring(readiness_error)) end
            test.eq(readiness.generation.epoch, 2)
            test.eq(readiness.generation.restarts, 1)
            local bad_readiness, bad_readiness_error = gateway_protocol.readiness({generation = {epoch = 2, restarts = 1, extra = true},
                address = "127.0.0.1:4312", listening = true, binding = binding, binding_valid = true}, "binding")
            test.is_nil(bad_readiness)
            test.eq(bad_readiness_error, "readiness generation: unknown field extra")
        end)
        test.it("decodes hook claims against their binding and carrier epoch", function()
            local value = {binding_id = "binding", carrier_epoch = 4, hooks = {{event_id = "event"}}}
            local claim, claim_error = gateway_protocol.hook_claim(value, "binding", 4)
            if not claim then error(tostring(claim_error)) end
            test.eq(claim.binding_id, "binding")
            test.eq(claim.carrier_epoch, 4)
            test.eq(#claim.hooks, 1)

            local missing_id, missing_id_error = gateway_protocol.hook_claim({carrier_epoch = 4, hooks = {}}, "binding", 4)
            test.is_nil(missing_id)
            test.eq(missing_id_error, "hook claim binding_id is malformed")
            local wrong_binding, wrong_binding_error = gateway_protocol.hook_claim({binding_id = "other", carrier_epoch = 4, hooks = {}}, "binding", 4)
            test.is_nil(wrong_binding)
            test.eq(wrong_binding_error, "hook claim names another binding")
            local wrong_epoch, wrong_epoch_error = gateway_protocol.hook_claim({binding_id = "binding", carrier_epoch = 3, hooks = {}}, "binding", 4)
            test.is_nil(wrong_epoch)
            test.eq(wrong_epoch_error, "hook claim names another carrier epoch")
            local unexpected, unexpected_error = gateway_protocol.hook_claim({binding_id = "binding", carrier_epoch = 4, hooks = {}, extra = true}, "binding", 4)
            test.is_nil(unexpected)
            test.eq(unexpected_error, "hook claim: unknown field extra")
            local malformed, malformed_error = gateway_protocol.hook_claim({binding_id = "binding", carrier_epoch = 4, hooks = {[1] = {}, [3] = {}}}, "binding", 4)
            test.is_nil(malformed)
            test.eq(malformed_error, "hook claim: list keys must be dense")
        end)
        test.it("settles from the terminal envelope and never from exit alone", function()
            local terminal: driver_types.Terminal = {outcome = "succeeded", answer = "42", resume_ref = "s1", usage = nil, error = nil}
            local settled = settle.decide({terminal = terminal, exit = nil, stream_ended = false, drained = false, exit_codes_trustworthy = false})
            if not settled then error("terminal envelope decides") end
            test.eq(settled.outcome, "succeeded")
            test.eq(settled.answer, "42")
            test.is_false(settled.exit_reconciled)
            test.is_nil(settle.decide({terminal = nil, exit = {code = 0, signal = nil, uncertain = false}, stream_ended = false, drained = false, exit_codes_trustworthy = false}))
            local missing = settle.decide({terminal = nil, exit = {code = 0, signal = nil, uncertain = false}, stream_ended = false, drained = true, exit_codes_trustworthy = false})
            if not missing then error("drained exit decides") end
            test.eq(missing.outcome, "uncertain")
            local killed = settle.decide({terminal = nil, exit = {code = 137, signal = 9, uncertain = false}, stream_ended = false, drained = true, exit_codes_trustworthy = false})
            test.eq((killed).outcome, "cancelled")
            local disagreeing = settle.decide({terminal = terminal, exit = {code = 3, signal = nil, uncertain = false}, stream_ended = false, drained = true, exit_codes_trustworthy = true})
            test.eq((disagreeing).outcome, "uncertain")
            test.eq((disagreeing).answer, "42")
            local untrusted = settle.decide({terminal = terminal, exit = {code = 3, signal = nil, uncertain = false}, stream_ended = false, drained = true, exit_codes_trustworthy = false})
            test.eq((untrusted).outcome, "succeeded")
            test.is_true((untrusted).exit_reconciled)
        end)
        test.it("decides a stream that ended without a result envelope only after exit and the drain", function()
            local ended: driver_types.Terminal = {outcome = "uncertain", answer = nil, resume_ref = "s1", usage = nil,
                error = {code = "stream_ended", message = "the stream ended without a result envelope", retryable = false}}
            local exited = {code = 143, signal = nil, uncertain = false}
            test.is_nil(settle.decide({terminal = ended, stream_ended = true, exit = nil, drained = false, exit_codes_trustworthy = false}))
            test.is_nil(settle.decide({terminal = ended, stream_ended = true, exit = nil, drained = true, exit_codes_trustworthy = false}))
            test.is_nil(settle.decide({terminal = ended, stream_ended = true, exit = exited, drained = false, exit_codes_trustworthy = false}))
            local settled = settle.decide({terminal = ended, stream_ended = true, exit = exited, drained = true, exit_codes_trustworthy = false})
            if not settled then error("exit and drain decide the ended stream") end
            test.eq(settled.outcome, "uncertain")
            test.eq(settled.resume_ref, "s1")
            test.is_true(settled.exit_reconciled)
            test.eq(settled.reason, "the stream ended without a result envelope")
        end)
        test.it("settles a child stopped on request without a result envelope as cancelled", function()
            local stopped = {code = nil, signal = nil, uncertain = true, stopped = true}
            local bare = settle.decide({terminal = nil, stream_ended = false, exit = stopped, drained = true, exit_codes_trustworthy = false})
            test.eq((bare).outcome, "cancelled")
            test.is_nil(settle.decide({terminal = nil, stream_ended = false, exit = stopped, drained = false, exit_codes_trustworthy = false}))
            local ended: driver_types.Terminal = {outcome = "uncertain", answer = nil, resume_ref = "s1", usage = nil,
                error = {code = "stream_ended", message = "the stream ended without a result envelope", retryable = false}}
            local cut = settle.decide({terminal = ended, stream_ended = true, exit = stopped, drained = true, exit_codes_trustworthy = false})
            test.eq((cut).outcome, "cancelled")
            test.eq((cut).resume_ref, "s1")
            -- A result the driver reported before the stop still decides.
            local answered: driver_types.Terminal = {outcome = "succeeded", answer = "done", resume_ref = nil, usage = nil, error = nil}
            local finished = settle.decide({terminal = answered, stream_ended = false, exit = stopped, drained = true, exit_codes_trustworthy = false})
            test.eq((finished).outcome, "succeeded")
        end)
        test.it("preserves canonical payload and stable event keys across old and new implementation", function()
            local binding_id = "bind-gateway-123"
            local turn_id = "turn-action-456"
            local item = make_valid_item("evt-001", "UserPromptSubmit", false)

            local batch1, err1 = hook_records.batch(binding_id, turn_id, {item})
            test.is_nil(err1)
            if not batch1 then error("batch1 is nil") end
            test.eq(#batch1.records, 1)
            test.eq(#batch1.event_ids, 1)
            test.eq(batch1.event_ids[1], "evt-001")
            test.eq(batch1.activity, "Working")

            local ref1 = reference_hook_record(binding_id, turn_id, item)
            test.eq(batch1.records[1].source, ref1.source)
            test.eq(batch1.records[1].turn_id, ref1.turn_id)
            test.eq((assert(bounds.object(batch1.records[1].body))).event_key, "hook:" .. binding_id .. ":UserPromptSubmit:turn:prompt-1")
            test.eq((assert(bounds.object(batch1.records[1].body))).event_key, (assert(bounds.object(ref1.body))).event_key)

            local data1 = assert(bounds.object((assert(bounds.object(batch1.records[1].body))).data))
            local ref_data1 = assert(bounds.object((assert(bounds.object(ref1.body))).data))
            test.eq(data1.event_name, "bee.harness.hook")
            test.eq(data1.event_revision, "1")
            test.eq(data1.payload_json, ref_data1.payload_json)

            -- Replay produces byte-for-byte identical canonical payload and keys
            local batch2, err2 = hook_records.batch(binding_id, turn_id, {item})
            test.is_nil(err2)
            if not batch2 then error("batch2 is nil") end
            local data2 = assert(bounds.object((assert(bounds.object(batch2.records[1].body))).data))
            test.eq(data2.payload_json, data1.payload_json)
            test.eq((assert(bounds.object(batch2.records[1].body))).event_key, (assert(bounds.object(batch1.records[1].body))).event_key)

            -- Optional turn_id: when omitted/nil, record carries no turn_id, but payload_json is byte-for-byte identical
            local batch_noturn, err_noturn = hook_records.batch(binding_id, nil, {item})
            test.is_nil(err_noturn)
            if not batch_noturn then error("batch_noturn is nil") end
            test.is_nil(batch_noturn.records[1].turn_id)
            local ref_noturn = reference_hook_record(binding_id, nil, item)
            test.is_nil(ref_noturn.turn_id)
            local data_noturn = assert(bounds.object((assert(bounds.object(batch_noturn.records[1].body))).data))
            test.eq(data_noturn.payload_json, data1.payload_json)

            -- Ambiguous event key uses hook:<event_id>. A stop's ambiguity is
            -- occurrence identity only: a prompt may stop more than once, so
            -- the stop cannot be merged, but it still reports that activity
            -- ended rather than that what happened is unknown.
            local amb_item = make_valid_item("evt-002", "Stop", true)
            local batch_amb, err_amb = hook_records.batch(binding_id, nil, {amb_item})
            test.is_nil(err_amb)
            if not batch_amb then error("batch_amb is nil") end
            test.eq(batch_amb.activity, "Stopped")
            -- A stop reports that the harness ended its turn: beside the hook
            -- record it carries a hook-sourced turn signal, which is what a
            -- thread notice watching the session recognizes. A stop failure
            -- ends the turn as failed. Only the hook is acknowledged.
            test.eq(#batch_amb.records, 2)
            test.eq(#batch_amb.event_ids, 1)
            local signal_record = batch_amb.records[2]
            test.eq(signal_record.source, "hook")
            local signal_body = assert(bounds.object(signal_record.body))
            test.eq(signal_body.type, "turn.signal")
            test.eq(signal_body.event_key, "hook:evt-002:turn")
            test.eq((assert(bounds.object(signal_body.data))).phase, "ended")
            test.is_nil((assert(bounds.object(signal_body.data))).reported_outcome)
            local failed_stop = hook_records.batch(binding_id, turn_id, {make_valid_item("evt-004", "StopFailure", true)})
            if not failed_stop then error("failed_stop is nil") end
            test.eq(#failed_stop.records, 2)
            test.eq(failed_stop.records[2].turn_id, turn_id)
            test.eq((assert(bounds.object((assert(bounds.object(failed_stop.records[2].body))).data))).reported_outcome, "failed")
            -- An activity that describes a specific occurrence cannot be
            -- attributed without that occurrence's identity.
            local untagged_tool = make_valid_item("evt-003", "PreToolUse", true)
            local batch_untagged = hook_records.batch(binding_id, nil, {untagged_tool})
            if not batch_untagged then error("batch_untagged is nil") end
            test.eq(batch_untagged.activity, "Activity uncertain")
            -- A captured turn ends with its stop: the sequence is not
            -- uncertain merely because the stop has no stable identity.
            local sequence = {make_valid_item("evt-010", "UserPromptSubmit", false), make_valid_item("evt-011", "PreToolUse", false),
                make_valid_item("evt-012", "PostToolUse", false), make_valid_item("evt-013", "Stop", true)}
            local batch_sequence = hook_records.batch(binding_id, nil, sequence)
            if not batch_sequence then error("batch_sequence is nil") end
            test.eq(batch_sequence.activity, "Stopped")
            test.eq((assert(bounds.object(batch_amb.records[1].body))).event_key, "hook:evt-002")
            local ref_amb = reference_hook_record(binding_id, nil, amb_item)
            test.eq((assert(bounds.object(batch_amb.records[1].body))).event_key, (assert(bounds.object(ref_amb.body))).event_key)
            test.eq((assert(bounds.object((assert(bounds.object(batch_amb.records[1].body))).data))).payload_json, (assert(bounds.object((assert(bounds.object(ref_amb.body))).data))).payload_json)

            -- Multiple items up to 16 preserve order, event_ids and payloads
            local items: {Object} = {}
            for i = 1, 16 do
                local it = make_valid_item(string.format("evt-%03d", i), "PreToolUse", false)
                it.sequence = i
                items[i] = it
            end
            local batch_multi, err_multi = hook_records.batch(binding_id, turn_id, items)
            test.is_nil(err_multi)
            if not batch_multi then error("batch_multi is nil") end
            test.eq(#batch_multi.records, 16)
            test.eq(#batch_multi.event_ids, 16)
            for i = 1, 16 do
                test.eq(batch_multi.event_ids[i], string.format("evt-%03d", i))
                local ref_i = reference_hook_record(binding_id, turn_id, items[i])
                test.eq((assert(bounds.object((assert(bounds.object(batch_multi.records[i].body))).data))).payload_json, (assert(bounds.object((assert(bounds.object(ref_i.body))).data))).payload_json)
            end

            -- Empty items list produces empty batch without error
            local empty_batch, empty_err = hook_records.batch(binding_id, turn_id, {})
            test.is_nil(empty_err)
            if not empty_batch then error("empty_batch is nil") end
            test.eq(#empty_batch.records, 0)
            test.eq(#empty_batch.event_ids, 0)

            -- Normalized fields through gateway normalize preserve valid payload bytes
            local submission, norm_err = gateway_hooks.normalize("UserPromptSubmit", {
                session_id = "sess-norm",
                turn_id = "turn-norm",
                prompt = "test prompt text",
                -- The intake already accepts finite numeric observations;
                -- record decoding must not strand one after admission.
                duration_ms = -1,
                tool_name = "tool_1",
            })
            test.is_nil(norm_err)
            if not submission then error("normalize failed") end
            local norm_item = {
                event_id = "evt-norm-01",
                event = submission.event,
                occurrence = submission.occurrence,
                ambiguous = submission.ambiguous,
                provenance = "codex:hook_engine",
                sequence = 5,
                fields = submission.fields,
            }
            local batch_norm, err_norm = hook_records.batch(binding_id, turn_id, {norm_item})
            test.is_nil(err_norm)
            if not batch_norm then error("batch_norm is nil") end
            local ref_norm = reference_hook_record(binding_id, turn_id, norm_item)
            test.eq((assert(bounds.object((assert(bounds.object(batch_norm.records[1].body))).data))).payload_json, (assert(bounds.object((assert(bounds.object(ref_norm.body))).data))).payload_json)
        end)
        test.it("rejects malformed hook claims at the unknown boundary without silent skip or fallback", function()
            local binding_id = "bind-gateway-123"
            local turn_id = "turn-action-456"

            -- Invalid binding_id
            test.is_nil(hook_records.batch("", turn_id, {make_valid_item("e1", "SessionStart", false)}))
            test.is_nil(hook_records.batch("bad\0id", turn_id, {make_valid_item("e1", "SessionStart", false)}))

            -- Invalid turn_id
            test.is_nil(hook_records.batch(binding_id, "", {make_valid_item("e1", "SessionStart", false)}))
            test.is_nil(hook_records.batch(binding_id, "turn\0bad", {make_valid_item("e1", "SessionStart", false)}))

            -- Items not a table
            test.is_nil(hook_records.batch(binding_id, turn_id, "not a table"))
            test.is_nil(hook_records.batch(binding_id, turn_id, 123))
            test.is_nil(hook_records.batch(binding_id, turn_id, true))

            -- Sparse / non-dense list
            test.is_nil(hook_records.batch(binding_id, turn_id, {[1] = make_valid_item("e1", "SessionStart", false), [3] = make_valid_item("e2", "SessionStart", false)}))
            test.is_nil(hook_records.batch(binding_id, turn_id, {a = make_valid_item("e1", "SessionStart", false)}))

            -- Exceeds limit of 16 claimed hooks
            local too_many: {Object} = {}
            for i = 1, 17 do
                too_many[i] = make_valid_item(string.format("evt-%03d", i), "PreToolUse", false)
            end
            test.is_nil(hook_records.batch(binding_id, turn_id, too_many))

            -- Duplicate event_id in claim
            local dup_items = {
                make_valid_item("evt-repeat", "PreToolUse", false),
                make_valid_item("evt-repeat", "PostToolUse", false),
            }
            test.is_nil(hook_records.batch(binding_id, turn_id, dup_items))

            -- Item not an object
            test.is_nil(hook_records.batch(binding_id, turn_id, {"not an object"}))

            -- Unknown top-level field
            local with_extra = make_valid_item("e1", "SessionStart", false)
            with_extra.malicious = "injection"
            test.is_nil(hook_records.batch(binding_id, turn_id, {with_extra}))

            -- Missing or invalid event_id
            local bad_eid1 = make_valid_item("e1", "SessionStart", false)
            bad_eid1.event_id = ""
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_eid1}))
            local bad_eid2 = make_valid_item("e1", "SessionStart", false)
            bad_eid2.event_id = 123
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_eid2}))
            local bad_eid3 = make_valid_item("e1", "SessionStart", false)
            bad_eid3.event_id = "id\0ctrl"
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_eid3}))

            -- Unknown hook event
            local bad_ev = make_valid_item("e1", "NonExistentEvent", false)
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_ev}))

            -- Invalid occurrence
            local bad_occ1 = make_valid_item("e1", "SessionStart", false)
            bad_occ1.occurrence = ""
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_occ1}))
            local bad_occ2 = make_valid_item("e1", "SessionStart", false)
            bad_occ2.occurrence = "occ\0ctrl"
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_occ2}))

            -- Invalid ambiguous
            local bad_amb = make_valid_item("e1", "SessionStart", false)
            bad_amb.ambiguous = "true"
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_amb}))

            -- Invalid provenance
            local bad_prov = make_valid_item("e1", "SessionStart", false)
            bad_prov.provenance = ""
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_prov}))

            -- Invalid sequence
            local bad_seq = make_valid_item("e1", "SessionStart", false)
            bad_seq.sequence = -1
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_seq}))

            -- Invalid digest / created_at
            local bad_dig = make_valid_item("e1", "SessionStart", false)
            bad_dig.digest = "not\0valid"
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_dig}))
            local bad_time = make_valid_item("e1", "SessionStart", false)
            bad_time.created_at = "time\0ctrl"
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_time}))

            -- Missing or non-table fields
            local no_fields = make_valid_item("e1", "SessionStart", false)
            no_fields.fields = nil
            test.is_nil(hook_records.batch(binding_id, turn_id, {no_fields}))
            local str_fields = make_valid_item("e1", "SessionStart", false)
            str_fields.fields = "not a table"
            test.is_nil(hook_records.batch(binding_id, turn_id, {str_fields}))

            -- Event mismatch between item and fields
            local mis_event = make_valid_item("e1", "SessionStart", false)
            mis_event.fields = {event = "SessionEnd"}
            test.is_nil(hook_records.batch(binding_id, turn_id, {mis_event}))

            -- Unknown field in fields
            local extra_in_fields = make_valid_item("e1", "SessionStart", false)
            extra_in_fields.fields = {event = "SessionStart", unauthorized = "field"}
            test.is_nil(hook_records.batch(binding_id, turn_id, {extra_in_fields}))

            -- Raw content field leaked into fields
            local leak_fields = make_valid_item("e1", "UserPromptSubmit", false)
            leak_fields.fields = {event = "UserPromptSubmit", prompt = "leaked text"}
            test.is_nil(hook_records.batch(binding_id, turn_id, {leak_fields}))

            -- Invalid content_sizes
            local bad_cs = make_valid_item("e1", "UserPromptSubmit", false)
            bad_cs.fields = {event = "UserPromptSubmit", content_sizes = "not a table"}
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_cs}))
            local bad_cs_key = make_valid_item("e1", "UserPromptSubmit", false)
            bad_cs_key.fields = {event = "UserPromptSubmit", content_sizes = {unknown_content = 10}}
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_cs_key}))
            local bad_cs_val = make_valid_item("e1", "UserPromptSubmit", false)
            bad_cs_val.fields = {event = "UserPromptSubmit", content_sizes = {prompt = -5}}
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_cs_val}))

            -- Invalid content_digests
            local bad_cd = make_valid_item("e1", "UserPromptSubmit", false)
            bad_cd.fields = {event = "UserPromptSubmit", content_digests = "not a table"}
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_cd}))
            local bad_cd_key = make_valid_item("e1", "UserPromptSubmit", false)
            bad_cd_key.fields = {event = "UserPromptSubmit", content_digests = {unknown_content = string.rep("a", 64)}}
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_cd_key}))
            local bad_cd_hex = make_valid_item("e1", "UserPromptSubmit", false)
            bad_cd_hex.fields = {event = "UserPromptSubmit", content_digests = {prompt = "not_valid_hex_digest_too_short"}}
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_cd_hex}))

            -- Invalid claim fields / enum fields / scalar fields in fields
            local bad_sess = make_valid_item("e1", "SessionStart", false)
            bad_sess.fields = {event = "SessionStart", session_id = ""}
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_sess}))
            local bad_enum = make_valid_item("e1", "SessionStart", false)
            bad_enum.fields = {event = "SessionStart", source = "invalid_source"}
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_enum}))
            local bad_bool = make_valid_item("e1", "Stop", true)
            bad_bool.fields = {event = "Stop", stop_hook_active = "not a bool"}
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_bool}))
            local bad_num = make_valid_item("e1", "PostToolUse", false)
            bad_num.fields = {event = "PostToolUse", duration_ms = "slow"}
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_num}))
            local bad_tool = make_valid_item("e1", "PreToolUse", false)
            bad_tool.fields = {event = "PreToolUse", tool_name = "has space"}
            test.is_nil(hook_records.batch(binding_id, turn_id, {bad_tool}))
        end)
    end)
end
return test.run_cases(define_tests)
