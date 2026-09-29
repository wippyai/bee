local test = require("test")
local protocol = require("protocol")

local function succeeded(): {[string]: unknown}
    return {outcome = "succeeded", schema = "bee:Text@1", value = {text = "done"}, artifacts = {}, usage = {}}
end

local function work_await(tag: string): {[string]: unknown}
    local value: {[string]: unknown} = {subject_kind = "work", subject = "bw:n:w:w1", cursor = "c1", tag = tag}
    if tag == "ready" then value.result = succeeded()
    elseif tag == "pending" then value.reason = "timeout"
    elseif tag == "blocked" then value.blocker = {kind = "budget", message = "over", subject = "bw:n:w:w1", actions = {}}
    else value.evidence = {summary = "unknown", artifacts = {}} end
    return value
end

local function define_tests()
    test.describe("Sessions protocol decoders", function()
        test.it("accepts exactly the four await branches for a work", function()
            for _, tag in ipairs({"ready", "pending", "blocked", "uncertain"}) do
                local decoded, failure = protocol.decode_work_await(work_await(tag))
                test.is_nil(failure)
                test.eq(decoded and decoded.tag, tag)
            end
        end)

        test.it("rejects an await carrying a second branch or none", function()
            local both = work_await("ready")
            both.reason = "timeout"
            test.is_nil(protocol.decode_work_await(both))
            local bare = work_await("pending")
            bare.reason = nil
            test.is_nil(protocol.decode_work_await(bare))
            local wrong_kind = work_await("ready")
            wrong_kind.subject_kind = "operation"
            test.is_nil(protocol.decode_work_await(wrong_kind))
            local extra = work_await("ready")
            extra.extra = 1
            test.is_nil(protocol.decode_work_await(extra))
        end)

        test.it("keeps a settled result off unsettled work state", function()
            local sender = {kind = "session", id = "bs:n:w:lead"}
            local base: {[string]: unknown} = {work = "bw:n:w:w1", session = "bs:n:w:s1", sender = sender, revision = 1, cancelling = false, phase = "accepted"}
            local state = assert(protocol.decode_work_state(base))
            test.eq(state.phase, "accepted")
            test.eq(state.sender.kind, "session")
            test.eq(state.sender.id, "bs:n:w:lead")
            base.sender = nil
            test.is_nil(protocol.decode_work_state(base))
            base.sender = sender
            base.result = succeeded()
            test.is_nil(protocol.decode_work_state(base))
            local settled: {[string]: unknown} = {work = "bw:n:w:w1", session = "bs:n:w:s1", sender = sender, revision = 2, cancelling = false,
                phase = "settled", result = succeeded()}
            local done = assert(protocol.decode_work_state(settled))
            test.eq(done.phase, "settled")
            settled.result = nil
            test.is_nil(protocol.decode_work_state(settled))
            settled.result = succeeded()
            settled.cancelling = true
            test.is_nil(protocol.decode_work_state(settled))
        end)

        test.it("decodes unsuccessful results with their fault", function()
            local result = assert(protocol.decode_result({outcome = "rejected", artifacts = {},
                error = {code = "OUTPUT_INVALID", message = "invalid", retry = "never", operation = "bo:n:w:o1"}}))
            test.eq(result.outcome, "rejected")
            test.is_nil(protocol.decode_result({outcome = "rejected", artifacts = {}}))
            test.is_nil(protocol.decode_result({outcome = "unknown", artifacts = {}, error = {code = "X", message = "m", retry = "never"}}))
        end)

        test.it("checks qualified refs by kind", function()
            test.eq(protocol.ref("work", "bw:n:w:w1"), "bw:n:w:w1")
            test.is_nil(protocol.ref("work", "bs:n:w:s1"))
            test.is_nil(protocol.ref("work", "bw:n:w"))
            test.is_nil(protocol.ref("work", "bw:n:w:w1:extra"))
            test.eq(protocol.subject_kind("bo:n:w:o1"), "operation")
            test.is_nil(protocol.subject_kind("bs:n:w:s1"))
        end)

        test.it("requires join values exactly when the join succeeded", function()
            local base: {[string]: unknown} = {subject_kind = "join", subject = "bj:n:w:j1", cursor = "c1", tag = "ready",
                children = {work_await("ready")}, result = {succeeded = true, winners = {"bw:n:w:w1"}, values = {{text = "done"}}}}
            test.not_nil(protocol.decode_join_await(base))
            base.result = {succeeded = true, winners = {"bw:n:w:w1"}}
            test.is_nil(protocol.decode_join_await(base))
            base.result = {succeeded = false, winners = {}, values = {}}
            test.is_nil(protocol.decode_join_await(base))
            base.result = {succeeded = false, winners = {}}
            test.not_nil(protocol.decode_join_await(base))
        end)

        test.it("closes the owner envelope", function()
            test.not_nil(protocol.decode_reply({ok = true, value = {}}))
            test.is_nil(protocol.decode_reply({ok = true, value = {}, error = {}}))
            test.is_nil(protocol.decode_reply({ok = false}))
            local refusal = assert(protocol.decode_reply({ok = false, error = {code = "DENIED", message = "no", retry = "never", operation_key = "k"}}))
            test.eq(refusal.ok, false)
            test.is_nil(protocol.decode_reply({ok = false, error = {code = "DENIED", message = "no", retry = "later"}}))
        end)

        test.it("renders faults as readable text", function()
            local fault = protocol.fault("DENIED", "session is not admitted", "never", nil)
            test.eq(tostring(fault), "DENIED: session is not admitted")
        end)

        test.it("bounds inline JSON by bytes and depth", function()
            test.is_true(protocol.json({text = "x"}))
            test.is_false(protocol.json(nil))
            test.is_false(protocol.json({text = string.rep("x", protocol.MAX_VALUE_BYTES + 1)}))
            local deep: {[string]: unknown} = {}
            local cursor = deep
            for _ = 1, protocol.MAX_VALUE_DEPTH + 1 do
                local child: {[string]: unknown} = {}
                cursor.next = child
                cursor = child
            end
            test.is_false(protocol.json(deep))
        end)
    end)
end

return test.run_cases(define_tests)
