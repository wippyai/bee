-- MIT. Session addressing on a message: the authority accepts recipient
-- actions only when they are actions of the thread the message lands on,
-- and a sending action only when it is the sender's own admitted work.
local test = require("test")
local harness = require("harness")
type Object = {[string]: unknown}
local function admitted_for(principal: string): Object
    local body = harness.admitted() :: Object
    body.principal_id = principal
    return body
end
local function addressed(id: string, recipient_actions: {string}?, sender_action: string?): Object
    local body = harness.message(id, "go ahead") :: Object
    if recipient_actions then body.recipient_action_ids = recipient_actions end
    if sender_action then body.sender_action_id = sender_action end
    return body
end
local function define_tests()
    test.describe("Thread message session addressing", function()
        local alice = harness.principal("alice", harness.ALL)
        local bob = harness.principal("bob", harness.ALL)
        test.it("records recipient and sending actions the authority can verify", function()
            local waiting = harness.thread(alice, "Waiting session")
            local sending = harness.thread(alice, "Sending session")
            harness.value(alice:call("admit_action", {thread_id = waiting, idempotency_key = harness.key(), action_id = "waiting-action", admitted = admitted_for("alice")}))
            harness.value(alice:call("admit_action", {thread_id = sending, idempotency_key = harness.key(), action_id = "sending-action", admitted = admitted_for("alice")}))
            local committed = harness.value(alice:call("record", {thread_id = waiting, idempotency_key = harness.key(), kind = "message",
                body = addressed("go-1", {"waiting-action"}, "sending-action")}))
            local page = harness.value(alice:call("read_after", {thread_id = waiting, cursor = committed.sequence - 1, limit = 1}))
            local body = page.records[1].body
            test.eq(body.recipient_action_ids[1], "waiting-action")
            test.eq(body.sender_action_id, "sending-action")
            test.eq(body.sender_id, "alice")
        end)
        test.it("refuses a recipient action that is not on the thread", function()
            local waiting = harness.thread(alice, "Waiting session")
            local elsewhere = harness.thread(alice, "Elsewhere")
            harness.value(alice:call("admit_action", {thread_id = elsewhere, idempotency_key = harness.key(), action_id = "elsewhere-action", admitted = admitted_for("alice")}))
            local refused = alice:call("record", {thread_id = waiting, idempotency_key = harness.key(), kind = "message", body = addressed("go-2", {"elsewhere-action"}, nil)})
            test.eq(harness.code(refused), "INVALID_ARGUMENT")
            test.eq(harness.head_sequence(waiting), 0)
        end)
        test.it("refuses a sending action the sender was not admitted for", function()
            local waiting = harness.thread(alice, "Waiting session")
            local foreign = harness.thread(bob, "Bob's session")
            harness.value(bob:call("admit_action", {thread_id = foreign, idempotency_key = harness.key(), action_id = "bob-action", admitted = admitted_for("bob")}))
            test.eq(harness.code(alice:call("record", {thread_id = waiting, idempotency_key = harness.key(), kind = "message", body = addressed("go-3", nil, "bob-action")})), "DENIED")
            test.eq(harness.code(alice:call("record", {thread_id = waiting, idempotency_key = harness.key(), kind = "message", body = addressed("go-4", nil, "never-admitted")})), "DENIED")
            test.eq(harness.head_sequence(waiting), 0)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
