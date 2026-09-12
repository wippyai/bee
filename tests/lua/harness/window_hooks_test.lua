-- MIT. Window hook delivery, pure: one in-flight identity, exact commit
-- replay after a lost reply, and settlement that never follows a hook.
local test = require("test")
local hooks = require("hooks")
local checkpoint = require("checkpoint")
type Object = {[string]: unknown}
type Reply = hooks.Reply
local function decoder(binding_id: string, turn_id: string?, items: unknown): (hooks.Batch?, string?)
    if type(items) ~= "table" then return nil, "claimed hooks must be a list" end
    local records: {{[string]: unknown}} = {}
    local event_ids: {string} = {}
    local activity: string? = nil
    for index, item in ipairs(items :: {unknown}) do
        if type(item) ~= "table" then return nil, "claimed hooks[" .. tostring(index) .. "] must be an object" end
        local row = item :: Object
        local event_id = tostring(row.event_id)
        event_ids[index] = event_id
        records[index] = {binding_id = binding_id, turn_id = turn_id, event_id = event_id, event = row.event}
        if type(row.event) == "string" then activity = row.event end
    end
    return {records = records, event_ids = event_ids, activity = activity}, nil
end
local function open(extra: Object?): hooks.State
    local config: hooks.Config = {
        thread_id = "thread-1",
        attempt_id = "attempt-1",
        epoch = 7,
        binding_ref = "driver:binding",
        binding_digest = "binding-digest",
        profile_id = "window",
        profile_digest = "profile-digest",
        plan_digest = "plan-digest",
        session_ref = "session-home",
        gateway_binding = "bind-1",
        hooks_enabled = true,
        drain_ms = 40,
        decoder = decoder,
    }
    if extra then
        for key, value in pairs(extra) do
            (config :: Object)[key] = value
        end
    end
    return hooks.new(config)
end
local function ok(value: Object): Reply
    value.binding_id = value.binding_id or "bind-1"
    value.sealed = true
    if value.checkpoint_revision ~= nil then
        value.attempt_id = value.attempt_id or "attempt-1"
        value.carrier_epoch = value.carrier_epoch or 7
    end
    return {ok = true, error = nil, value = value, replayed = false}
end
local function fault(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil, replayed = false}
end
local function claim_value(items: {Object}): Object
    return {binding_id = "bind-1", carrier_epoch = 7, hooks = items}
end
local function item(event_id: string, event: string): Object
    return {event_id = event_id, event = event, occurrence = event_id, ambiguous = false, digest = "d", fields = {}, provenance = "p", sequence = 1}
end
local function persist(state: hooks.State, now: integer): hooks.Intent
    local intent = hooks.next_intent(state, "fresh-key", now)
    if not intent then error("missing checkpoint intent") end
    test.eq(intent.target, hooks.COMMIT)
    test.is_true(hooks.begin(state, "cp", intent))
    test.is_true(hooks.apply(state, "cp", ok({checkpoint_revision = 1})))
    test.is_true(hooks.may_start(state))
    return intent
