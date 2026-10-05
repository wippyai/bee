local test = require("test")
local bounds = require("bounds")
local funcs = require("funcs")
local security = require("security")
local sessions = require("sessions")
local protocol = require("protocol")

local function client(): sessions.Client
    return sessions.client()
end


-- Runs one probe scenario as an application handler processing `event`.
local function handler(event: string, scenario: string): {[string]: unknown}
    local policy, policy_error = security.policy("bee.tests.sessions:probe_policy")
    if not policy then error(tostring(policy_error)) end
    local result, failure = funcs.new():with_actor(security.new_actor("event:" .. event))
        :with_scope(security.new_scope({policy})):call("bee.tests.sessions:probe", {scenario = scenario})
    if failure then error("probe: " .. tostring(failure)) end
    return assert((bounds.object(result)))
end

local function define_tests()
    test.describe("Sessions client one call", function()
        test.it("runs and awaits inside an application handler", function()
            local result = handler("evt-1", "call")
            test.eq(result.tag, "ready")
            test.eq(result.work, "bw:n:w:ready")
        end)

        test.it("keeps the work on pending, blocked and uncertain observations", function()
            local client = client()
            for _, tag in ipairs({"pending", "blocked", "uncertain"}) do
                local result, fault = client:call({definition = "research:" .. tag, input = "go", operation_key = "call/" .. tag})
                test.is_nil(fault)
                test.eq(result and result.observation.tag, tag)
                test.eq(result and result.work:ref(), "bw:n:w:" .. tag)
            end
        end)

        test.it("returns the succeeded value of a ready observation", function()
            local result = assert((client():call({definition = "research:ready", input = "go", operation_key = "call/ready"})))
            local observation = result.observation
            if observation.tag ~= "ready" then error("expected ready") end
            test.eq(observation.result.outcome, "succeeded")
        end)

        test.it("reports an unsuccessful settlement as a ready observation", function()
            local result = assert((client():call({definition = "research:failed", input = "go", operation_key = "call/failed"})))
            local observation = result.observation
            if observation.tag ~= "ready" then error("expected ready") end
            test.eq(observation.result.outcome, "failed")
        end)
    end)

    test.describe("Session terminals", function()
        test.it("opens and calls a session as the agent's live terminal session", function()
            local opened = assert((client():open({definition = "research:worker", operation_key = "terminal/open"})))
            test.eq(opened.snapshot.terminal, true)
            local called = assert((client():call({definition = "research:window", input = "go", operation_key = "terminal/call"})))
            test.eq(called.work:ref(), "bw:n:w:window")
        end)
        test.it("forwards a chosen folder on open", function()
            local opened, fault = client():open({definition = "research:folder", workdir = {root_ref = "bee.node:machine", path = "home/project"},
                operation_key = "folder/open"})
            test.is_nil(fault)
            test.not_nil(opened)
        end)
    end)

    test.describe("Sessions operation keys", function()
        test.it("requires an explicit key even inside an application handler", function()
            local api = assert((bounds.object(sessions)))
            local open = api.open
            assert((type(open) == "function"))
            local opened, raw_fault = open({definition = "research:worker"})
            local fault = type(raw_fault) == "table" and raw_fault or nil
            test.is_nil(opened)
            test.eq(fault and fault.code, "KEY_REQUIRED")
            test.eq(fault and fault.retry, "never")
            test.eq(handler("evt-1", "context").code, "KEY_REQUIRED")
            test.eq(tostring(fault), "KEY_REQUIRED: pass an explicit operation_key for every mutation")
        end)

        test.it("accepts a caller-owned operation key", function()
            local opened, fault = sessions.open({definition = "research:worker", operation_key = "journal/open-1"})
            test.is_nil(fault)
            test.eq(opened and opened.receipt and opened.receipt.operation, "bo:n:w:journal_open_1")
        end)

        test.it("replays only the explicit key and ignores process identity", function()
            local first = handler("evt-1", "keys")
            local replay = handler("evt-1", "keys")
            local next_event = handler("evt-2", "keys")
            test.eq(first.first, first.again)
            test.neq(first.labelled, first.first)
            test.neq(first.opened, first.other)
            for _, name in ipairs({"first", "labelled", "opened", "other"}) do test.eq(replay[name], first[name]) end
            for _, name in ipairs({"first", "labelled", "opened", "other"}) do test.eq(next_event[name], first[name]) end
        end)

        test.it("passes independent explicit keys through separate client instances", function()
            local one, two = client(), client()
            local a = assert((one:send({session = "bs:n:w:s1", input = "go", operation_key = "send/a"})))
            local b = assert((two:send({session = "bs:n:w:s1", input = "go", operation_key = "send/b"})))
            local again = assert((client():send({session = "bs:n:w:s1", input = "go", operation_key = "send/a"})))
            test.neq(a.receipt and a.receipt.operation, b.receipt and b.receipt.operation)
            test.eq(a.receipt and a.receipt.operation, again.receipt and again.receipt.operation)
        end)
    end)

    test.describe("Sessions handles", function()
        test.it("opens, sends, awaits and closes", function()
            local client = client()
            local session = assert((client:open({definition = "research:worker", operation_key = "open/handles"})))
            test.eq(session:ref(), "bs:n:w:s1")
            test.eq(session.incarnation, 1)
            local work = assert((session:send({input = "pending", operation_key = "send/handles"})))
            test.eq(work:ref(), "bw:n:w:pending")
            test.eq(work.receipt and work.receipt.state, "queued")
            local observed = assert((work:await({timeout_ms = 1000})))
            test.eq(observed.tag, "pending")
            local closing = assert((session:close({operation_key = "close/handles"})))
            test.eq(closing.receipt and closing.receipt.effect, "close")
            local closed = assert((closing:await()))
            test.eq(closed.subject, closing:ref())
        end)

        test.it("checks that a session owns the work it awaits", function()
            local client = client()
            local session = assert((client:open({definition = "research:worker", operation_key = "open/ownership"})))
            local other = assert((client:call({definition = "research:ready", input = "go", operation_key = "call/ownership"}))).work
            local observed, fault = session:await(other)
            test.is_nil(observed)
            test.eq(fault and fault.code, "INVALID")
            local mine = assert((session:send({input = "ready", operation_key = "send/ownership"})))
            test.eq(assert((session:await(mine))).tag, "ready")
        end)

        test.it("captures the incarnation and refuses a stale reference", function()
            local client = client()
            local session = assert((client:open({definition = "research:two", operation_key = "open/incarnation"})))
            test.eq(session.incarnation, 2)
            assert((session:send({input = "go", operation_key = "send/two"})))
            local stale, fault = client:send({session = "bs:n:w:s2", input = "go", operation_key = "send/stale"})
            test.is_nil(stale)
            test.eq(fault and fault.code, "STALE")
            test.not_nil(fault and fault.operation_key)
            local current = assert((client:send({session = "bs:n:w:s2", incarnation = 2, input = "go", operation_key = "send/current"})))
            test.eq(current.session, "bs:n:w:s2")
        end)

        test.it("rehydrates sessions and works without executing", function()
            local client = client()
            local session = assert((client:get("bs:n:w:s2")))
            test.eq(session.incarnation, 2)
            local work = assert((client:work("bw:n:w:two")))
            test.eq(work.incarnation, 2)
            test.eq(work.session, "bs:n:w:s2")
            local cancelling = assert((work:cancel({reason = "stop", operation_key = "cancel/rehydrated"})))
            test.eq(cancelling.receipt and cancelling.receipt.effect, "cancel")
            local ready_work = assert((client:work("bw:n:w:ready")))
            local state = assert((ready_work:state()))
            test.eq(state.phase, "settled")
            test.eq(state.sender.kind, "session")
            test.eq(state.sender.id, "bs:n:w:lead")
            test.eq(assert((work:state())).phase, "accepted")
        end)
    end)

    test.describe("Sessions faults", function()
        test.it("echoes the key of a refused mutation", function()
            local opened, fault = client():open({definition = "research:deny", operation_key = "open/deny"})
            test.is_nil(opened)
            test.eq(fault and fault.code, "DENIED")
            test.not_nil(fault and fault.operation_key)
        end)

        test.it("treats a lost or malformed mutation reply as an unknown outcome to replay by key", function()
            for _, name in ipairs({"lost", "malformed"}) do
                local opened, fault = client():open({definition = "research:" .. name, operation_key = "open/" .. name})
                test.is_nil(opened)
                test.eq(fault and fault.code, "UNKNOWN_OUTCOME")
                test.eq(fault and fault.retry, "same_key")
                test.not_nil(fault and fault.operation_key)
            end
        end)

        test.it("rejects a malformed await reply and a foreign subject as unavailable reads", function()
            local client = client()
            for _, name in ipairs({"malformed", "other"}) do
                local observed, fault = client:await({subject = "bw:n:w:" .. name})
                test.is_nil(observed)
                test.eq(fault and fault.code, "UNAVAILABLE")
                test.eq(fault and fault.retry, "refresh")
            end
        end)

        test.it("refuses malformed requests before dispatch", function()
            local client = client()
            local function refused(name: string, value: unknown)
                local fault = type(value) == "table" and assert((bounds.object(value))) or nil
                if not fault or fault.code ~= "INVALID" then error(name .. " returned " .. tostring(value)) end
            end
            refused("open definition", select(2, client:open({definition = 7, operation_key = "bad"})))
            refused("folder name", select(2, client:open({definition = "d:ready", workdir = "folder-1", operation_key = "bad-folder"})))
            refused("escaping folder", select(2, client:open({definition = "d:ready", workdir = {root_ref = "bee.node:machine", path = "../etc"}, operation_key = "bad-folder"})))
            refused("folder field", select(2, client:open({definition = "d:ready", workdir = {root_ref = "bee.node:machine", path = "x", access = "write"}, operation_key = "bad-folder"})))
            refused("large input", select(2, client:call({definition = "d:ready", input = string.rep("x", protocol.MAX_TEXT_BYTES + 1), operation_key = "large"})))
            refused("nil structured value", select(2, client:call({definition = "d:ready", input = {schema = "s", value = nil}, operation_key = "nil"})))
            refused("work ref in session position", select(2, client:send({session = "bw:n:w:w1", input = "go", operation_key = "bad-session"})))
            refused("newline operation key", select(2, client:send({session = "bs:n:w:s1", input = "go", operation_key = "bad\nkey"})))
            refused("session ref in await position", select(2, client:await({subject = "bs:n:w:s1"})))
            refused("oversized timeout", select(2, client:await({subject = "bw:n:w:w1", timeout_ms = 60001})))
            refused("operation ref in cancel position", select(2, client:cancel({work = "bo:n:w:o1", operation_key = "bad-work"})))
            refused("close mode", select(2, client:close({session = "bs:n:w:s1", mode = "drain", operation_key = "bad-mode"})))
            refused("newline key for send", select(2, client:send({session = "bs:n:w:s1", input = "go", operation_key = "bad\nkey"})))
        end)
    end)

    test.describe("Sessions joins, lists and catalog", function()
        test.it("joins an ordered work set with every child observation", function()
            local client = client()
            local first = assert((client:call({definition = "research:ready", input = "go", operation_key = "call/join-a"}))).work
            local second = assert((client:call({definition = "research:pending", input = "go", operation_key = "call/join-b"}))).work
            local joined = assert((client:join({works = {first, second}, timeout_ms = 1000, operation_key = "join/pending"})))
            test.eq(joined.tag, "pending")
            test.eq(#joined.children, 2)
            test.eq(joined.children[1].subject, first:ref())
            local done = assert((client:join({works = {first:ref()}, policy = "all_settled", operation_key = "join/done"})))
            if done.tag ~= "ready" then error("expected ready") end
            test.is_true(done.result.succeeded)
        end)

        test.it("validates the join request", function()
            local client = client()
            local function refused(joined: protocol.JoinAwait?, fault: protocol.Fault?): boolean
                return joined == nil and fault ~= nil and fault.code == "INVALID"
            end
            test.is_true(refused(client:join({works = {}, operation_key = "empty"})))
            test.is_true(refused(client:join({works = {"bw:n:w:a", "bw:n:w:a"}, operation_key = "duplicate"})))
            test.is_true(refused(client:join({works = {"bw:n:w:a"}, policy = "quorum", operation_key = "quorum-missing"})))
            test.is_true(refused(client:join({works = {"bw:n:w:a"}, policy = "quorum", quorum = 2, operation_key = "quorum-range"})))
            test.is_true(refused(client:join({works = {"bw:n:w:a"}, quorum = 1, operation_key = "quorum-policy"})))
            test.is_true(refused(client:join({works = {"bw:n:w:a"}, losers = "drop", operation_key = "loser-mode"})))
        end)

        test.it("lists sessions and catalog candidates", function()
            local client = client()
            local page = assert((client:list({filter = {lifecycle = "active", activity = "idle"}})))
            test.eq(#page.items, 1)
            local _, fault = client:list({filter = {activity = "waiting"}})
            test.eq(fault and fault.code, "INVALID")
            local catalog = assert((client:catalog({kind = "definition"})))
            test.eq(catalog.items[1].ref, "research:quick")
            test.is_true(catalog.complete)
        end)
    end)
end

return test.run_cases(define_tests)
