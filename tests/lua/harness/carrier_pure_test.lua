-- MIT. The carrier's pure rules: provenance round-trips and keys ignore
-- chunking; checkpoints decode exactly and only move forward; settlement
-- follows the terminal envelope and never process exit alone.
local test = require("test")
local provenance = require("provenance")
local checkpoint = require("checkpoint")
local settle = require("settle")
local driver_types = require("driver_types")
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
    end)
end
return test.run_cases(define_tests)
