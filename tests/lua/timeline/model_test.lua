-- MIT. The model, pure: the picker folds thread pages, attach resumes a
-- remembered subscription and otherwise subscribes from the start, pages
-- count only under the session's lease and fold by sequence, an
-- acknowledgment moves the cursor only as the owner answered, a stale
-- lease asks for resume, silence detaches without changing anything
-- durable, dropped rows are marked, and the checkpoint restores identity.
local test = require("test")
local model = require("model")
type Object = {[string]: unknown}
local function ok(value: unknown): model.Reply
    return {ok = true, error = nil, value = value, replayed = false}
end
local function fault(code: string, message: string): model.Reply
    return {ok = false, error = {code = code, message = message}, value = nil, replayed = false}
end
local function summary(id: string, after: integer, lease: integer, incarnation: integer, closed: boolean?): Object
    return {subscription_id = id, after_sequence = after, lease_generation = lease, owner_incarnation = incarnation, owner_authority = "auth-1", closed = closed == true}
end
local function message(sequence: integer, text: string): Object
    return {schema_revision = "bee.thread-record@1", record_id = "r" .. tostring(sequence), thread_id = "t-1", sequence = sequence, recorded_at = "2026-09-09T00:00:00.000Z",
        kind = "message", producer_id = "bee.test.alice", source = "bee", body = {message_id = "m" .. tostring(sequence), message_kind = "request", sender_id = "bee.test.alice", recipient_ids = {}, content = {text = text}}}
end
local function page(id: string, lease: integer, from: integer, through: integer, records: {Object}, more: boolean): model.Reply
    return ok({subscription_id = "s-1", page_id = id, lease_generation = lease, from_sequence = from, scanned_through = through, records = records, has_more = more})
