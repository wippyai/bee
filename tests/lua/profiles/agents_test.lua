-- MIT. The Agent window's sessions model over a scripted sessions client.
local test = require("test")
local agents = require("agents")
type Object = {[string]: unknown}
local function candidate(ref: string, title: string, status: string, reasons: {string}, kind: string?): Object
    return {ref = ref, kind = kind or "definition", title = title, status = status, checked_at = "t", reasons = reasons,
        features = {}, actions = {}}
end
local function snapshot(activity: string, queued: integer): Object
    return {session = "bs:n:w:s1", revision = 1, incarnation = 1, title = "Worker", lifecycle = "active", activity = activity,
        queue_count = queued}
end
local function work(ref: string, observations: {Object}, phase: string): any
    local index = 0
    return {ref = function(): string return ref end, session = "bs:n:w:s1", incarnation = 1,
        await = function(_: any, _options: any): (Object, nil)
            index = math.min(index + 1, #observations)
            return observations[index], nil
        end,
        state = function(): (Object, nil) return {phase = phase}, nil end}
end
local function session(activity: string, queued: integer, sent: {Object}, refreshed: {any}): any
    local handle: any = {snapshot = snapshot(activity, queued)}
    local reads = 0
    handle.send = function(_: any, options: Object): (any, Object?)
        sent[#sent + 1] = options
        local produced = refreshed.works and refreshed.works[#sent]
        if not produced then return nil, {code = "UNAVAILABLE", message = "owner unreachable", retry = "same_key", operation_key = options.operation_key} end
        return produced, nil
    end
    handle.get = function(): (any, Object?)
        reads = reads + 1
        local next_handle: any = {snapshot = snapshot(refreshed.activity or activity, 0), get = handle.get, send = handle.send}
        return next_handle, nil
    end
    return handle
end
local function key_source(): () -> string
    local count = 0
    return function(): string count = count + 1; return "key-" .. tostring(count) end
end
local function define_tests()
    test.describe("Agent window catalog listing", function()
        test.it("asks for ready candidates only and orders by title", function()
            local asked: {Object} = {}
            local client: any = {catalog = function(_: any, options: Object): (Object, nil)
                asked[#asked + 1] = options
                return {items = {candidate("b:two", "Two", "ready", {}), candidate("a:one", "One", "ready", {}),
                    candidate("x:exec", "Exec", "ready", {}, "executor")}, complete = true, unavailable_count = 2, diagnostics = {}}, nil
            end}
            local listing = agents.list(client, false)
            test.eq(asked[1].include_unavailable, false)
            test.eq(#listing.items, 2)
            test.eq(listing.items[1].ref, "a:one")
            test.eq(listing.unavailable, 2)
        end)
        test.it("shows unavailable candidates after ready ones with their reason and follows pages", function()
            local pages = {
                {items = {candidate("c:codex", "Codex", "missing", {"codex is not installed"})}, next = "cursor-1", complete = false,
                    unavailable_count = 1, diagnostics = {}},
                {items = {candidate("a:claude", "Claude", "ready", {})}, complete = true, unavailable_count = 1,
                    diagnostics = {{code = "UNAVAILABLE", message = "probe skipped", retry = "refresh"}}},
            }
            local index = 0
            local cursors: {unknown} = {}
            local client: any = {catalog = function(_: any, options: Object): (Object, nil)
                index = index + 1
                cursors[index] = options.cursor
                test.eq(options.include_unavailable, true)
                return pages[index], nil
            end}
            local listing = agents.list(client, true)
            test.eq(cursors[2], "cursor-1")
            test.eq(listing.items[1].ref, "a:claude")
            test.is_true(listing.items[1].ready)
            test.eq(listing.items[2].reason, "codex is not installed")
            test.is_false(listing.items[2].ready)
            test.eq(listing.notes[1], "UNAVAILABLE: probe skipped")
        end)
        test.it("reports a catalog fault", function()
            local client: any = {catalog = function(): (nil, Object) return nil, {code = "DENIED", message = "no", retry = "never"} end}
            local listing, err = agents.list(client, false)
            test.is_nil(listing)
            test.eq(err, "DENIED: no")
        end)
    end)
    test.describe("Agent window session conversation", function()
        test.it("opens a session under an operation key and profile", function()
            local seen: Object = {}
            local client: any = {open = function(_: any, options: Object): (any, nil)
                seen = options
                return session("idle", 0, {}, {}), nil
            end}
            local conv = agents.open(client, "bee.driver.claude:default", {id = "p1", revision = 3}, "open-key")
            test.eq(seen.operation_key, "open-key")
            test.eq(seen.definition, "bee.driver.claude:default")
            test.eq(conv.activity, "idle")
            test.eq(conv.title, "Worker")
        end)
        test.it("keeps the send key across a failed attempt of the same text", function()
            local sent: {Object} = {}
            local conv = agents.open({open = function(): (any, nil) return session("idle", 0, sent, {}), nil end} :: any, "d:x", nil, "k")
            local keys = key_source()
            test.is_false(agents.submit(conv, "hello", keys))
            test.is_false(agents.submit(conv, "hello", keys))
            test.eq(sent[1].operation_key, sent[2].operation_key)
            test.is_true(conv.notice:find("owner unreachable", 1, true) ~= nil)
            test.is_false(agents.submit(conv, "other", keys))
            test.is_true(sent[3].operation_key ~= sent[1].operation_key)
        end)
        test.it("shows queued, then working, then the settled result and activity", function()
            local sent: {Object} = {}
            local pending: Object = {tag = "pending", reason = "timeout"}
            local ready: Object = {tag = "ready", result = {outcome = "succeeded", value = "done", artifacts = {}, usage = {}}}
            local produced = work("bw:1", {pending, pending, ready}, "reserved")
            local refreshed: any = {works = {produced}, activity = "working"}
            local conv = agents.open({open = function(): (any, nil) return session("idle", 0, sent, refreshed), nil end} :: any, "d:x", nil, "k")
            test.is_true(agents.submit(conv, "hello", key_source()))
            test.eq(conv.turns[1].state, "queued")
            test.is_true(agents.pending(conv))
            agents.refresh(conv)
            test.eq(conv.turns[1].state, "working")
            test.eq(conv.activity, "working")
            refreshed.activity = "idle"
            agents.refresh(conv)
            agents.refresh(conv)
            test.eq(conv.turns[1].state, "ready")
            test.eq(conv.turns[1].text, "done")
            test.eq(conv.activity, "idle")
            test.is_false(agents.pending(conv))
        end)
        test.it("shows unsuccessful, blocked and uncertain observations", function()
            local sent: {Object} = {}
            local failed: Object = {tag = "ready", result = {outcome = "failed", error = {code = "TIMEOUT", message = "slow", retry = "never"}, artifacts = {}}}
            local blocked: Object = {tag = "blocked", blocker = {kind = "budget", message = "budget spent", subject = "s", actions = {}}}
            local uncertain: Object = {tag = "uncertain", evidence = {summary = "outcome unprovable", artifacts = {}}}
            local refreshed: any = {works = {work("bw:1", {failed}, "accepted"), work("bw:2", {blocked}, "accepted"),
                work("bw:3", {uncertain}, "accepted")}}
            local conv = agents.open({open = function(): (any, nil) return session("idle", 0, sent, refreshed), nil end} :: any, "d:x", nil, "k")
            local keys = key_source()
            for _, text in ipairs({"a", "b", "c"}) do test.is_true(agents.submit(conv, text, keys)) end
            agents.refresh(conv)
            test.eq(conv.turns[1].state, "failed")
            test.eq(conv.turns[1].text, "failed: TIMEOUT: slow")
            test.eq(conv.turns[2].state, "blocked")
            test.eq(conv.turns[2].text, "budget spent")
            test.eq(conv.turns[3].state, "uncertain")
            test.eq(conv.turns[3].text, "outcome unprovable")
        end)
    end)
end
return test.run_cases(define_tests)
