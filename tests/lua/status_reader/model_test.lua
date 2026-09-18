-- MIT. The reader, pure: a generation fences replies from a superseded
-- binding, a replacement owner resets rather than continues, a projection
-- behind the head is stale and asks for another bounded refresh, a reply
-- older than what is held moves nothing, and an unreachable owner shows the
-- last status as unavailable, never as idle.
local test = require("test")
local reader = require("reader")
type Object = {[string]: unknown}
local function ok(value: Object): reader.Reply
    return {ok = true, error = nil, value = value, replayed = false}
end
local function fault(code: string, message: string): reader.Reply
    return {ok = false, error = {code = code, message = message}, value = nil, replayed = false}
end
local function status(activity: string, extra: Object?): Object
    local s: Object = {activity = activity, waiting_on_you = false, waiting_message_ids = {}, open_requests = 0,
        pending_approvals = 0, running_actions = 0, uncertain_actions = 0, open_actions = 0}
    for key, value in pairs(extra or {}) do s[key] = value end
    return s
end
local function define_tests()
    test.describe("Status reader", function()
        test.it("advances through update, derives through read, and schedules another refresh while behind", function()
            local r = reader.new()
            test.eq(r.availability, "unbound")
            test.is_nil(reader.update_intent(r, "k"))
            reader.bind(r, "t-1")
            test.eq(r.availability, "loading")
            local update = reader.update_intent(r, "k1")
            if not update then error("update") end
            test.eq(update.target, reader.UPDATE)
            reader.apply_update(r, update.generation, ok({revision = 1, through_sequence = 64, head_sequence = 130, owner_authority = "auth-1", owner_incarnation = 1}))
            test.is_true(reader.needs_refresh(r))
            local read = reader.read_intent(r)
            if not read then error("read") end
            reader.apply_read(r, read.generation, ok({revision = 1, through_sequence = 64, head_sequence = 130, owner_authority = "auth-1", status = status("running", {running_actions = 1, open_actions = 1})}))
            test.eq(r.availability, "stale")
            test.is_true(reader.value(r).stale)
            test.is_true(reader.needs_refresh(r))
            test.eq(r.status and r.status.activity, "running")
            local watch = reader.watch_intent(r)
            if not watch then error("watch") end
            test.eq(watch.request.after_sequence, 130)
            -- Caught up: ready, and the change-wait's after-cursor follows.
            reader.apply_update(r, r.generation, ok({revision = 2, through_sequence = 130, head_sequence = 130, owner_authority = "auth-1"}))
            reader.apply_read(r, r.generation, ok({revision = 2, through_sequence = 130, head_sequence = 130, owner_authority = "auth-1", status = status("idle")}))
            test.eq(r.availability, "ready")
            test.is_false(reader.value(r).stale)
            test.is_false(reader.needs_refresh(r))
            test.eq(reader.watch_intent(r).request.after_sequence, 130)
        end)
        test.it("fences a reply from a superseded binding", function()
            local r = reader.new()
            reader.bind(r, "t-1")
            local stale_read = reader.read_intent(r)
            if not stale_read then error("Missing read intent for bound thread") end
            reader.bind(r, "t-2")
            reader.apply_read(r, stale_read.generation, ok({revision = 5, through_sequence = 9, head_sequence = 9, owner_authority = "auth-1", status = status("running")}))
            test.eq(r.thread_id, "t-2")
            test.is_nil(r.status)
            test.eq(r.availability, "loading")
            reader.unbind(r)
            test.eq(r.availability, "unbound")
            test.is_nil(r.thread_id)
        end)
        test.it("resets on a replacement owner and ignores a reply older than what it holds", function()
            local r = reader.new()
            reader.bind(r, "t-1")
            reader.apply_read(r, r.generation, ok({revision = 4, through_sequence = 40, head_sequence = 40, owner_authority = "auth-1", status = status("waiting", {open_requests = 1})}))
            test.eq(r.availability, "ready")
            -- A reply older than the held revision under the same owner moves nothing.
            reader.apply_read(r, r.generation, ok({revision = 2, through_sequence = 20, head_sequence = 40, owner_authority = "auth-1", status = status("idle")}))
            test.eq(r.revision, 4)
            test.eq(r.status and r.status.activity, "waiting")
            -- A replacement owner authority resets the view and advances the
            -- generation so the previous authority's replies are retired.
            local before = r.generation
            reader.apply_update(r, r.generation, ok({revision = 1, through_sequence = 3, head_sequence = 3, owner_authority = "auth-2", owner_incarnation = 1}))
            test.eq(r.owner_authority, "auth-2")
            test.eq(r.revision, 1)
            test.is_nil(r.status)
            test.is_true(r.generation > before)
        end)
        test.it("fences a delayed reply from the previous owner after a same-thread replacement", function()
            local r = reader.new()
            reader.bind(r, "t-1")
            local old_generation = r.generation
            reader.apply_read(r, old_generation, ok({revision = 6, through_sequence = 60, head_sequence = 60, owner_authority = "auth-1", owner_incarnation = 2, status = status("running", {running_actions = 1})}))
            test.eq(r.owner_authority, "auth-1")
            -- The same thread is now served by a replacement owner; an update
            -- reply reveals the new authority and retires the old generation.
            reader.apply_update(r, r.generation, ok({revision = 1, through_sequence = 5, head_sequence = 5, owner_authority = "auth-2", owner_incarnation = 1}))
            test.eq(r.owner_authority, "auth-2")
            reader.apply_read(r, r.generation, ok({revision = 1, through_sequence = 5, head_sequence = 5, owner_authority = "auth-2", owner_incarnation = 1, status = status("idle")}))
            test.eq(r.status and r.status.activity, "idle")
            -- A delayed read from the previous authority, under the old
            -- generation, must not switch the reader back to auth-1.
            reader.apply_read(r, old_generation, ok({revision = 7, through_sequence = 70, head_sequence = 70, owner_authority = "auth-1", owner_incarnation = 2, status = status("running")}))
            test.eq(r.owner_authority, "auth-2")
            test.eq(r.revision, 1)
            test.eq(r.status and r.status.activity, "idle")
        end)
        test.it("shows an unreachable owner as unavailable, never idle, keeping the last status", function()
            local r = reader.new()
            reader.bind(r, "t-1")
            reader.apply_read(r, r.generation, ok({revision = 3, through_sequence = 9, head_sequence = 9, owner_authority = "auth-1", status = status("running", {running_actions = 1})}))
            reader.lost(r)
            test.eq(r.availability, "unavailable")
            test.eq(r.detail, "no answer from the thread owner")
            test.eq(r.status and r.status.activity, "running")
            test.neq(r.availability, "unbound")
            -- A denied read also surfaces unavailable with the fault, not idle.
            reader.apply_read(r, r.generation, fault("DENIED", "caller is not a member of the thread"))
            test.eq(r.availability, "unavailable")
            test.is_true(r.detail:find("DENIED", 1, true) ~= nil)
        end)
        test.it("rejects missing status instead of inventing idle", function()
            local r = reader.new()
            reader.bind(r, "t-1")
            reader.apply_read(r, r.generation, ok({revision = 1, through_sequence = 1, head_sequence = 1, owner_authority = "auth-1"}))
            test.eq(r.availability, "unavailable")
            test.is_nil(r.status)
        end)
        test.it("does not lower the observed head on an older update", function()
            local r = reader.new()
            reader.bind(r, "t-1")
            reader.apply_read(r, r.generation, ok({revision = 4, through_sequence = 40, head_sequence = 60, owner_authority = "auth-1", status = status("running")}))
            reader.apply_update(r, r.generation, ok({revision = 2, through_sequence = 20, head_sequence = 20, owner_authority = "auth-1"}))
            test.eq(r.head_sequence, 60)
            test.is_true(reader.needs_refresh(r))
        end)
        test.it("keeps a newer known head when the same projection is read again", function()
            local r = reader.new()
            reader.bind(r, "t-1")
            reader.apply_read(r, r.generation, ok({revision = 4, through_sequence = 40, head_sequence = 60, owner_authority = "auth-1", status = status("running")}))
            reader.apply_read(r, r.generation, ok({revision = 4, through_sequence = 40, head_sequence = 40, owner_authority = "auth-1", status = status("running")}))
            test.eq(r.head_sequence, 60)
            test.eq(r.availability, "stale")
            test.is_true(reader.needs_refresh(r))
        end)
        test.it("coalesces a change-wait wakeup into one pending refresh", function()
            local r = reader.new()
            reader.bind(r, "t-1")
            reader.apply_read(r, r.generation, ok({revision = 1, through_sequence = 5, head_sequence = 5, owner_authority = "auth-1", status = status("idle")}))
            test.is_false(reader.needs_refresh(r))
            reader.apply_watch(r, r.generation, ok({status = "ready", scanned_through = 5, head_sequence = 7}))
            test.is_true(reader.needs_refresh(r))
            reader.apply_watch(r, r.generation, ok({status = "ready", scanned_through = 5, head_sequence = 9}))
            test.is_true(reader.needs_refresh(r))
        end)
    end)
end
return require("test").run_cases(define_tests)