end
local function define_tests()
    test.describe("Timeline model", function()
        test.it("folds thread pages into the picker and reports an unavailable list as such", function()
            local state = model.new("bee.timeline.i1")
            test.eq(model.list_intent(state).request.limit, model.PAGE_LIMIT)
            local more = model.apply_list(state, ok({threads = {{thread_id = "t-1", title = "One", state = "open", head_sequence = 3, owner_id = "bee.test.alice"}}, next_after_thread_id = "t-1"}))
            test.is_true(more)
            test.eq(model.list_intent(state).request.after_thread_id, "t-1")
            test.is_false(model.apply_list(state, ok({threads = {{thread_id = "t-2", title = "Two\27[31m", state = "open", head_sequence = 0, owner_id = "bee.test.bob"}}})))
            test.eq(#state.picker.threads, 2)
            test.eq(state.picker.selected, "t-1")
            test.is_nil(state.picker.threads[2].title:find("\27", 1, true))
            model.move(state, 1)
            test.eq(state.picker.selected, "t-2")
            test.eq(model.picked(state) and model.picked(state).title, "Two [31m")
            model.apply_list(state, fault("DENIED", "no"))
            test.eq(state.picker.unavailable, "DENIED: no")
        end)
        test.it("subscribes from the start, pages under the lease and moves the cursor only as the owner answers", function()
            local state = model.new("bee.timeline.i1")
            model.open(state, "t-1", nil)
            test.eq(state.phase, "attaching")
            local intent = model.attach_intent(state, "k-1")
            if not intent then error("intent") end
            test.eq(intent.target, model.SUBSCRIBE)
            test.eq(intent.request.after_sequence, 0)
            test.eq(intent.request.consumer_id, "bee.timeline.i1")
            model.apply_attach(state, ok(summary("s-1", 0, 1, 2)))
            test.eq(state.phase, "attached")
            test.eq(state.subscription_id, "s-1")
            local page_intent = model.page_intent(state)
            if not page_intent then error("page intent") end
            test.eq(page_intent.request.subscription_id, "s-1")
            local more = model.apply_page(state, page("p-1", 1, 0, 2, {message(1, "one"), message(2, "two")}, true))
            test.is_true(more)
            test.eq(#state.rows, 2)
            test.eq(state.rows[2].summary, "request from bee.test.alice: two")
            local ack = model.ack_intent(state, "k-2")
            if not ack then error("ack") end
            test.eq(ack.request.page_id, "p-1")
            test.eq(ack.request.scanned_through, 2)
            model.apply_ack(state, ok({after_sequence = 2}))
            test.eq(state.session and state.session.after_sequence, 2)
            test.is_nil(model.ack_intent(state, "k-4"))
            local watch = model.watch_intent(state)
            if not watch then error("watch") end
            test.eq(watch.target, model.WATCH)
            test.eq(watch.request.after_sequence, 2)
            test.is_nil(watch.request.consumer_id)
            test.is_nil(watch.request.limit)
            -- A bounded change-wait is a read hint: a wait that ended
            -- without an answer never claims the owner is unavailable.
            local before = state.unavailable
            model.apply_watch(state, fault("UNAVAILABLE", "no answer from the owner"))
            test.eq(state.unavailable, before)
            test.is_false(model.apply_page(state, page("p-2", 2, 2, 3, {message(3, "three")}, false)))
            test.eq(#state.rows, 2)
            test.eq(state.phase, "resume_required")
            test.is_true(state.notice:find("newer lease", 1, true) ~= nil)
            state.phase = "attached"
            test.is_false(model.apply_page(state, page("p-0", 0, 2, 3, {message(3, "stale")}, false)))
            test.eq(#state.rows, 2)
            test.is_true(state.notice:find("lease generation 0", 1, true) ~= nil)
            test.is_false(model.apply_page(state, page("p-2", 1, 2, 3, {message(3, "three")}, false)))
            test.eq(#state.rows, 3)
            model.apply_page(state, page("p-2", 1, 2, 3, {message(3, "three")}, false))
            test.eq(#state.rows, 3)
            test.is_false(model.apply_page(state, ok({subscription_id = "s-1", records = {}, from_sequence = 3, scanned_through = 3, has_more = false})))
        end)
        test.it("resumes a remembered subscription, asks for resume on a stale lease and re-subscribes when the owner forgot it", function()
            local state = model.new("bee.timeline.i1")
            model.open(state, "t-1", "s-1")
            local intent = model.attach_intent(state, "k-1")
            if not intent then error("intent") end
            test.eq(intent.target, model.RESUME)
            test.eq(intent.request.subscription_id, "s-1")
            model.apply_attach(state, ok(summary("s-1", 40, 2, 3)))
            test.eq(state.phase, "attached")
            test.eq(state.dropped_through, 40)
            test.eq(state.session and state.session.lease_generation, 2)
            model.apply_ack(state, fault("CONFLICT", "the subscription belongs to an earlier owner incarnation; resume it"))
            test.eq(state.phase, "resume_required")
            model.retry(state)
            test.eq(state.phase, "attaching")
            local again = model.attach_intent(state, "k-2")
            if not again then error("again") end
            test.eq(again.target, model.RESUME)
            model.apply_attach(state, ok(summary("s-1", 40, 2, 3)))
            test.eq(state.phase, "resume_required")
            model.retry(state)
            model.apply_attach(state, ok(summary("s-1", 41, 3, 4)))
            test.eq(state.phase, "attached")
            test.eq(state.session and state.session.after_sequence, 41)
            local forgotten = model.new("bee.timeline.i1")
            model.open(forgotten, "t-1", "s-old")
            model.apply_attach(forgotten, fault("NOT_FOUND", "subscription does not exist"))
            test.eq(forgotten.phase, "attaching")
            test.is_nil(forgotten.subscription_id)
            test.eq(model.attach_intent(forgotten, "k-3") and model.attach_intent(forgotten, "k-3").target, model.SUBSCRIBE)
            local denied = model.new("bee.timeline.i1")
            model.open(denied, "t-1", nil)
            model.apply_attach(denied, fault("DENIED", "caller is not a member of the thread"))
            test.eq(denied.phase, "unavailable")
            test.eq(denied.unavailable, "DENIED: caller is not a member of the thread")
            test.eq(#denied.rows, 0)
        end)
        test.it("detaches on silence without changing the cursor, marks gaps and dropped rows, and checkpoints identity", function()
            local state = model.new("bee.timeline.i1")
            model.open(state, "t-1", nil)
            model.apply_attach(state, ok(summary("s-1", 0, 1, 1)))
            local records: {Object} = {}
            for sequence = 1, 64 do records[#records + 1] = message(sequence, "m" .. tostring(sequence)) end
            model.apply_page(state, page("p-1", 1, 0, 64, records, true))
            model.apply_ack(state, ok({after_sequence = 64}))
            for batch = 1, 8 do
                local more: {Object} = {}
                for sequence = batch * 64 + 1, batch * 64 + 64 do more[#more + 1] = message(sequence, "x") end
                model.apply_page(state, page("p-" .. tostring(batch + 1), 1, batch * 64, batch * 64 + 64, more, true))
                model.apply_ack(state, ok({after_sequence = batch * 64 + 64}))
            end
            test.eq(#state.rows, model.MAX_ROWS)
            test.eq(state.dropped_through, 576 - model.MAX_ROWS)
            test.eq(state.rows[1].sequence, 576 - model.MAX_ROWS + 1)
            model.lost(state)
            test.eq(state.session and state.session.state, "detached")
            test.eq(state.session and state.session.after_sequence, 576)
            test.eq(state.unavailable, "no answer from the thread owner")
            -- Acknowledgment moves the owner's cursor, not proof the viewer
            -- saw the rows: a checkpoint after ack but before the rows are
            -- persisted, restored on a fresh instance, resumes past the
            -- acknowledged rows and shows them as a gap, never as seen.
            local crash = model.checkpoint(state)
            local recovered = model.new("bee.timeline.i3")
            test.is_true(model.restore(recovered, crash))
            model.apply_attach(recovered, ok(summary("s-1", 576, 2, 1)))
            test.eq(recovered.dropped_through, 576)
            test.eq(#recovered.rows, 0)
            test.is_false(model.apply_page(recovered, ok({subscription_id = "s-1", records = {}, from_sequence = 576, scanned_through = 576, has_more = false})))
            model.reconnect(state)
            test.eq(state.session and state.session.state, "attached")
            model.apply_page(state, page("p-x", 1, 600, 601, {message(601, "late")}, false))
            test.eq(state.gap_after, 576)
            model.select(state, 601)
            test.is_false(state.follow)
            model.toggle_technical(state)
            local saved = model.checkpoint(state)
            local restored = model.new("bee.timeline.i2")
            test.is_true(model.restore(restored, saved))
            test.eq(restored.thread_id, "t-1")
            test.eq(restored.subscription_id, "s-1")
            test.eq(restored.phase, "attaching")
            test.eq(restored.selected, 601)
            test.is_false(restored.follow)
            test.is_true(restored.technical)
            test.is_false(model.restore(model.new("x"), "5"))
            test.is_false(model.restore(model.new("x"), '{"thread_id": "a\\u0007b"}'))
            test.is_false(model.restore(model.new("x"), '{"selected": "no"}'))
            local blank = model.new("x")
            test.is_true(model.restore(blank, "{}"))
            test.eq(blank.phase, "picking")
            model.close_thread(state)
            test.eq(state.phase, "picking")
            test.is_nil(state.session)
        end)
    end)
end
return require("test").run_cases(define_tests)
