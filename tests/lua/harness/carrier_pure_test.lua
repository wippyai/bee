-- MIT. The carrier's pure rules: provenance round-trips and keys ignore
-- chunking; checkpoints decode exactly and only move forward; settlement
-- follows the terminal envelope and never process exit alone.
local test = require("test")
local provenance = require("provenance")
local checkpoint = require("checkpoint")
local settle = require("settle")
local driver_types = require("driver_types")
local hook_records = require("hook_records")
local gateway_hooks = require("gateway_hooks")
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
            local kept = checkpoint.new(pinned, 1) :: {[string]: unknown}
            kept.output = "truncated"
            local decoded_kept, kept_error = checkpoint.decode(kept)
            if not decoded_kept then error(tostring(kept_error)) end
            test.eq(decoded_kept.output, "truncated")
            kept.output = "unobserved"
            local _, conclusion_error = checkpoint.decode(kept)
            test.eq(conclusion_error, "output must be open, complete or truncated")
            local loose = checkpoint.new(pinned, 1) :: {[string]: unknown}
            loose.extra = true
            test.is_nil(checkpoint.decode(loose))
            local wrong = checkpoint.new(pinned, 1)
            wrong.schema_revision = "bee.carrier.checkpoint@0"
            test.is_nil(checkpoint.decode(wrong))
        end)
        test.it("settles from the terminal envelope and never from exit alone", function()
            local terminal: driver_types.Terminal = {outcome = "succeeded", answer = "42", resume_ref = "s1", usage = nil, error = nil}
            local settled = settle.decide({terminal = terminal, exit = nil, drained = false, exit_codes_trustworthy = false})
            if not settled then error("terminal envelope decides") end
            test.eq(settled.outcome, "succeeded")
            test.eq(settled.answer, "42")
            test.is_false(settled.exit_reconciled)
            test.is_nil(settle.decide({terminal = nil, exit = {code = 0, signal = nil, uncertain = false}, drained = false, exit_codes_trustworthy = false}))
            local missing = settle.decide({terminal = nil, exit = {code = 0, signal = nil, uncertain = false}, drained = true, exit_codes_trustworthy = false})
            if not missing then error("drained exit decides") end
            test.eq(missing.outcome, "uncertain")
            local killed = settle.decide({terminal = nil, exit = {code = 137, signal = 9, uncertain = false}, drained = true, exit_codes_trustworthy = false})
            test.eq((killed :: settle.Settlement).outcome, "cancelled")
            local disagreeing = settle.decide({terminal = terminal, exit = {code = 3, signal = nil, uncertain = false}, drained = true, exit_codes_trustworthy = true})
            test.eq((disagreeing :: settle.Settlement).outcome, "uncertain")
            test.eq((disagreeing :: settle.Settlement).answer, "42")
            local untrusted = settle.decide({terminal = terminal, exit = {code = 3, signal = nil, uncertain = false}, drained = true, exit_codes_trustworthy = false})
            test.eq((untrusted :: settle.Settlement).outcome, "succeeded")
            test.is_true((untrusted :: settle.Settlement).exit_reconciled)
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
            test.eq((batch1.records[1].body :: Object).event_key, "hook:" .. binding_id .. ":UserPromptSubmit:turn:prompt-1")
            test.eq((batch1.records[1].body :: Object).event_key, (ref1.body :: Object).event_key)

            local data1 = (batch1.records[1].body :: Object).data :: Object
            local ref_data1 = (ref1.body :: Object).data :: Object
            test.eq(data1.event_name, "bee.harness.hook")
            test.eq(data1.event_revision, "1")
            test.eq(data1.payload_json, ref_data1.payload_json)

            -- Replay produces byte-for-byte identical canonical payload and keys
            local batch2, err2 = hook_records.batch(binding_id, turn_id, {item})
            test.is_nil(err2)
            if not batch2 then error("batch2 is nil") end
            local data2 = (batch2.records[1].body :: Object).data :: Object
            test.eq(data2.payload_json, data1.payload_json)
            test.eq((batch2.records[1].body :: Object).event_key, (batch1.records[1].body :: Object).event_key)

            -- Optional turn_id: when omitted/nil, record carries no turn_id, but payload_json is byte-for-byte identical
            local batch_noturn, err_noturn = hook_records.batch(binding_id, nil, {item})
            test.is_nil(err_noturn)
            if not batch_noturn then error("batch_noturn is nil") end
            test.is_nil(batch_noturn.records[1].turn_id)
            local ref_noturn = reference_hook_record(binding_id, nil, item)
            test.is_nil(ref_noturn.turn_id)
            local data_noturn = (batch_noturn.records[1].body :: Object).data :: Object
            test.eq(data_noturn.payload_json, data1.payload_json)

            -- Ambiguous event key uses hook:<event_id>
            local amb_item = make_valid_item("evt-002", "Stop", true)
            local batch_amb, err_amb = hook_records.batch(binding_id, nil, {amb_item})
            test.is_nil(err_amb)
            if not batch_amb then error("batch_amb is nil") end
            test.eq(batch_amb.activity, "Activity uncertain")
            test.eq((batch_amb.records[1].body :: Object).event_key, "hook:evt-002")
            local ref_amb = reference_hook_record(binding_id, nil, amb_item)
            test.eq((batch_amb.records[1].body :: Object).event_key, (ref_amb.body :: Object).event_key)
            test.eq(((batch_amb.records[1].body :: Object).data :: Object).payload_json, ((ref_amb.body :: Object).data :: Object).payload_json)

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
                test.eq(((batch_multi.records[i].body :: Object).data :: Object).payload_json, ((ref_i.body :: Object).data :: Object).payload_json)
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
            test.eq(((batch_norm.records[1].body :: Object).data :: Object).payload_json, ((ref_norm.body :: Object).data :: Object).payload_json)
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
