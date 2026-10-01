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
        test.it("decodes ordered history and rejects mixed refs, cursors and unknown fields", function()
            local row: {[string]: unknown} = {work = "bw:n:w:one", sequence = 1, input = "hello", created_at = "2026-09-30T12:00:00.000Z"}
            local page: {[string]: unknown} = {items = {row}, next = 1}
            local decoded = assert(protocol.decode_history(page))
            test.eq(decoded.items[1].input, "hello")
            page.next = 2
            test.is_nil(protocol.decode_history(page))
            page.next = 1
            row.work = "bs:n:w:one"
            test.is_nil(protocol.decode_history(page))
            row.work = "bw:n:w:one"
            row.sender = "forged"
            test.is_nil(protocol.decode_history(page))
            row.sender = nil
            page.items = {row, row}
            test.is_nil(protocol.decode_history(page))
        end)

        test.it("decodes provider usage counts and rejects malformed usage", function()
            local result = succeeded()
            result.usage = {input_tokens = 2, output_tokens = 4, cached_tokens = 10}
            local decoded = assert(protocol.decode_result(result))
            test.eq(decoded.usage.output_tokens, 4)
            result.usage = {input_tokens = -1}
            test.is_nil(protocol.decode_result(result))
            result.usage = {cost_decimal = "1.2"}
            test.is_nil(protocol.decode_result(result))
        end)
        test.it("accepts only the optional work budget fields", function()
            local decoded = assert(protocol.decode_budget({provider_steps = 8, tokens = 12000, wall_time_ms = 90000}))
            test.eq(decoded.provider_steps, 8)
            test.eq(decoded.tokens, 12000)
            test.eq(decoded.wall_time_ms, 90000)
            test.is_nil(protocol.decode_budget({}))
            test.is_nil(protocol.decode_budget({turn_budget = 8}))
            test.is_nil(protocol.decode_budget({tokens = -1}))
        end)
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

        test.it("decodes a budget-exceeded result with placement evidence", function()
            local result = assert(protocol.decode_result({outcome = "budget_exceeded", artifacts = {},
                error = {code = "BUDGET_EXCEEDED", message = "wall_time_ms exceeded", retry = "never"},
                evidence = {summary = "placement proved the CLI exited after the budget", artifacts = {"attempt bturn:n:w:t1", "exit observed by runner"}}}))
            test.eq(result.outcome, "budget_exceeded")
            test.eq(result.evidence.summary, "placement proved the CLI exited after the budget")
            test.is_nil(protocol.decode_result({outcome = "budget_exceeded", artifacts = {},
                error = {code = "BUDGET_EXCEEDED", message = "limit", retry = "never"}}))
        end)

        test.it("keeps quiet-period evidence on a stalled session snapshot", function()
            local snapshot = {session = "bs:n:w:s1", revision = 1, incarnation = 1, title = "quiet",
                lifecycle = "active", activity = "stalled", execution = {state = "running",
                    evidence_at = "2026-09-30T12:00:00.000Z", stale = false}, queue_count = 0, effective_limits = {},
                continuity = {mode = "provider_resume"}, actions = {},
                activity_evidence = {kind = "quiet", turn = "bturn:n:w:t1", last_progress_at_ms = 1000,
                    quiet_period_ms = 5000, quiet_for_ms = 6000}}
            local decoded = assert(protocol.decode_snapshot(snapshot))
            test.eq(decoded.activity, "stalled")
            test.eq(decoded.activity_evidence and decoded.activity_evidence.turn, "bturn:n:w:t1")
            test.eq(decoded.activity_evidence and decoded.activity_evidence.quiet_for_ms, 6000)
        end)

        test.it("decodes a session snapshot after a budget-exceeded work result", function()
            local snapshot = {session = "bs:n:w:s1", revision = 2, incarnation = 1, title = "bounded",
                lifecycle = "active", activity = "idle", execution = {state = "quiescent",
                    evidence_at = "2026-09-30T12:00:00.000Z", stale = false}, queue_count = 0, effective_limits = {},
                continuity = {mode = "provider_resume"}, actions = {},
                last_result = {work = "bw:n:w:w1", outcome = "budget_exceeded", summary = "tokens exceeded",
                    at = "2026-09-30T12:00:00.000Z"}}
            local decoded = assert(protocol.decode_snapshot(snapshot))
            test.eq(decoded.last_result and decoded.last_result.outcome, "budget_exceeded")
        end)

        test.it("retains the saved profile revision and rejects malformed profile references", function()
            local snapshot: {[string]: unknown} = {session = "bs:n:w:s1", revision = 1, incarnation = 1, title = "saved",
                lifecycle = "closed", activity = "idle", execution = {state = "quiescent",
                    evidence_at = "2026-09-30T12:00:00.000Z", stale = false}, queue_count = 0, effective_limits = {},
                continuity = {mode = "provider_resume"}, actions = {}, saved_profile = {id = "careful", revision = 3}}
            local decoded, err = protocol.decode_snapshot(snapshot)
            if not decoded then error(tostring(err)) end
            test.eq(decoded.saved_profile and decoded.saved_profile.id, "careful")
            test.eq(decoded.saved_profile and decoded.saved_profile.revision, 3)
            for _, invalid in ipairs({{id = "careful", revision = 0}, {id = "careful", revision = 1.5},
                {id = "", revision = 3}, {id = "careful", revision = 3, extra = true}}) do
                snapshot.saved_profile = invalid
                test.is_nil(protocol.decode_snapshot(snapshot))
            end
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
