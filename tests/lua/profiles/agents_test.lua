-- MIT. The Agent window's sessions model over a scripted sessions client.
local test = require("test")
local agents = require("agents")
local sessions = require("sessions")
type Object = {[string]: unknown}
local function client_of(value: unknown): sessions.Client return value :: sessions.Client end
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
        await = function(_: any, _options: any): (unknown, nil)
            index = math.min(index + 1, #observations)
            return observations[index], nil
        end,
        state = function(): (unknown, nil) return {phase = phase}, nil end}
end
local function session(activity: string, queued: integer, sent: {Object}, refreshed: any): any
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
local function must_list(client: sessions.Client, include: boolean): agents.Listing
    local listing, err = agents.list(client, include)
    if not listing then error(tostring(err)) end
    return listing
end
local function must_open(client: sessions.Client, definition: string, profile: {id: string, revision: integer}?, key: string): agents.Conversation
    local conv, err = agents.open(client, definition, profile, key)
    if not conv then error(tostring(err)) end
    return conv
end
local function at(list: {Object}, index: integer): Object
    local value = list[index]
    if not value then error("missing call " .. tostring(index)) end
    return value
end
local function key_source(): () -> string
    local count = 0
    return function(): string count = count + 1; return "key-" .. tostring(count) end
end
local function define_tests()
    test.describe("Agent window catalog listing", function()
        test.it("asks for ready candidates only and orders by title", function()
            local asked: {Object} = {}
            local client: any = {catalog = function(_: any, options: Object): (unknown, nil)
                asked[#asked + 1] = options
                return {items = {candidate("b:two", "Two", "ready", {}), candidate("a:one", "One", "ready", {}),
                    candidate("x:exec", "Exec", "ready", {}, "executor")}, complete = true, unavailable_count = 2, diagnostics = {}}, nil
            end}
            local listing = must_list(client_of(client), false)
            test.eq(at(asked, 1).include_unavailable, false)
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
            local client: any = {catalog = function(_: any, options: Object): (unknown, nil)
                index = index + 1
                cursors[index] = options.cursor
                test.eq(options.include_unavailable, true)
                return pages[index], nil
            end}
            local listing = must_list(client_of(client), true)
            test.eq(cursors[2], "cursor-1")
            test.eq(listing.items[1].ref, "a:claude")
            test.is_true(listing.items[1].ready)
            test.eq(listing.items[2].reason, "codex is not installed")
            test.is_false(listing.items[2].ready)
            test.eq(listing.notes[1], "UNAVAILABLE: probe skipped")
        end)
        test.it("reports a catalog fault", function()
            local client: any = {catalog = function(): (nil, Object) return nil, {code = "DENIED", message = "no", retry = "never"} end}
            local listing, err = agents.list(client_of(client), false)
            test.is_nil(listing)
            test.eq(err, "DENIED: no")
        end)
    end)
    test.describe("Sessions directory and work control", function()
        test.it("pages every visible session and filters by its public workspace address", function()
            local asked: {Object} = {}
            local first = snapshot("working", 2)
            local second = snapshot("idle", 0)
            second.session, second.lifecycle = "bs:n:other:s2", "closed"
            local client: any = {list = function(_: any, options: Object): (unknown, nil)
                asked[#asked + 1] = options
                if options.cursor then return {items = {second}}, nil end
                return {items = {first}, next = "next"}, nil
            end}
            local rows = agents.directory(client_of(client), nil)
            test.eq(rows and #rows, 2)
            test.eq(rows and rows[2].lifecycle, "closed")
            test.eq(at(asked, 2).cursor, "next")
            rows = agents.directory(client_of(client), "w")
            test.eq(rows and #rows, 1)
        end)
        test.it("cancels working Work with a stable key and leaves the session open", function()
            local keys: {string} = {}
            local current: any = {state = "working", input = "fix", text = "", work = {
                cancel = function(_: any, options: Object): (nil, Object)
                    keys[#keys + 1] = tostring(options.operation_key)
                    return nil, {code = "UNKNOWN_OUTCOME", message = "lost reply", retry = "same_key"}
                end}}
            local conv: any = {turns = {{state = "queued", work = {}}, current}, lifecycle = "active", notice = ""}
            local source = key_source()
            test.is_false(agents.stop(conv :: agents.Conversation, source))
            test.is_false(agents.stop(conv :: agents.Conversation, source))
            test.eq(keys[1], keys[2])
            test.eq(conv.lifecycle, "active")
        end)
    end)
    test.describe("Agent window session conversation", function()
        test.it("opens a session under an operation key and profile", function()
            local seen: Object = {}
            local client: any = {open = function(_: any, options: Object): (any, nil)
                seen = options
                return session("idle", 0, {}, {}), nil
            end}
            local conv = must_open(client_of(client), "bee.driver.claude:default", {id = "p1", revision = 3}, "open-key")
            test.eq(seen.operation_key, "open-key")
            test.eq(seen.definition, "bee.driver.claude:default")
            test.eq(conv.activity, "idle")
            test.eq(conv.title, "Worker")
        end)
        test.it("keeps the send key across a failed attempt of the same text", function()
            local sent: {Object} = {}
            local conv = must_open(client_of({open = function(): (any, nil) return session("idle", 0, sent, {}), nil end}), "d:x", nil, "k")
            local keys = key_source()
            test.is_false(agents.submit(conv, "hello", keys))
            test.is_false(agents.submit(conv, "hello", keys))
            test.eq(at(sent, 1).operation_key, at(sent, 2).operation_key)
            test.is_true(conv.notice:find("owner unreachable", 1, true) ~= nil)
            test.is_false(agents.submit(conv, "other", keys))
            test.is_true(at(sent, 3).operation_key ~= at(sent, 1).operation_key)
        end)
        test.it("shows queued, then working, then the settled result and activity", function()
            local sent: {Object} = {}
            local pending: Object = {tag = "pending", reason = "timeout"}
            local ready: Object = {tag = "ready", result = {outcome = "succeeded", value = "done", artifacts = {}, usage = {}}}
            local produced = work("bw:1", {pending, pending, ready}, "reserved")
            local refreshed: any = {works = {produced}, activity = "working"}
            local conv = must_open(client_of({open = function(): (any, nil) return session("idle", 0, sent, refreshed), nil end}), "d:x", nil, "k")
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
            local conv = must_open(client_of({open = function(): (any, nil) return session("idle", 0, sent, refreshed), nil end}), "d:x", nil, "k")
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