end
local function define_tests()
    test.describe("Window hook delivery", function()
        test.it("requires a proved checkpoint revision before launch or hook acknowledgment", function()
            for _, invalid in ipairs({{}, {checkpoint_revision = 9}, {checkpoint_revision = -1}}) do
                local state = open()
                local intent = hooks.next_intent(state, "cp", 0)
                if not intent then error("checkpoint") end
                test.is_true(hooks.begin(state, "cp", intent))
                hooks.apply(state, "cp", ok(invalid))
                test.is_false(hooks.may_start(state))
                test.eq(state.revision, 0)
            end
            local state = open()
            persist(state, 0)
            local claim = hooks.next_intent(state, "claim", 0)
            if not claim then error("claim") end
            hooks.begin(state, "claim", claim)
            hooks.apply(state, "claim", ok(claim_value({item("e1", "Stop")})))
            test.is_nil(state.activity)
            local commit = hooks.next_intent(state, "commit", 0)
            if not commit then error("commit") end
            hooks.begin(state, "commit", commit)
            hooks.apply(state, "commit", ok({}))
            test.eq(state.work, "commit")
            test.eq(state.revision, 1)
            test.is_nil(state.activity)
            local retry = hooks.next_intent(state, "retry", hooks.RETRY_MS)
            if not retry then error("exact retry") end
            test.eq(retry.request, commit.request)
            hooks.begin(state, "retry", retry)
            test.is_false(hooks.apply(state, "commit", ok({checkpoint_revision = 2})))
            test.is_nil(state.activity)
            hooks.apply(state, "retry", ok({checkpoint_revision = 2}))
            test.eq(state.activity, "Stop")
            test.is_false(hooks.apply(state, "commit", ok({checkpoint_revision = 3})))
            test.eq(state.activity, "Stop")
        end)

        test.it("cannot turn a malformed claim or refused seal into a clean close", function()
            local state = open()
            persist(state, 0)
            hooks.shutdown(state, 0, true)
            local seal = hooks.next_intent(state, "seal", 0)
            if not seal then error("seal") end
            hooks.begin(state, "seal", seal)
            hooks.apply(state, "seal", fault("DENIED", "seal refused"))
            test.is_false(state.sealed)
            test.eq(hooks.outcome(state), "uncertain")

            state = open()
            persist(state, 0)
            hooks.shutdown(state, 0, true)
            seal = hooks.next_intent(state, "seal", 0)
            if not seal then error("seal") end
            hooks.begin(state, "seal", seal)
            hooks.apply(state, "seal", ok({}))
            local claim = hooks.next_intent(state, "claim", 0)
            if not claim then error("claim") end
            hooks.begin(state, "claim", claim)
            hooks.apply(state, "claim", ok({binding_id = "bind-1", carrier_epoch = 7}))
            test.eq(state.work, "claim")
            test.is_false(hooks.finished(state))
            hooks.expire(state, 40)
            test.eq(hooks.outcome(state), "uncertain")
        end)

        test.it("persists the initial checkpoint pins before the child may start", function()
            local state = open()
            test.is_false(hooks.may_start(state))
            local intent = hooks.next_intent(state, "ignored", 0)
            if not intent then error("checkpoint") end
            test.eq(intent.target, hooks.COMMIT)
            test.eq(intent.request.thread_id, "thread-1")
            test.eq(intent.request.attempt_id, "attempt-1")
            test.eq(intent.request.carrier_epoch, 7)
            test.eq(intent.request.expected_revision, 0)
            test.eq(intent.request.idempotency_key, "launch:attempt-1:window:checkpoint")
            test.eq(#(intent.request.records :: {unknown}), 0)
            test.is_nil(intent.request.records and (intent.request.records :: {Object})[1] and (intent.request.records :: {Object})[1].turn_id)
            local point, err = checkpoint.decode(intent.request.checkpoint)
            if not point then error(tostring(err)) end
            test.eq(point.binding_ref, "driver:binding")
            test.eq(point.binding_digest, "binding-digest")
            test.eq(point.profile_id, "window")
            test.eq(point.profile_digest, "profile-digest")
            test.eq(point.plan_digest, "plan-digest")
            test.eq(point.retained_session_ref, "session-home")
            test.eq(point.gateway_binding, "bind-1")
            test.eq(point.attachment_generation, 7)
            test.is_true(hooks.begin(state, "cp", intent))
            test.is_nil(hooks.next_intent(state, "other", 0))
            test.is_false(hooks.may_start(state))
            test.is_true(hooks.apply(state, "cp", ok({checkpoint_revision = 1})))
            test.is_true(hooks.may_start(state))
            test.eq(state.revision, 1)
        end)

        test.it("admits only one request until the exact pending reply arrives", function()
            local state = open()
            persist(state, 0)
            local intent = hooks.next_intent(state, "k1", 0)
            if not intent then error("claim") end
            test.eq(intent.target, hooks.CLAIM)
            test.is_true(hooks.begin(state, "pending-1", intent))
            test.is_false(hooks.begin(state, "pending-2", intent))
            test.is_nil(hooks.next_intent(state, "k2", 0))
            test.eq(state.work, "claim")
            test.is_nil(hooks.next_intent(state, "k3", 0))
        end)

        test.it("ignores a stale completion and keeps the pending identity", function()
            local state = open()
            persist(state, 0)
            local intent = hooks.next_intent(state, "k1", 0)
            if not intent then error("claim") end
            test.is_true(hooks.begin(state, "live", intent))
            test.is_false(hooks.apply(state, "stale", ok(claim_value({item("e1", "SessionStart")}))))
            test.is_false(hooks.lost(state, "stale"))
            test.eq(state.work, "claim")
            test.is_nil(hooks.next_intent(state, "k2", 0))
            test.is_true(hooks.apply(state, "live", ok(claim_value({item("e1", "SessionStart")}))))
            test.eq(state.work, "commit")
        end)

        test.it("retries the exact commit request and key after a lost reply", function()
            local state = open()
            persist(state, 0)
            local claim = hooks.next_intent(state, "k1", 0)
            if not claim then error("claim") end
            test.is_true(hooks.begin(state, "c1", claim))
            test.is_true(hooks.apply(state, "c1", ok(claim_value({item("e1", "UserPromptSubmit")}))))
            local commit = hooks.next_intent(state, "new-key", 0)
            if not commit then error("commit") end
            test.eq(commit.target, hooks.COMMIT)
            test.eq(commit.request.expected_revision, 1)
            test.eq(commit.request.carrier_epoch, 7)
            local key = tostring(commit.request.idempotency_key)
            test.neq(key, "new-key")
            test.neq(key, "launch:attempt-1:window:checkpoint")
            local records = commit.request.records :: {{[string]: unknown}}
            test.eq(#records, 1)
            test.eq(records[1].event_id, "e1")
            test.is_nil(records[1].turn_id)
            test.is_true(hooks.begin(state, "commit-1", commit))
            test.is_true(hooks.lost(state, "commit-1"))
            local retry = hooks.next_intent(state, "another-key", hooks.RETRY_MS)
            if not retry then error("retry") end
            test.eq(retry.target, hooks.COMMIT)
            test.eq(retry.request, commit.request)
            test.eq(retry.request.idempotency_key, key)
            test.eq(retry.request.expected_revision, 1)
            test.is_true(hooks.begin(state, "commit-2", retry))
            test.is_true(hooks.apply(state, "commit-2", ok({checkpoint_revision = 2})))
            test.eq(state.revision, 2)
            test.eq(state.work, "ack")
        end)

        test.it("keeps pending commit work across close and seals before finish", function()
            local state = open()
            persist(state, 0)
            local claim = hooks.next_intent(state, "k1", 0)
            if not claim then error("claim") end
            test.is_true(hooks.begin(state, "c1", claim))
            test.is_true(hooks.apply(state, "c1", ok(claim_value({item("e1", "Stop")}))))
            local commit = hooks.next_intent(state, "k2", 0)
            if not commit then error("commit") end
            test.is_true(hooks.begin(state, "commit-1", commit))
            hooks.shutdown(state, 5, true)
            test.is_false(hooks.finished(state))
            test.eq(hooks.outcome(state), "uncertain")
            local after = hooks.next_intent(state, "k3", 5)
            if not after then error("seal") end
            test.eq(after.target, hooks.SEAL)
            test.eq(after.request.binding_id, "bind-1")
            test.is_true(hooks.begin(state, "seal", after))
            test.is_true(hooks.apply(state, "seal", ok({})))
            local replay = hooks.next_intent(state, "k4", 5)
            if not replay then error("preserved commit") end
            test.eq(replay.target, hooks.COMMIT)
            test.eq(replay.request, commit.request)
            test.is_true(hooks.begin(state, "commit-2", replay))
            test.is_true(hooks.apply(state, "commit-2", ok({checkpoint_revision = 2})))
            local ack = hooks.next_intent(state, "k5", 5)
            if not ack then error("ack") end
            test.eq(ack.target, hooks.ACK)
            local sealed_ids = ack.request.event_ids :: {string}
            test.eq(#sealed_ids, 1)
            test.eq(sealed_ids[1], "e1")
            test.is_true(hooks.begin(state, "ack", ack))
            test.is_true(hooks.apply(state, "ack", ok({acknowledged = 1})))
            local drain = hooks.next_intent(state, "k6", 5)
            if not drain then error("drain") end
            test.eq(drain.target, hooks.CLAIM)
            test.is_true(hooks.begin(state, "drain", drain))
            test.is_true(hooks.apply(state, "drain", ok(claim_value({}))))
            test.is_nil(hooks.next_intent(state, "k7", 5))
            test.is_true(hooks.finished(state))
            test.eq(hooks.outcome(state), "cancelled")
        end)

        test.it("does not claim the next batch before the current ack", function()
            local state = open()
            persist(state, 0)
            local claim = hooks.next_intent(state, "k1", 0)
            if not claim then error("claim") end
            test.eq(claim.request.limit, 16)
            test.is_true(hooks.begin(state, "c1", claim))
            test.is_true(hooks.apply(state, "c1", ok(claim_value({item("e1", "PreToolUse"), item("e2", "PostToolUse")}))))
            local commit = hooks.next_intent(state, "k2", 0)
            if not commit then error("commit") end
            test.eq(commit.target, hooks.COMMIT)
            test.eq(#(commit.request.records :: {unknown}), 2)
            test.is_true(hooks.begin(state, "commit", commit))
            test.is_true(hooks.apply(state, "commit", ok({checkpoint_revision = 2})))
            test.eq(state.work, "ack")
            local ack = hooks.next_intent(state, "k3", 0)
            if not ack then error("ack") end
            test.eq(ack.target, hooks.ACK)
            local ids = ack.request.event_ids :: {string}
            test.eq(#ids, 2)
            test.eq(ids[1], "e1")
            test.eq(ids[2], "e2")
            test.is_true(hooks.begin(state, "ack", ack))
            test.is_nil(hooks.next_intent(state, "k5", 0))
            test.is_true(hooks.apply(state, "ack", ok({acknowledged = 2})))
            local next_claim = hooks.next_intent(state, "k6", 0)
            if not next_claim then error("next claim") end
            test.eq(next_claim.target, hooks.CLAIM)
        end)

        test.it("never settles a logical success from hook observations", function()
            local state = open()
            persist(state, 0)
            local claim = hooks.next_intent(state, "k1", 0)
            if not claim then error("claim") end
            test.is_true(hooks.begin(state, "c1", claim))
            test.is_true(hooks.apply(state, "c1", ok(claim_value({item("s1", "SessionStart"), item("s2", "Stop")}))))
            local commit = hooks.next_intent(state, "k2", 0)
            if not commit then error("commit") end
            test.is_true(hooks.begin(state, "commit", commit))
            test.is_true(hooks.apply(state, "commit", ok({checkpoint_revision = 2})))
            local ack = hooks.next_intent(state, "k3", 0)
            if not ack then error("ack") end
            test.is_true(hooks.begin(state, "ack", ack))
            test.is_true(hooks.apply(state, "ack", ok({acknowledged = 2})))
            test.eq(hooks.outcome(state), "uncertain")
            hooks.shutdown(state, 10, false)
            local seal = hooks.next_intent(state, "k4", 10)
            if not seal then error("seal") end
            test.is_true(hooks.begin(state, "seal", seal))
            test.is_true(hooks.apply(state, "seal", ok({})))
            local drain = hooks.next_intent(state, "k5", 10)
            if not drain then error("drain") end
            test.is_true(hooks.begin(state, "drain", drain))
            test.is_true(hooks.apply(state, "drain", ok(claim_value({}))))
            test.is_nil(hooks.next_intent(state, "k6", 10))
            test.is_true(hooks.finished(state))
            test.eq(hooks.outcome(state), "uncertain")
        end)

        test.it("retains durable uncertainty when a bounded drain expires mid-commit", function()
            local state = open()
            persist(state, 0)
            local claim = hooks.next_intent(state, "k1", 0)
            if not claim then error("claim") end
            test.is_true(hooks.begin(state, "c1", claim))
            test.is_true(hooks.apply(state, "c1", ok(claim_value({item("e1", "Stop")}))))
            local commit = hooks.next_intent(state, "k2", 0)
            if not commit then error("commit") end
            test.is_true(hooks.begin(state, "commit", commit))
            hooks.shutdown(state, 0, true)
            local seal = hooks.next_intent(state, "k3", 0)
            if not seal then error("seal") end
            test.is_true(hooks.begin(state, "seal", seal))
            test.is_true(hooks.apply(state, "seal", ok({})))
            local replay = hooks.next_intent(state, "k4", 0)
            if not replay then error("replay") end
            test.eq(replay.target, hooks.COMMIT)
            test.is_true(hooks.begin(state, "commit-2", replay))
            hooks.expire(state, 40)
            test.is_true(hooks.finished(state))
            test.eq(hooks.outcome(state), "uncertain")
            test.is_true(state.unresolved)
            test.is_false(hooks.apply(state, "commit-2", ok({checkpoint_revision = 2})))
        end)

        test.it("stops delivery on revoked authority and preserves unresolved work", function()
            local state = open()
            persist(state, 0)
            local claim = hooks.next_intent(state, "claim", 0)
            if not claim then error("claim") end
            hooks.begin(state, "claim", claim)
            hooks.apply(state, "claim", fault("CONFLICT", "carrier replaced"))
            test.is_true(hooks.finished(state))
            test.is_nil(hooks.next_intent(state, "retry", 100000))
            hooks.shutdown(state, 100000, true)
            test.eq(hooks.outcome(state), "uncertain")
        end)

        test.it("requires the current claim identity and retains an unproved acknowledgment", function()
            local state = open()
            persist(state, 0)
            local claim = hooks.next_intent(state, "claim", 0)
            if not claim then error("claim") end
            hooks.begin(state, "claim", claim)
            hooks.apply(state, "claim", ok({binding_id = "wrong", carrier_epoch = 7, hooks = {item("foreign", "Stop")}}))
            test.eq(state.work, "claim")
            test.is_nil(state.batch)
            claim = hooks.next_intent(state, "again", hooks.RETRY_MS)
            if not claim then error("claim retry") end
            hooks.begin(state, "again", claim)
            hooks.apply(state, "again", ok(claim_value({item("e1", "Stop")})))
            local commit = hooks.next_intent(state, "commit", hooks.RETRY_MS)
            if not commit then error("commit") end
            hooks.begin(state, "commit", commit)
            hooks.apply(state, "commit", ok({checkpoint_revision = 2}))
            local ack = hooks.next_intent(state, "ack", hooks.RETRY_MS)
            if not ack then error("ack") end
            hooks.begin(state, "ack", ack)
            hooks.apply(state, "ack", ok({binding_id = "wrong", acknowledged = 1}))
            test.eq(state.work, "ack")
            local retry = hooks.next_intent(state, "ack-retry", hooks.RETRY_MS * 2)
            if not retry then error("ack retry") end
            test.eq(retry.request, ack.request)
            hooks.begin(state, "ack-retry", retry)
            hooks.apply(state, "ack-retry", ok({acknowledged = 0}))
            test.eq(state.work, "claim")
        end)
    end)
end
return test.run_cases(define_tests)
