-- MIT. Launch work remains in the thread journal and settles per WorkRef.
local test = require("test")
local harness = require("harness")
local owner_store = require("owner")
local WORKSPACE = string.rep("a", 32)

local function result(state: string, value: unknown?): {[string]: unknown}
    local settled: {[string]: unknown} = {state = state}
    if state == "succeeded" then
        settled.schema = "bee:Text@1"
        settled.value = value or {text = "done"}
    else
        settled.error = {code = "FAILED", message = "work failed"}
    end
    return settled
end

local function define_tests()
    test.describe("Threads canonical session work store", function()
        test.it("pages immutable history and associates the last result with its session thread", function()
            local sessions = harness.session_owner(WORKSPACE)
            local opened = harness.value(sessions:call("session_create", {operation_key = harness.key(), route = {provider = "fixture"}}))
            local first = harness.value(sessions:call("work_send", {session = opened.session, input = "one", operation_key = harness.key()}))
            harness.value(sessions:call("work_send", {session = opened.session, input = "two", operation_key = harness.key()}))
            local page = harness.value(sessions:call("work_history", {session = opened.session, limit = 1}))
            test.eq(page.items[1].work, first.work)
            test.eq(page.items[1].input, "one")
            test.not_nil(page.next)
            local next_page = harness.value(sessions:call("work_history", {session = opened.session, limit = 1, cursor = page.next}))
            test.eq(next_page.items[1].input, "two")
            test.is_nil(next_page.next)
            local turn = harness.value(sessions:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
            local pulled = harness.value(sessions:call("turn_pull", {turn = turn.turn, claim = turn.claim}))
            harness.value(sessions:call("turn_accept", {turn = turn.turn, claim = turn.claim, input_digest = pulled.input_digest, checkpoint = {}, operation_key = harness.key()}))
            harness.value(sessions:call("work_settle", {turn = turn.turn, claim = turn.claim, result = result("succeeded", {text = "answer"}), operation_key = harness.key()}))
            local snapshot = harness.value(sessions:call("session_describe", {session = opened.session}))
            test.eq(snapshot.thread_ref, snapshot.route.thread_id)
            test.eq(snapshot.workspace, WORKSPACE)
            test.eq(snapshot.last_result.work, first.work)
            test.eq(snapshot.last_result.summary, "answer")
        end)
        test.it("lets the node scheduler reserve and settle workspace-homed work without a home identity", function()
            local sessions = harness.session_owner(WORKSPACE)
            local opened = harness.value(sessions:call("session_create", {operation_key = harness.key()}))
            local sent = harness.value(sessions:call("work_send", {session = opened.session, input = "node turn", operation_key = harness.key()}))
            local node = harness.session_owner()
            local turn = harness.value(node:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
            test.eq(turn.work, sent.work)
            local pulled = harness.value(node:call("turn_pull", {turn = turn.turn, claim = turn.claim}))
            harness.value(node:call("turn_accept", {turn = turn.turn, claim = turn.claim, input_digest = pulled.input_digest, checkpoint = {}, operation_key = harness.key()}))
            harness.value(node:call("work_settle", {turn = turn.turn, claim = turn.claim, result = result("succeeded"), operation_key = harness.key()}))
            test.eq(harness.value(sessions:call("work_describe", {work = sent.work})).phase, "settled")
        end)
        test.it("keeps cross-workspace visibility separate from mutation authority", function()
            local other_workspace = "cccccccccccccccccccccccccccccccc"
            local other = harness.session_owner(other_workspace)
            local opened = harness.value(other:call("session_create", {operation_key = harness.key(), title = "peer"}))
            local local_owner = harness.session_owner(WORKSPACE)
            test.eq(harness.code(local_owner:call("session_describe", {session = opened.session})), "NOT_FOUND")
            local reader = harness.principal("reader", {"bee.threads:session_owner_test_policy", "bee.security.threads:thread_workspace_list_policy"}, WORKSPACE)
            test.eq(harness.value(reader:call("session_describe", {session = opened.session})).workspace, other_workspace)
            test.eq(harness.code(reader:call("work_send", {session = opened.session, input = "hello", operation_key = harness.key()})), "DENIED")
            local sender = harness.principal("sender", {"bee.threads:session_owner_test_policy", "bee.threads:sessions_other_workspace_test_policy"}, WORKSPACE)
            local sent = harness.value(sender:call("work_send", {session = opened.session, input = "hello", operation_key = harness.key()}))
            test.is_true(sent.work:find(":" .. other_workspace .. ":", 1, true) ~= nil)
            test.eq(harness.value(other:call("work_describe", {work = sent.work})).sender.id, "sender")
            local page = harness.value(reader:call("session_scan", {workspace = other_workspace}))
            test.eq(page.items[1], opened.session)
        end)
        test.it("creates sessions and immutable queued work with keyed replay and journal events", function()
            local sessions = harness.session_owner(WORKSPACE)
            local open_key = harness.key()
            local open_request = {operation_key = open_key, title = "review", route = {
                definition = "bee.test:definition", profile_id = "batch"}}
            local opened_reply = sessions:call("session_create", open_request)
            local opened = harness.value(opened_reply)
            local session_ref = opened.session
            test.is_true(string.sub(session_ref, 1, 3) == "bs:")
            local open_replay = sessions:call("session_create", open_request)
            test.is_true(open_replay.replayed)
            test.eq(open_replay.value.session, session_ref)
            test.eq(harness.code(sessions:call("session_create", {operation_key = open_key, title = "different"})), "CONFLICT")
            local described = harness.value(sessions:call("session_describe", {session = session_ref}))
            test.eq(described.state, "active")
            test.eq(described.revision, 1)
            test.eq(described.route.session_ref, session_ref)
            test.eq(described.route.action_id, session_ref)
            test.eq(described.route.workspace_id, WORKSPACE)
            test.eq(described.route.owner_id, "sessions-owner")
            test.is_true(type(described.route.thread_id) == "string" and described.route.thread_id ~= "")

            local key = harness.key()
            local request = {session = session_ref, operation_key = key, input = {text = "inspect"}, output_schema = "bee:Text@1"}
            local receipt = harness.value(sessions:call("work_send", request))
            test.is_true(string.sub(receipt.work, 1, 3) == "bw:")
            test.eq(receipt.state, "queued")
            local replay = sessions:call("work_send", request)
            test.is_true(replay.ok)
            test.is_true(replay.replayed)
            test.eq(replay.value.work, receipt.work)

            local changed = {session = session_ref, operation_key = key, input = {text = "replace"}, output_schema = "bee:Text@1"}
            test.eq(harness.code(sessions:call("work_send", changed)), "CONFLICT")
            local work = harness.value(sessions:call("work_describe", {work = receipt.work}))
            test.eq(work.phase, "queued")
            test.is_nil(work.result)
            local found = harness.value(sessions:call("operation_lookup", {operation_key = key}))
            test.eq(found.operation_key, key)
            test.eq(found.receipt.work, receipt.work)
            local described = harness.value(sessions:call("operation_describe", {operation = receipt.operation}))
            test.eq(described.operation_key, key)
            test.eq(described.receipt.work, receipt.work)

            local page = harness.value(sessions:call("feed_read", {session = session_ref, after_sequence = 0, limit = 16}))
            test.eq(#page.events, 2)
            test.eq(page.events[1].kind, "session.created")
            test.eq(page.events[2].kind, "work.queued")
            test.eq(page.events[2].schema, "bee.sessions.event@1")
            test.eq(page.events[2].owner, "threads")
            local db = harness.open()
            local thread = harness.query(db, "SELECT thread_id FROM bee_sessions WHERE session_ref = ?", {session_ref})
            local count = harness.query(db, "SELECT COUNT(*) AS count FROM bee_thread_records WHERE thread_id = ?", {thread[1].thread_id})
            db:release()
            test.eq(count[1].count, 2)
        end)

        test.it("reserves work independently across sessions", function()
            local sessions = harness.session_owner(WORKSPACE)
            local producer = harness.value(sessions:call("session_create", {operation_key = harness.key()}))
            local consumer = harness.value(sessions:call("session_create", {operation_key = harness.key()}))
            harness.value(sessions:call("work_send", {session = producer.session, operation_key = harness.key(), input = {text = "first"}}))
            local second = harness.value(sessions:call("work_send", {session = consumer.session, operation_key = harness.key(), input = {text = "second"}}))
            local reservation = harness.value(sessions:call("turn_reserve", {session = consumer.session, operation_key = harness.key()}))
            test.eq(reservation.work, second.work)
            test.eq(reservation.state, "reserved")
        end)

        test.it("scans durable sessions with a stable reference cursor", function()
            local sessions = harness.session_owner(string.rep("b", 32))
            harness.value(sessions:call("session_create", {operation_key = harness.key()}))
            harness.value(sessions:call("session_create", {operation_key = harness.key()}))
            local first = harness.value(sessions:call("session_scan", {limit = 1}))
            test.eq(#first.items, 1)
            test.not_nil(first.next)
            local second = harness.value(sessions:call("session_scan", {cursor = first.next, limit = 1}))
            test.eq(#second.items, 1)
            test.is_nil(second.next)
            test.neq(first.items[1], second.items[1])
            local repeat_first = harness.value(sessions:call("session_scan", {limit = 1}))
            test.eq(first.items[1], repeat_first.items[1])
        end)

        test.it("keeps work independent when another session's work fails", function()
            local sessions = harness.session_owner(WORKSPACE)
            local producer = harness.value(sessions:call("session_create", {operation_key = harness.key()}))
            local consumer = harness.value(sessions:call("session_create", {operation_key = harness.key()}))
            local first = harness.value(sessions:call("work_send", {session = producer.session, operation_key = harness.key(), input = {text = "fails"}}))
            local second = harness.value(sessions:call("work_send", {session = consumer.session, operation_key = harness.key(), input = {text = "independent"}}))

            local reservation = harness.value(sessions:call("turn_reserve", {session = producer.session, operation_key = harness.key()}))
            local envelope = harness.value(sessions:call("turn_pull", {turn = reservation.turn, claim = reservation.claim}))
            harness.value(sessions:call("turn_accept", {turn = reservation.turn, claim = reservation.claim,
                input_digest = envelope.input_digest, checkpoint = {}, operation_key = harness.key()}))
            harness.value(sessions:call("work_settle", {turn = reservation.turn, claim = reservation.claim,
                result = result("failed"), operation_key = harness.key()}))

            local independent = harness.value(sessions:call("turn_reserve", {session = consumer.session, operation_key = harness.key()}))
            test.eq(independent.work, second.work)
            test.eq(independent.state, "reserved")
            test.eq(harness.value(sessions:call("work_describe", {work = second.work})).phase, "reserved")
        end)

        test.it("seals lifecycle changes only when queued work is settled", function()
            local sessions = harness.session_owner(WORKSPACE)
            local opened = harness.value(sessions:call("session_create", {operation_key = harness.key()}))
            local work = harness.value(sessions:call("work_send", {session = opened.session, operation_key = harness.key(), input = {text = "finish before close"}}))
            test.eq(harness.code(sessions:call("session_transition", {session = opened.session, state = "closed", operation_key = harness.key()})), "BLOCKED")
            harness.value(sessions:call("session_transition", {session = opened.session, state = "suspended", operation_key = harness.key()}))
            test.eq(harness.value(sessions:call("turn_reserve", {session = opened.session, operation_key = harness.key()})).state, "suspended")
            test.eq(harness.code(sessions:call("session_transition", {session = opened.session, state = "active", expected_revision = 1, operation_key = harness.key()})), "CONFLICT")
            harness.value(sessions:call("session_transition", {session = opened.session, state = "active", expected_revision = 2, operation_key = harness.key()}))
            local reservation = harness.value(sessions:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
            test.eq(reservation.work, work.work)
            local envelope = harness.value(sessions:call("turn_pull", {turn = reservation.turn, claim = reservation.claim}))
            harness.value(sessions:call("turn_accept", {turn = reservation.turn, claim = reservation.claim,
                input_digest = envelope.input_digest, checkpoint = {}, operation_key = harness.key()}))
            harness.value(sessions:call("work_settle", {turn = reservation.turn, claim = reservation.claim,
                result = result("succeeded"), operation_key = harness.key()}))
            harness.value(sessions:call("session_transition", {session = opened.session, state = "closing", expected_revision = 3, operation_key = harness.key()}))
            harness.value(sessions:call("session_transition", {session = opened.session, state = "closed", expected_revision = 4, operation_key = harness.key()}))
            test.eq(harness.value(sessions:call("session_describe", {session = opened.session})).state, "closed")
        end)

        test.it("serializes concurrent FIFO reservations and fences old claims after owner restart", function()
            local sessions = harness.session_owner(WORKSPACE)
            local opened = harness.value(sessions:call("session_create", {operation_key = harness.key()}))
            local first = harness.value(sessions:call("work_send", {session = opened.session, operation_key = harness.key(), input = {text = "first"}}))
            harness.value(sessions:call("work_send", {session = opened.session, operation_key = harness.key(), input = {text = "second"}}))
            local left_request = {session = opened.session, operation_key = harness.key()}
            local right_request = {session = opened.session, operation_key = harness.key()}
            local left = sessions:start("turn_reserve", left_request)
            local right = sessions:start("turn_reserve", right_request)
            local a, b = harness.await(left), harness.await(right)
            test.is_true(a.ok and b.ok)
            local reserved_a = a.value.turn ~= nil
            local reserved_b = b.value.turn ~= nil
            test.is_true(reserved_a ~= reserved_b)
            local claim = reserved_a and a.value or b.value
            test.eq(claim.work, first.work)
            local winning_request = reserved_a and left_request or right_request
            local replay = sessions:call("turn_reserve", winning_request)
            test.is_true(replay.ok)
            test.is_true(replay.replayed)
            test.eq(replay.value.turn, claim.turn)

            local before = harness.open()
            local _, restart_error = owner_store.establish(before)
            before:release()
            test.is_nil(restart_error)
            local stale = sessions:call("turn_pull", {turn = claim.turn, claim = claim.claim})
            test.eq(harness.code(stale), "STALE")
            test.eq(harness.code(sessions:call("turn_accept", {turn = claim.turn, claim = claim.claim,
                input_digest = claim.input_digest, checkpoint = {}, operation_key = harness.key()})), "STALE")
        end)

        test.it("commits acceptance and one per-work result, and replays settlement by key", function()
            local sessions = harness.session_owner(WORKSPACE)
            local opened = harness.value(sessions:call("session_create", {operation_key = harness.key()}))
            local work = harness.value(sessions:call("work_send", {session = opened.session, operation_key = harness.key(), input = {text = "finish"}}))
            local reservation = harness.value(sessions:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
            local envelope = harness.value(sessions:call("turn_pull", {turn = reservation.turn, claim = reservation.claim}))
            test.eq(harness.code(sessions:call("turn_accept", {turn = reservation.turn, claim = reservation.claim,
                input_digest = string.rep("0", 64), checkpoint = {frontier = 1}, operation_key = harness.key()})), "CONFLICT")
            harness.value(sessions:call("turn_accept", {turn = reservation.turn, claim = reservation.claim,
                input_digest = envelope.input_digest, checkpoint = {frontier = 1}, operation_key = harness.key()}))

            local key = harness.key()
            local settle = {turn = reservation.turn, claim = reservation.claim, result = result("succeeded"), operation_key = key}
            local receipt = harness.value(sessions:call("work_settle", settle))
            test.eq(receipt.work, work.work)
            test.eq(receipt.result.state, "succeeded")
            local replay = sessions:call("work_settle", settle)
            test.is_true(replay.ok)
            test.is_true(replay.replayed)
            test.eq(replay.value.work, work.work)
            local described = harness.value(sessions:call("work_describe", {work = work.work}))
            test.eq(described.phase, "settled")
            test.eq(described.result.state, "succeeded")
            test.eq(harness.value(sessions:call("operation_lookup", {operation_key = key})).receipt.work, work.work)
            test.eq(harness.value(sessions:call("operation_describe", {operation = receipt.operation})).receipt.work, work.work)
            test.eq(harness.code(sessions:call("work_settle", {turn = reservation.turn, claim = reservation.claim,
                result = result("failed"), operation_key = harness.key()})), "CONFLICT")
        end)

        test.it("appends normalized observations only while the current turn claim is accepted", function()
            local sessions = harness.session_owner(WORKSPACE)
            local opened = harness.value(sessions:call("session_create", {operation_key = harness.key()}))
            local work = harness.value(sessions:call("work_send", {session = opened.session,
                operation_key = harness.key(), input = {text = "observe live output"}}))
            local reservation = harness.value(sessions:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
            local envelope = harness.value(sessions:call("turn_pull", {turn = reservation.turn, claim = reservation.claim}))
            harness.value(sessions:call("turn_accept", {turn = reservation.turn, claim = reservation.claim,
                input_digest = envelope.input_digest, checkpoint = {}, operation_key = harness.key()}))
            local event = {type = "text", event_key = "claude:1:assistant", data = {type = "text", segment_id = "answer",
                operation = "append", text = "live text", channel = "answer"}}
            local operation_key = harness.key()
            local request = {turn = reservation.turn, claim = reservation.claim, operation_key = operation_key, observation = event}
            local appended = harness.value(sessions:call("turn_observation", request))
            test.eq(appended.session, opened.session)
            test.eq(appended.work, work.work)
            test.eq(appended.event_key, event.event_key)
            test.is_true(sessions:call("turn_observation", request).replayed)
            local page = harness.value(sessions:call("feed_read", {session = opened.session, after_sequence = 0, limit = 64}))
            local found = false
            for _, row in ipairs(page.events) do
                if row.kind == "turn.observation" then
                    found = true
                    test.eq(row.data.observation.event_key, event.event_key)
                    test.eq(row.data.observation.data.text, "live text")
                end
            end
            test.is_true(found)
            test.eq(harness.code(sessions:call("turn_observation", {turn = reservation.turn, claim = "wrong-claim",
                operation_key = harness.key(), observation = event})), "DENIED")
            harness.value(sessions:call("work_settle", {turn = reservation.turn, claim = reservation.claim,
                result = result("succeeded"), operation_key = harness.key()}))
            test.eq(harness.code(sessions:call("turn_observation", {turn = reservation.turn, claim = reservation.claim,
                operation_key = harness.key(), observation = event})), "CONFLICT")
        end)

        test.it("cancels queued work immediately and records active cancellation for the scheduler", function()
            local sessions = harness.session_owner(WORKSPACE)
            local opened = harness.value(sessions:call("session_create", {operation_key = harness.key()}))
            local queued = harness.value(sessions:call("work_send", {session = opened.session,
                operation_key = harness.key(), input = {text = "cancel before activation"}}))
            local cancel_key = harness.key()
            local cancel_request = {work = queued.work, operation_key = cancel_key, reason = "not needed"}
            local receipt = harness.value(sessions:call("work_cancel", cancel_request))
            test.eq(receipt.effect, "cancel")
            test.eq(receipt.subject, queued.work)
            local cancelled = harness.value(sessions:call("work_describe", {work = queued.work}))
            test.eq(cancelled.phase, "settled")
            test.eq(cancelled.result.state, "cancelled")
            test.eq(cancelled.result.artifacts[1], "work was cancelled before executor activation")
            test.is_true(sessions:call("work_cancel", cancel_request).replayed)
            test.eq(harness.value(sessions:call("operation_describe", {operation = receipt.operation})).receipt.effect, "cancel")

            local active = harness.value(sessions:call("work_send", {session = opened.session,
                operation_key = harness.key(), input = {text = "cancel active turn"}}))
            local reservation = harness.value(sessions:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
            local envelope = harness.value(sessions:call("turn_pull", {turn = reservation.turn, claim = reservation.claim}))
            harness.value(sessions:call("turn_accept", {turn = reservation.turn, claim = reservation.claim,
                input_digest = envelope.input_digest, checkpoint = {attempt_id = reservation.turn, generation = 1},
                operation_key = harness.key()}))
            local active_cancel = harness.value(sessions:call("work_cancel", {work = active.work,
                operation_key = harness.key(), reason = "stop the active turn"}))
            local cancelling = harness.value(sessions:call("work_describe", {work = active.work}))
            test.is_true(cancelling.cancelling)
            test.eq(cancelling.turn, reservation.turn)
            test.eq(cancelling.claim, reservation.claim)
            local due = harness.value(sessions:call("work_scan", {limit = 16}))
            local found = false
            for _, row in ipairs(due.items) do if row.work == active.work then found = row.cancel_requested == true end end
            test.is_true(found)
            test.eq(harness.value(sessions:call("operation_describe", {operation = active_cancel.operation})).receipt.subject, active.work)
        end)

        test.it("allows launch journal mutations only through the sessions owner scope", function()
            local caller = harness.principal("ordinary-client", {}, WORKSPACE)
            test.eq(harness.code(caller:call("session_create", {operation_key = harness.key()})), "DENIED")
        end)
    end)
end

return test.run_cases(define_tests)
