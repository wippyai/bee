local test = require("test")
local funcs = require("funcs")
local security = require("security")
local sessions = require("sessions")
local protocol = require("protocol")

local function scope(): sessions.Client
    local client, fault = sessions.scope("goal-1")
    if not client then error(tostring(fault and fault.message)) end
    return client
end

local function must(value: any, fault: any?): any
    if value == nil then error(fault and (tostring(fault.code) .. ": " .. tostring(fault.message)) or "no value") end
    return value
end

-- Runs one probe scenario as an application handler processing `event`.
local function handler(event: string, scenario: string): {[string]: unknown}
    local policy, policy_error = security.policy("bee.sessions:probe_policy")
    if not policy then error(tostring(policy_error)) end
    local result, failure = funcs.new():with_actor(security.new_actor("event:" .. event))
        :with_scope(security.new_scope({policy})):call("bee.sessions:probe", {scenario = scenario})
    if failure then error("probe: " .. tostring(failure)) end
    return result :: {[string]: unknown}
end

local function define_tests()
    test.describe("Sessions client one call", function()
        test.it("runs and awaits inside an application handler", function()
            local result = handler("evt-1", "call")
            test.eq(result.tag, "ready")
            test.eq(result.work, "bw:n:w:ready")
        end)

        test.it("keeps the work on pending, blocked and uncertain observations", function()
            local client = scope()
            for _, tag in ipairs({"pending", "blocked", "uncertain"}) do
                local result, fault = client:call({definition = "research:" .. tag, input = "go", key = tag})
                test.is_nil(fault)
                test.eq(result and result.observation.tag, tag)
                test.eq(result and result.work:ref(), "bw:n:w:" .. tag)
            end
        end)

        test.it("returns the succeeded value of a ready observation", function()
            local result = must(scope():call({definition = "research:ready", input = "go"}))
            local observation = result.observation
            if observation.tag ~= "ready" then error("expected ready") end
            test.eq(observation.result.outcome, "succeeded")
        end)

        test.it("reports an unsuccessful settlement as a ready observation", function()
            local result = must(scope():call({definition = "research:failed", input = "go"}))
            local observation = result.observation
            if observation.tag ~= "ready" then error("expected ready") end
            test.eq(observation.result.outcome, "failed")
        end)
    end)

    test.describe("Sessions operation keys", function()
        test.it("requires a durable context", function()
            local opened, fault = sessions.open({definition = "research:worker"})
            test.is_nil(opened)
            test.eq(fault and fault.code, "CONTEXT_REQUIRED")
            test.eq(fault and fault.retry, "never")
            test.eq(handler("evt-1", "context").session, "bs:n:w:s1")
        end)

        test.it("accepts an explicit journaled key without a context", function()
            local opened, fault = sessions.open({definition = "research:worker", operation_key = "journal/open-1"})
            test.is_nil(fault)
            test.eq(opened and opened.receipt and opened.receipt.operation, "bo:n:w:journal_open_1")
            local both, both_fault = sessions.open({definition = "research:worker", operation_key = "k", key = "l"})
            test.is_nil(both)
            test.eq(both_fault and both_fault.code, "INVALID")
        end)

        test.it("derives stable keys, replays identical calls and labels repeats", function()
            local first = handler("evt-1", "keys")
            local replay = handler("evt-1", "keys")
            local next_event = handler("evt-2", "keys")
            test.eq(first.first, first.again)
            test.eq(first.conflict, "KEY_REQUIRED")
            test.eq(first.different, "")
            test.neq(first.labelled, first.first)
            test.neq(first.opened, first.other)
            for _, name in ipairs({"first", "labelled", "opened", "other"}) do test.eq(replay[name], first[name]) end
            for _, name in ipairs({"first", "labelled", "opened", "other"}) do test.neq(next_event[name], first[name]) end
        end)

        test.it("scopes keys to the persisted identifier and target", function()
            local one, two = scope(), must(sessions.scope("goal-2"))
            local a = must(one:send({session = "bs:n:w:s1", input = "go"}))
            local b = must(two:send({session = "bs:n:w:s1", input = "go"}))
            local c = must(one:send({session = "bs:n:w:t1", input = "go"}))
            local again = must(scope():send({session = "bs:n:w:s1", input = "go"}))
            test.neq(a.receipt and a.receipt.operation, b.receipt and b.receipt.operation)
            test.neq(a.receipt and a.receipt.operation, c.receipt and c.receipt.operation)
            test.eq(a.receipt and a.receipt.operation, again.receipt and again.receipt.operation)
        end)
    end)

    test.describe("Sessions handles", function()
        test.it("opens, sends, awaits and closes", function()
            local client = scope()
            local session = must(client:open({definition = "research:worker"}))
            test.eq(session:ref(), "bs:n:w:s1")
            test.eq(session.incarnation, 1)
            local work = must(session:send({input = "pending"}))
            test.eq(work:ref(), "bw:n:w:pending")
            test.eq(work.receipt and work.receipt.state, "queued")
            local observed = must(work:await({timeout_ms = 1000}))
            test.eq(observed.tag, "pending")
            local closing = must(session:close({mode = "drain"}))
            test.eq(closing.receipt and closing.receipt.effect, "close")
            local closed = must(closing:await())
            test.eq(closed.subject, closing:ref())
        end)

        test.it("checks that a session owns the work it awaits", function()
            local client = scope()
            local session = must(client:open({definition = "research:worker"}))
            local other = must(client:call({definition = "research:ready", input = "go"})).work
            local observed, fault = session:await(other)
            test.is_nil(observed)
            test.eq(fault and fault.code, "INVALID")
            local mine = must(session:send({input = "ready"}))
            test.eq(must(session:await(mine)).tag, "ready")
        end)

        test.it("captures the incarnation and refuses a stale reference", function()
            local client = scope()
            local session = must(client:open({definition = "research:two"}))
            test.eq(session.incarnation, 2)
            must(session:send({input = "go"}))
            local stale, fault = client:send({session = "bs:n:w:s2", input = "go", key = "stale"})
            test.is_nil(stale)
            test.eq(fault and fault.code, "STALE")
            test.not_nil(fault and fault.operation_key)
            local current = must(client:send({session = "bs:n:w:s2", incarnation = 2, input = "go"}))
            test.eq(current.session, "bs:n:w:s2")
        end)

        test.it("rehydrates sessions and works without executing", function()
            local client = scope()
            local session = must(client:get("bs:n:w:s2"))
            test.eq(session.incarnation, 2)
            local work = must(client:work("bw:n:w:two"))
            test.eq(work.incarnation, 2)
            test.eq(work.session, "bs:n:w:s2")
            local cancelling = must(work:cancel({reason = "stop"}))
            test.eq(cancelling.receipt and cancelling.receipt.effect, "cancel")
            local state = must(must(client:work("bw:n:w:ready")):state())
            test.eq(state.phase, "settled")
            test.eq(state.sender, "bs:n:w:lead")
            test.eq(must(work:state()).phase, "accepted")
        end)
    end)

    test.describe("Sessions faults", function()
        test.it("echoes the key of a refused mutation", function()
            local opened, fault = scope():open({definition = "research:deny", key = "d"})
            test.is_nil(opened)
            test.eq(fault and fault.code, "DENIED")
            test.not_nil(fault and fault.operation_key)
        end)

        test.it("treats a lost or malformed mutation reply as an unknown outcome to replay by key", function()
            for _, name in ipairs({"lost", "malformed"}) do
                local opened, fault = scope():open({definition = "research:" .. name, key = name})
                test.is_nil(opened)
                test.eq(fault and fault.code, "UNKNOWN_OUTCOME")
                test.eq(fault and fault.retry, "same_key")
                test.not_nil(fault and fault.operation_key)
            end
        end)

        test.it("rejects a malformed await reply and a foreign subject as unavailable reads", function()
            local client = scope()
            for _, name in ipairs({"malformed", "other"}) do
                local observed, fault = client:await({subject = "bw:n:w:" .. name})
                test.is_nil(observed)
                test.eq(fault and fault.code, "UNAVAILABLE")
                test.eq(fault and fault.retry, "refresh")
            end
        end)

        test.it("refuses malformed requests before dispatch", function()
            local client = scope()
            local function refused(fault: protocol.Fault?): boolean return fault ~= nil and fault.code == "INVALID" end
            test.is_true(refused(select(2, client:open({definition = 7 :: any}))))
            test.is_true(refused(select(2, client:call({definition = "d:ready", input = string.rep("x", protocol.MAX_TEXT_BYTES + 1)}))))
            test.is_true(refused(select(2, client:call({definition = "d:ready", input = {schema = "s", value = nil}}))))
            test.is_true(refused(select(2, client:send({session = "bw:n:w:w1", input = "go"}))))
            test.is_true(refused(select(2, client:send({session = "bs:n:w:s1", input = "go", key = "bad\nkey"}))))
            test.is_true(refused(select(2, client:await({subject = "bs:n:w:s1"}))))
            test.is_true(refused(select(2, client:await({subject = "bw:n:w:w1", timeout_ms = 60001}))))
            test.is_true(refused(select(2, client:cancel({work = "bo:n:w:o1"}))))
            test.is_true(refused(select(2, client:close({session = "bs:n:w:s1", mode = "later" :: any}))))
            test.is_true(refused(select(2, client:send({session = "bs:n:w:s1", input = "go", key = "bad\nkey"}))))
        end)
    end)

    test.describe("Sessions joins, lists and catalog", function()
        test.it("joins an ordered work set with every child observation", function()
            local client = scope()
            local first = must(client:call({definition = "research:ready", input = "go", key = "a"})).work
            local second = must(client:call({definition = "research:pending", input = "go", key = "b"})).work
            local joined = must(client:join({works = {first, second}, timeout_ms = 1000}))
            test.eq(joined.tag, "pending")
            test.eq(#joined.children, 2)
            test.eq(joined.children[1].subject, first:ref())
            local done = must(client:join({works = {first:ref()}, policy = "all_settled", key = "j2"}))
            if done.tag ~= "ready" then error("expected ready") end
            test.is_true(done.result.succeeded)
        end)

        test.it("validates the join request", function()
            local client = scope()
            local function refused(joined: protocol.JoinAwait?, fault: protocol.Fault?): boolean
                return joined == nil and fault ~= nil and fault.code == "INVALID"
            end
            test.is_true(refused(client:join({works = {}})))
            test.is_true(refused(client:join({works = {"bw:n:w:a", "bw:n:w:a"}})))
            test.is_true(refused(client:join({works = {"bw:n:w:a"}, policy = "quorum"})))
            test.is_true(refused(client:join({works = {"bw:n:w:a"}, policy = "quorum", quorum = 2})))
            test.is_true(refused(client:join({works = {"bw:n:w:a"}, quorum = 1})))
            test.is_true(refused(client:join({works = {"bw:n:w:a"}, losers = "drop" :: any})))
        end)

        test.it("lists sessions and catalog candidates", function()
            local client = scope()
            local page = must(client:list({filter = {lifecycle = "active", activity = "idle"}}))
            test.eq(#page.items, 1)
            test.eq(page.feed, "f1")
            local _, fault = client:list({filter = {activity = "waiting"}})
            test.eq(fault and fault.code, "INVALID")
            local catalog = must(client:catalog({kind = "definition"}))
            test.eq(catalog.items[1].ref, "research:quick")
            test.is_true(catalog.complete)
        end)
    end)
end

return test.run_cases(define_tests)
