-- MIT. The owner's subscription lifecycle: it closes an abandoned
-- subscription while preserving its durable cursor, forgets a closed one to
-- reclaim capacity, keeps forgetting explicit, bounds retained metadata, and
-- fences the old lease, outstanding page and late acknowledgments. Only the
-- thread owner runs these; replies are idempotent.
local test = require("test")
local harness = require("harness")
local function define_tests()
    test.describe("Thread subscription lifecycle", function()
        local alice = harness.principal("alice", harness.ALL)
        local bob = harness.principal("bob", {})
        local function thread_with(count: integer): string
            local thread_id = harness.thread(alice, "Lifecycle")
            harness.value(alice:call("join", {thread_id = thread_id, idempotency_key = harness.key(), member_id = "bob", role = "participant", expected_revision = 1}))
            for index = 1, count do
                harness.value(alice:call("record", {thread_id = thread_id, idempotency_key = harness.key(), kind = "message", body = harness.message("m" .. tostring(index), "line " .. tostring(index))}))
            end
            return thread_id
        end
        test.it("lets the owner close an abandoned subscription, preserving its cursor and fencing the old lease", function()
            local thread_id = thread_with(70)
            local created = harness.value(bob:call("subscribe", {thread_id = thread_id, idempotency_key = harness.key(), consumer_id = "abandoned", after_sequence = 0, durability = "durable"}))
            local page = harness.value(bob:call("page", {thread_id = thread_id, subscription_id = created.subscription_id}))
            harness.value(bob:call("ack_page", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = created.subscription_id, page_id = page.page_id, scanned_through = page.scanned_through}))
            local second = harness.value(bob:call("page", {thread_id = thread_id, subscription_id = created.subscription_id}))
            test.not_nil(second.page_id)
            -- A non-owner cannot close another's subscription.
            test.eq(harness.code(bob:call("close_subscription", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = created.subscription_id})), "DENIED")
            local closed = harness.value(alice:call("close_subscription", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = created.subscription_id}))
            test.is_true(closed.closed)
            -- The lease and outstanding page are fenced: paging is refused, and a
            -- late acknowledgment of the retired page finds nothing outstanding.
            test.eq(harness.code(bob:call("page", {thread_id = thread_id, subscription_id = created.subscription_id})), "INVALID_STATE")
            test.eq(harness.code(bob:call("ack_page", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = created.subscription_id, page_id = second.page_id, scanned_through = second.scanned_through})), "INVALID_STATE")
            -- Idempotent: a second close with a fresh key still reports it closed.
            test.is_true(harness.value(alice:call("close_subscription", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = created.subscription_id})).closed)
            -- The durable cursor is preserved: bob resumes from where he acknowledged.
            local resumed = harness.value(bob:call("resume", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = created.subscription_id}))
            test.eq(resumed.after_sequence, page.scanned_through)
            test.eq(resumed.lease_generation, 2)
            test.is_false(resumed.closed)
            local next_page = harness.value(bob:call("page", {thread_id = thread_id, subscription_id = created.subscription_id}))
            test.eq(next_page.from_sequence, page.scanned_through)
        end)
        test.it("forgets only a closed subscription and makes everything after NOT_FOUND", function()
            local thread_id = thread_with(5)
            local created = harness.value(bob:call("subscribe", {thread_id = thread_id, idempotency_key = harness.key(), consumer_id = "gone", after_sequence = 0, durability = "durable"}))
            -- Forgetting is explicit: an open subscription must be closed first.
            test.eq(harness.code(alice:call("forget_subscription", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = created.subscription_id})), "INVALID_STATE")
            test.eq(harness.code(bob:call("forget_subscription", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = created.subscription_id})), "DENIED")
            harness.value(alice:call("close_subscription", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = created.subscription_id}))
            local forgotten = harness.value(alice:call("forget_subscription", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = created.subscription_id}))
            test.is_true(forgotten.forgotten)
            -- The cursor, lease, page and any later acknowledgment are gone.
            test.eq(harness.code(bob:call("page", {thread_id = thread_id, subscription_id = created.subscription_id})), "NOT_FOUND")
            test.eq(harness.code(bob:call("resume", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = created.subscription_id})), "NOT_FOUND")
            test.eq(harness.code(bob:call("ack_page", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = created.subscription_id, page_id = "any", scanned_through = 1})), "NOT_FOUND")
            -- Idempotent: forgetting an absent subscription reports it forgotten.
            test.is_true(harness.value(alice:call("forget_subscription", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = created.subscription_id})).forgotten)
            test.is_true(harness.value(alice:call("forget_subscription", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = "never-existed"})).forgotten)
            -- After forgetting, the same identity subscribes again: capacity recovered.
            local again = harness.value(bob:call("subscribe", {thread_id = thread_id, idempotency_key = harness.key(), consumer_id = "gone", after_sequence = 0, durability = "durable"}))
            test.neq(again.subscription_id, created.subscription_id)
        end)
        test.it("replays a close under the same idempotency key without a second effect", function()
            local thread_id = thread_with(3)
            local created = harness.value(bob:call("subscribe", {thread_id = thread_id, idempotency_key = harness.key(), consumer_id = "retry", after_sequence = 0, durability = "durable"}))
            local key = harness.key()
            harness.value(alice:call("close_subscription", {thread_id = thread_id, idempotency_key = key, subscription_id = created.subscription_id}))
            local replay = alice:call("close_subscription", {thread_id = thread_id, idempotency_key = key, subscription_id = created.subscription_id})
            test.is_true(replay.replayed)
            test.is_true(harness.value(replay).closed)
        end)
        test.it("counts closed subscriptions toward capacity and reclaims only through forget", function()
            local subscriptions = require("subscriptions")
            local thread_id = thread_with(1)
            local ids: {string} = {}
            for index = 1, subscriptions.MAX_THREAD_SUBSCRIPTIONS do
                local created = harness.value(bob:call("subscribe", {thread_id = thread_id, idempotency_key = harness.key(), consumer_id = "c" .. tostring(index), after_sequence = 0, durability = "durable"}))
                ids[#ids + 1] = created.subscription_id
            end
            -- At capacity a new subscription is refused, never at the cost of an existing one.
            test.eq(harness.code(bob:call("subscribe", {thread_id = thread_id, idempotency_key = harness.key(), consumer_id = "overflow", after_sequence = 0, durability = "durable"})), "LIMIT_EXCEEDED")
            -- Closing one keeps its resumable cursor and still counts toward capacity.
            harness.value(alice:call("close_subscription", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = ids[1]}))
            test.eq(harness.code(bob:call("subscribe", {thread_id = thread_id, idempotency_key = harness.key(), consumer_id = "overflow", after_sequence = 0, durability = "durable"})), "LIMIT_EXCEEDED")
            -- Forgetting the closed one reclaims capacity; a new subscription then fits.
            harness.value(alice:call("forget_subscription", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = ids[1]}))
            local admitted = harness.value(bob:call("subscribe", {thread_id = thread_id, idempotency_key = harness.key(), consumer_id = "overflow", after_sequence = 0, durability = "durable"}))
            test.not_nil(admitted.subscription_id)
        end)
        test.it("cannot resurrect a forgotten subscription by replaying an old subscribe or resume key", function()
            local thread_id = thread_with(4)
            local subscribe_key = harness.key()
            local created = harness.value(bob:call("subscribe", {thread_id = thread_id, idempotency_key = subscribe_key, consumer_id = "ghost", after_sequence = 0, durability = "durable"}))
            local resume_key = harness.key()
            -- Give it a resume receipt to replay later, then close and forget it.
            harness.value(alice:call("close_subscription", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = created.subscription_id}))
            local resumed = harness.value(bob:call("resume", {thread_id = thread_id, idempotency_key = resume_key, subscription_id = created.subscription_id}))
            test.eq(resumed.lease_generation, 2)
            harness.value(alice:call("close_subscription", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = created.subscription_id}))
            harness.value(alice:call("forget_subscription", {thread_id = thread_id, idempotency_key = harness.key(), subscription_id = created.subscription_id}))
            -- Replaying the old subscribe key returns its historical receipt, not a live row.
            local subscribe_replay = bob:call("subscribe", {thread_id = thread_id, idempotency_key = subscribe_key, consumer_id = "ghost", after_sequence = 0, durability = "durable"})
            test.is_true(subscribe_replay.replayed)
            test.eq(harness.value(subscribe_replay).subscription_id, created.subscription_id)
            test.eq(harness.code(bob:call("page", {thread_id = thread_id, subscription_id = created.subscription_id})), "NOT_FOUND")
            -- Replaying the old resume key likewise returns its receipt and no usable lease.
            local resume_replay = bob:call("resume", {thread_id = thread_id, idempotency_key = resume_key, subscription_id = created.subscription_id})
            test.is_true(resume_replay.replayed)
            test.eq(harness.code(bob:call("page", {thread_id = thread_id, subscription_id = created.subscription_id})), "NOT_FOUND")
            -- The forgotten identity is free to subscribe anew as a fresh row.
            local fresh = harness.value(bob:call("subscribe", {thread_id = thread_id, idempotency_key = harness.key(), consumer_id = "ghost", after_sequence = 0, durability = "durable"}))
            test.neq(fresh.subscription_id, created.subscription_id)
        end)
    end)
end
return require("test").run_cases(define_tests)
