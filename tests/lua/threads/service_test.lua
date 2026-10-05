-- MIT. The Threads service: it advances the owner incarnation, announces each
-- commit on its thread, and serves the operations other nodes send to the
-- threads route as the calling node.
local test = require("test")
local system = require("system")
local bounds = require("bounds")
local harness = require("harness")
local sends = require("sends")
local owner = require("owner")
local transaction = require("transaction")
local protocol = require("protocol")

type Object = {[string]: unknown}

local PEER = "bee.threads.peer."

local function forward(op: string, args: Object): protocol.Reply
    local reply, err = protocol.call(assert(system.node.id()), op, args, "10s")
    if not reply then error(op .. ": " .. tostring(err)) end
    return reply
end

-- The thread owner's reply the route carries back.
local function owner_reply(reply: protocol.Reply): Object
    if not reply.ok then error("route failed: " .. tostring(reply.error)) end
    return assert(bounds.object(reply.value))
end

local function define_tests()
    test.describe("Threads service", function()
        local alice = harness.principal("alice", harness.ALL)
        local node = assert(system.node.id())
        local peer = PEER .. node

        test.it("has advanced the owner incarnation before serving", function()
            local db = harness.open()
            local result = transaction.read(db, function(tx)
                local incarnation, err = owner.current(tx)
                if err then return transaction.failure("INTERNAL", err) end
                return transaction.success(incarnation, false)
            end)
            db:release()
            test.is_true(result.ok)
            test.is_true((tonumber(result.value) or 0) >= 1)
        end)

        test.it("announces each record on its own thread only", function()
            local first = harness.thread(alice, "First")
            local second = harness.thread(alice, "Second")
            local feed = harness.committed(first)
            harness.value(alice:call("record", {thread_id = second, idempotency_key = harness.key(), kind = "message", body = harness.message("elsewhere", "other thread")}))
            harness.value(alice:call("record", {thread_id = first, idempotency_key = harness.key(), kind = "message", body = harness.message("here", "this thread")}))
            local event = feed.subscription:channel():receive()
            test.eq(event.path, first)
            test.eq(event.data.sequence, 1)
            feed:close()
        end)

        test.it("serves forwarded operations as the calling node under the thread's own membership", function()
            local thread_id = harness.thread(alice, "From a peer")
            local message = harness.message("peer-1", "hello from a peer")
            local digest = assert(sends.payload_digest(message))
            local request: Object = {thread_id = thread_id, idempotency_key = "peer-key", payload_digest = digest, message = message}
            local refused = owner_reply(forward("threads.send", request))
            test.is_false(refused.ok)
            test.eq((assert(bounds.object(refused.error))).code, "DENIED")
            harness.value(alice:call("join", {thread_id = thread_id, idempotency_key = harness.key(), member_id = peer, role = "participant", expected_revision = 1}))
            local sent = owner_reply(forward("threads.send", request))
            test.is_true(sent.ok)
            local committed = assert(bounds.object(sent.value))
            test.eq(committed.caller_node_id, node)
            test.eq(committed.sequence, 1)
            local replayed = owner_reply(forward("threads.send", request))
            test.is_true(replayed.replayed)
            local status = assert(bounds.object(owner_reply(forward("threads.send_status", {thread_id = thread_id, idempotency_key = "peer-key"})).value))
            test.is_true(status.committed)
            test.eq(status.record_id, committed.record_id)
            local watched = assert(bounds.object(owner_reply(forward("threads.watch", {thread_id = thread_id, after_sequence = 0, wait_ms = 0})).value))
            test.eq(watched.status, "ready")
        end)

        test.it("takes the calling node from the transport, never from the payload", function()
            local thread_id = harness.thread(alice, "Spoofed")
            local message = harness.message("peer-2", "spoof")
            local digest = assert(sends.payload_digest(message))
            local reply = forward("threads.send", {thread_id = thread_id, idempotency_key = "k", caller_node_id = "node-elsewhere", payload_digest = digest, message = message})
            test.is_false(reply.ok)
            test.contains(tostring(reply.error), "does not match the authenticated caller node")
        end)

        test.it("refuses operations a peer may not call", function()
            local reply = forward("threads.create", {thread_id = "t", idempotency_key = "k", title = "x"})
            test.is_false(reply.ok)
            test.contains(tostring(reply.error), "unknown threads operation")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
