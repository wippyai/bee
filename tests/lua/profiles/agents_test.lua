-- MIT. The Agent window's sessions model over a scripted sessions client.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local agents = require("agents")
local sessions = require("sessions")
type Object = {[string]: unknown}
local fixtures = require("fixtures")
local protocol = require("protocol")
type Refreshed = {works: {sessions.Work}?, activity: string?}
local function candidate(ref: string, title: string, status: string, reasons: {string}, kind: string?): Object
    return {ref = ref, kind = kind or "definition", title = title, status = status, checked_at = "2026-09-30T12:00:00.000Z", reasons = reasons,
        features = {"presentation:start_menu"}, actions = {}}
end
local function snapshot(activity: string, queued: integer): protocol.SessionSnapshot
    return fixtures.fixture_snapshot("bs:n:w:s1", "Worker", activity, queued)
end
local function work(ref: string, observations: {Object}, phase: string): sessions.Work
    local index = 0
    return fixtures.fixture_work(ref, {
        await = function(): (protocol.WorkAwait?, sessions.Fault?)
            index = math.min(index + 1, #observations)
            local value = observations[index]
            value.subject_kind, value.subject, value.cursor = "work", "bw:n:w:fixture", "cursor"
            if value.tag == "ready" then
                local result = assert(bounds.object(value.result))
                if result.outcome == "succeeded" then result.schema = "bee:Text@1" end
            end
            return assert(protocol.decode_work_await(value)), nil
        end,
        state = function(): (protocol.WorkState?, sessions.Fault?)
            return assert(protocol.decode_work_state({work = "bw:n:w:fixture", session = "bs:n:w:s1",
                sender = {kind = "principal", id = "principal:fixture"}, revision = 1, cancelling = false, phase = phase})), nil
        end,
    })
end
local function session(activity: string, queued: integer, sent: {Object}, refreshed: Refreshed): sessions.Session
    local function send(options: sessions.SendOptions): (sessions.Work?, sessions.Fault?)
        sent[#sent + 1] = assert(bounds.object(options))
        local produced = refreshed.works and refreshed.works[#sent]
        if not produced then return nil, protocol.fault("UNAVAILABLE", "owner unreachable", "same_key", options.operation_key) end
        return produced, nil
    end
    local function get(): (sessions.Session?, sessions.Fault?)
        return fixtures.fixture_session(snapshot(refreshed.activity or activity, 0), {get = get, send = send}), nil
    end
    return fixtures.fixture_session(snapshot(activity, queued), {get = get, send = send})
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
            local client: unknown = {catalog = function(_self: unknown, options: unknown): (unknown, nil)
                asked[#asked + 1] = assert(bounds.object(options))
                return {items = {candidate("b:two", "Two", "ready", {}), candidate("a:one", "One", "ready", {}),
                    candidate("x:exec", "Exec", "ready", {}, "executor")}, complete = true, unavailable_count = 2, diagnostics = {}}, nil
            end}
            local api = assert(bounds.object(agents))
            local list = api.list
            assert(type(list) == "function")
            local raw, err = list(client, false)
            local listing = assert(bounds.object(raw), tostring(err))
            local items = principals.objects(listing.items)
            test.eq(at(asked, 1).include_unavailable, true)
            test.eq(#items, 2)
            test.eq(items[1].ref, "a:one")
            test.eq(listing.unavailable, 0)
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
            local client = fixtures.fixture_client({catalog = function(options: sessions.CatalogOptions): (unknown, sessions.Fault?)
                index = index + 1
                cursors[index] = options.cursor
                test.eq(options.include_unavailable, true)
                return pages[index], nil
            end})
            local listing = must_list(client, true)
            test.eq(cursors[2], "cursor-1")
            test.eq(listing.items[1].ref, "a:claude")
            test.is_true(listing.items[1].ready)
            test.eq(listing.items[2].reason, "codex is not installed")
            test.is_false(listing.items[2].ready)
            test.eq(listing.notes[1], "UNAVAILABLE: probe skipped")
        end)
        test.it("hides programmatic routes from the person catalog", function()
            local hidden = candidate("c:batch", "Research batch", "ready", {})
            hidden.features = {}
            local scripted = fixtures.fixture_client({catalog = function(_options: sessions.CatalogOptions): (unknown, sessions.Fault?)
                return {items = {candidate("c:window", "Claude", "ready", {}), hidden}, complete = true, unavailable_count = 0, diagnostics = {}}, nil
            end})
            local listing = must_list(scripted, true)
            test.eq(#listing.items, 1)
            test.eq(listing.items[1].title, "Claude")
        end)
        test.it("reports a catalog fault", function()
            local client = fixtures.fixture_client({catalog = function(): (unknown, sessions.Fault?) return nil, protocol.fault("DENIED", "no", "never", nil) end})
            local listing, err = agents.list(client, false)
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
            local client = fixtures.fixture_client({list = function(options: sessions.ListOptions): (unknown, sessions.Fault?)
                asked[#asked + 1] = assert(bounds.object(options))
                if options.cursor then return {items = {second}}, nil end
                return {items = {first}, next = "next"}, nil
            end})
            local rows = agents.directory(client, nil)
            test.eq(rows and #rows, 2)
            test.eq(rows and rows[2].lifecycle, "closed")
            test.eq(at(asked, 2).cursor, "next")
            rows = agents.directory(client, "w")
            test.eq(rows and #rows, 1)
        end)
        test.it("keeps uncertain work observable without offering it as current work", function()
            local conv: agents.Conversation = {session = session("idle", 0, {}, {}), title = "Worker", lifecycle = "active",
                activity = "idle", queued = 0, notice = "", turns = {{state = "uncertain", input = "fix", text = "Outcome unknown", work = fixtures.fixture_work("bw:1", {})}}}
            test.is_false(agents.pending(conv))
        end)
        test.it("cancels working Work with a stable key and leaves the session open", function()
            local keys: {string} = {}
            local current: agents.Turn = {state = "working", input = "fix", text = "", work = fixtures.fixture_work("bw:1", {
                cancel = function(options: sessions.CancelOptions): (sessions.Operation?, sessions.Fault?)
                    keys[#keys + 1] = options.operation_key
                    return nil, protocol.fault("UNKNOWN_OUTCOME", "lost reply", "same_key", nil)
                end})}
            local conv: agents.Conversation = {session = session("idle", 0, {}, {}), title = "Worker", activity = "working", queued = 1,
                turns = {{state = "queued", input = "", text = "", work = fixtures.fixture_work("bw:0", {})}, current}, lifecycle = "active", notice = ""}
            local source = key_source()
            test.is_false(agents.stop(conv, source))
            test.is_false(agents.stop(conv, source))
            test.eq(keys[1], keys[2])
            test.eq(conv.lifecycle, "active")
        end)
    end)
    test.describe("Agent window session conversation", function()
        test.it("opens a session under an operation key and profile", function()
            local seen: Object = {}
            local client = fixtures.fixture_client({open = function(options: sessions.OpenOptions): (sessions.Session?, sessions.Fault?)
                seen = assert(bounds.object(options))
                return session("idle", 0, {}, {}), nil
            end})
            local conv = must_open(client, "bee.driver.claude:default", {id = "p1", revision = 3}, "open-key")
            test.eq(seen.operation_key, "open-key")
            test.eq(seen.definition, "bee.driver.claude:default")
            test.eq(conv.activity, "idle")
            test.eq(conv.title, "Worker")
        end)
        test.it("keeps the send key across a failed attempt of the same text", function()
            local sent: {Object} = {}
            local conv = must_open(fixtures.fixture_client({open = function(): (sessions.Session?, sessions.Fault?) return session("idle", 0, sent, {}), nil end}), "d:x", nil, "k")
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
            local refreshed: Refreshed = {works = {produced}, activity = "working"}
            local conv = must_open(fixtures.fixture_client({open = function(): (sessions.Session?, sessions.Fault?) return session("idle", 0, sent, refreshed), nil end}), "d:x", nil, "k")
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
        test.it("displays a structured text outcome with real newlines", function()
            local produced = work("bw:1", {{tag = "ready", result = {outcome = "succeeded", value = {text = "hello\nworld"}, artifacts = {}, usage = {}}}}, "accepted")
            local conv = must_open(fixtures.fixture_client({open = function(): (sessions.Session?, sessions.Fault?) return session("idle", 0, {}, {works = {produced}}), nil end}), "d:x", nil, "k")
            agents.submit(conv, "hello", key_source())
            agents.refresh(conv)
            test.eq(conv.turns[1].text, "hello\nworld")
        end)
        test.it("labels other structured results without promising unavailable Details content", function()
            local produced = work("bw:1", {{tag = "ready", result = {outcome = "succeeded", value = {count = 3}, artifacts = {}, usage = {}}}}, "accepted")
            local conv = must_open(fixtures.fixture_client({open = function(): (sessions.Session?, sessions.Fault?) return session("idle", 0, {}, {works = {produced}}), nil end}), "d:x", nil, "k")
            agents.submit(conv, "Count the items", key_source())
            agents.refresh(conv)
            test.eq(conv.turns[1].text, "Completed · structured result")
        end)
        test.it("shows unsuccessful, blocked and uncertain observations", function()
            local sent: {Object} = {}
            local failed: Object = {tag = "ready", result = {outcome = "failed", error = {code = "TIMEOUT", message = "slow", retry = "never"}, artifacts = {}}}
            local blocked: Object = {tag = "blocked", blocker = {kind = "budget", message = "budget spent", subject = "s", actions = {}}}
            local uncertain: Object = {tag = "uncertain", evidence = {summary = "outcome unprovable", artifacts = {}}}
            local refreshed: Refreshed = {works = {work("bw:1", {failed}, "accepted"), work("bw:2", {blocked}, "accepted"),
                work("bw:3", {uncertain}, "accepted")}}
            local conv = must_open(fixtures.fixture_client({open = function(): (sessions.Session?, sessions.Fault?) return session("idle", 0, sent, refreshed), nil end}), "d:x", nil, "k")
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
