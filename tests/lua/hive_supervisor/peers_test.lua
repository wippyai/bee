-- MIT. Tests for Hive supervisor peer exchange: state machine, transitions,
-- bounding, simultaneous exchange, replay/duplicate handling, replacement,
-- and isolation from callers.
local test = require("test")
local peers = require("peers")
local types = require("types")
local bounds = require("bounds")

local function pid(node: string, tag: string): string
    return "{" .. node .. "@" .. types.SUPERVISOR_HOST .. "|" .. tag .. "}"
end

local function make_config(node: string, inc: string, nodes: {string}, ttl: integer?, max_peers: integer?, max_pending: integer?): peers.Config
    return {
        local_node = node,
        local_incarnation = inc,
        configured_nodes = nodes,
        ttl_ms = ttl or 5000,
        max_peers = max_peers,
        max_pending = max_pending,
    }
end

local function define_tests()
    test.describe("Hive supervisor peer exchange", function()
        test.it("initializes state and enforces config bounds", function()
            local cfg = make_config("laptop", "inc-1", {"forge", "backup"}, 5000)
            local state, err = peers.new(cfg)
            if not state or err then error("new failed: " .. tostring(err)) end
            test.is_true(peers.is_configured(state, "forge"))
            test.is_false(peers.is_configured(state, "unknown"))

            -- Rejects local_node inside configured_nodes
            local bad_cfg = make_config("laptop", "inc-1", {"forge", "laptop"}, 5000)
            local _, err_bad = peers.new(bad_cfg)
            test.eq(err_bad, "configured_nodes cannot contain local_node")

            -- Rejects duplicate configured nodes
            local dup_cfg = make_config("laptop", "inc-1", {"forge", "forge"}, 5000)
            local _, err_dup = peers.new(dup_cfg)
            test.eq(err_dup, "duplicate configured node: forge")

            -- Rejects negative or zero TTL
            local ttl_cfg = make_config("laptop", "inc-1", {"forge"}, 0)
            local _, err_ttl = peers.new(ttl_cfg)
            test.eq(err_ttl, "ttl_ms must be a positive integer")
        end)

        test.it("handles normal two-state exchange to active peers", function()
            local stateA = peers.new(make_config("laptop", "inc-laptop", {"forge"}, 5000))
            local stateB = peers.new(make_config("forge", "inc-forge", {"laptop"}, 5000))
            if not stateA or not stateB then error("state init failed") end

            local pidA = pid("laptop", "pid-a-1")
            local pidB = pid("forge", "pid-b-1")

            -- 1. Initiator A calls begin
            local helloA, errA = peers.begin(stateA, "forge", pidB, "challenge-A", 1000)
            if not helloA or errA then error("begin failed: " .. tostring(errA)) end
            test.eq(helloA.protocol_revision, types.REVISION)
            test.eq(helloA.supervisor_incarnation, "inc-laptop")
            test.eq(helloA.challenge, "challenge-A")
            test.is_nil(helloA.response)
            -- Requests cannot be accepted from pending exchange
            test.is_nil(peers.current(stateA, "forge"))

            -- 2. Responder B receives A's hello
            local replyB, transB, errB = peers.receive(stateB, pidA, helloA, "challenge-B", 1050)
            if not replyB or errB then error("receive B failed: " .. tostring(errB)) end
            test.is_nil(transB) -- B is not active yet (waiting for response to challenge-B)
            test.eq(replyB.supervisor_incarnation, "inc-forge")
            test.eq(replyB.challenge, "challenge-B")
            test.eq(replyB.response, "challenge-A")
            test.is_nil(peers.current(stateB, "laptop"))

            -- 3. Initiator A receives B's reply (answers B's challenge and activates)
            local replyA2, transA, errA2 = peers.receive(stateA, pidB, replyB, nil, 1100)
            if not replyA2 or errA2 then error("receive A failed: " .. tostring(errA2)) end
            test.eq(replyA2.challenge, "challenge-A")
            test.eq(replyA2.response, "challenge-B")
            if not transA then error("expected transition on A") end
            test.is_nil(transA.old_peer)
            test.eq(transA.node_id, "forge")
            test.eq(transA.new_peer.node_id, "forge")
            test.eq(transA.new_peer.pid, pidB)
            test.eq(transA.new_peer.supervisor_incarnation, "inc-forge")
            test.eq(transA.new_peer.established_at, 1100)

            local currentA = peers.current(stateA, "forge")
            if not currentA then error("expected current peer on A") end
            test.eq(currentA.pid, pidB)
            test.is_nil(peers.pending(stateA, "forge"))

            -- 4. Responder B receives A's reply (activates, outbound hello is nil -> no pingpong)
            local replyB2, transB2, errB2 = peers.receive(stateB, pidA, replyA2, nil, 1150)
            test.is_nil(errB2)
            test.is_nil(replyB2) -- Responder need not answer again, preventing pingpong
            if not transB2 then error("expected transition on B") end
            test.is_nil(transB2.old_peer)
            test.eq(transB2.new_peer.node_id, "laptop")
            test.eq(transB2.new_peer.pid, pidA)
            test.eq(transB2.new_peer.supervisor_incarnation, "inc-laptop")

            local currentB = peers.current(stateB, "laptop")
            if not currentB then error("expected current peer on B") end
            test.eq(currentB.pid, pidA)
            test.is_nil(peers.pending(stateB, "laptop"))
        end)

        test.it("converges under simultaneous begin without pingpong", function()
            local stateA = peers.new(make_config("laptop", "inc-laptop", {"forge"}, 5000))
            local stateB = peers.new(make_config("forge", "inc-forge", {"laptop"}, 5000))
            if not stateA or not stateB then error("state init failed") end

            local pidA = pid("laptop", "pid-a-sim")
            local pidB = pid("forge", "pid-b-sim")

            -- Both begin simultaneously
            local helloA = peers.begin(stateA, "forge", pidB, "cA-sim", 1000)
            local helloB = peers.begin(stateB, "laptop", pidA, "cB-sim", 1005)
            if not helloA or not helloB then error("begin failed") end

            -- A receives B's initial hello: responds with cB answered, cA as challenge
            local replyA, transA, errA = peers.receive(stateA, pidB, helloB, nil, 1050)
            test.is_nil(errA)
            test.is_nil(transA)
            if not replyA then error("expected reply from A") end
            test.eq(replyA.challenge, "cA-sim")
            test.eq(replyA.response, "cB-sim")

            -- B receives A's initial hello: responds with cA answered, cB as challenge
            local replyB, transB, errB = peers.receive(stateB, pidA, helloA, nil, 1060)
            test.is_nil(errB)
            test.is_nil(transB)
            if not replyB then error("expected reply from B") end
            test.eq(replyB.challenge, "cB-sim")
            test.eq(replyB.response, "cA-sim")

            -- A receives B's reply: finishes exchange, no more outbound hello
            local replyA2, transA2, errA2 = peers.receive(stateA, pidB, replyB, nil, 1100)
            test.is_nil(errA2)
            test.is_nil(replyA2) -- No pingpong
            if not transA2 then error("expected transA2") end
            test.eq(transA2.new_peer.pid, pidB)
            test.is_true(peers.current(stateA, "forge") ~= nil)

            -- B receives A's reply: finishes exchange, no more outbound hello
            local replyB2, transB2, errB2 = peers.receive(stateB, pidA, replyA, nil, 1110)
            test.is_nil(errB2)
            test.is_nil(replyB2) -- No pingpong
            if not transB2 then error("expected transB2") end
            test.eq(transB2.new_peer.pid, pidA)
            test.is_true(peers.current(stateB, "laptop") ~= nil)
        end)

        test.it("replays duplicate initial hello without extending deadline", function()
            local stateB = peers.new(make_config("forge", "inc-forge", {"laptop"}, 5000))
            if not stateB then error("stateB init failed") end
            local pidA = pid("laptop", "pid-a-1")

            local initialHello: types.Hello = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = "inc-laptop",
                challenge = "challenge-A",
                response = nil,
            }

            local reply1, _, err1 = peers.receive(stateB, pidA, initialHello, "challenge-B", 1000)
            if not reply1 or err1 then error("first receive failed") end
            local p1 = peers.pending(stateB, "laptop")
            if not p1 then error("expected pending") end
            test.eq(p1.expires_at, 6000)

            -- Duplicate received at t=2000; must replay identical response and NOT extend deadline
            local reply2, trans2, err2 = peers.receive(stateB, pidA, initialHello, "new-nonce-ignored", 2000)
            test.is_nil(err2)
            test.is_nil(trans2)
            if not reply2 then error("expected replayed reply") end
            test.eq(reply2.challenge, reply1.challenge)
            test.eq(reply2.response, reply1.response)

            local p2 = peers.pending(stateB, "laptop")
            if not p2 then error("expected pending still present") end
            test.eq(p2.expires_at, 6000) -- Still 6000, not 7000!
        end)

        test.it("ignores duplicate accepted response with no new state", function()
            local stateA = peers.new(make_config("laptop", "inc-laptop", {"forge"}, 5000))
            local stateB = peers.new(make_config("forge", "inc-forge", {"laptop"}, 5000))
            if not stateA or not stateB then error("state init failed") end

            local pidA = pid("laptop", "pid-a-1")
            local pidB = pid("forge", "pid-b-1")

            local helloA = peers.begin(stateA, "forge", pidB, "cA", 1000)
            local replyB = peers.receive(stateB, pidA, helloA, "cB", 1010)
            local replyA, transA = peers.receive(stateA, pidB, replyB, nil, 1020)
            local _, transB = peers.receive(stateB, pidA, replyA, nil, 1030)
            if not transA or not transB then error("handshake setup failed") end

            -- Retransmit replyA to B after B already accepted it
            local outDup, transDup, errDup = peers.receive(stateB, pidA, replyA, nil, 1050)
            test.is_nil(outDup)
            test.is_nil(transDup)
            test.is_nil(errDup)

            -- Retransmit replyB to A after A already accepted it
            local outDupA, transDupA, errDupA = peers.receive(stateA, pidB, replyB, nil, 1060)
            if not outDupA or not replyA then error("initiator must replay its final answer") end
            test.eq(outDupA.challenge, replyA.challenge)
            test.eq(outDupA.response, replyA.response)
            test.is_nil(transDupA)
            test.is_nil(errDupA)
        end)

        test.it("rejects unsolicited response", function()
            local state = peers.new(make_config("laptop", "inc-laptop", {"forge"}, 5000))
            if not state then error("state init failed") end
            local pidB = pid("forge", "pid-b-1")

            local unsolicited: types.Hello = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = "inc-forge",
                challenge = "cB",
                response = "unexpected",
            }
            local out, trans, err = peers.receive(state, pidB, unsolicited, nil, 1000)
            test.is_nil(out)
            test.is_nil(trans)
            test.eq(err, "unsolicited or unexpected response")
        end)

        test.it("rejects wrong host, node, PID, incarnation, and challenge", function()
            local state = peers.new(make_config("laptop", "inc-laptop", {"forge"}, 5000))
            if not state then error("state init failed") end

            local validHello: types.Hello = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = "inc-forge",
                challenge = "cB",
                response = nil,
            }

            -- 1. Wrong host
            local wrongHostPID = "{forge@bee:workers|pid1}"
            local _, _, errHost = peers.receive(state, wrongHostPID, validHello, "nonce1", 1000)
            test.eq(errHost, "sender host is not supervisor host")

            -- 2. Wrong (unconfigured) node
            local wrongNodePID = "{rogue@" .. types.SUPERVISOR_HOST .. "|pid1}"
            local _, _, errNode = peers.receive(state, wrongNodePID, validHello, "nonce1", 1000)
            test.eq(errNode, "sender node is not configured")

            -- 3. Local node PID
            local localPID = "{laptop@" .. types.SUPERVISOR_HOST .. "|pid1}"
            local _, _, errLocal = peers.receive(state, localPID, validHello, "nonce1", 1000)
            test.eq(errLocal, "sender node cannot be local node")

            -- 4. Begin exchange to test response mismatches
            local pidB1 = pid("forge", "pid-b-1")
            local pidB2 = pid("forge", "pid-b-2")
            peers.begin(state, "forge", pidB1, "local-c1", 1000)

            -- Wrong PID for pending exchange
            local respWrongPID: types.Hello = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = "inc-forge",
                challenge = "cB",
                response = "local-c1",
            }
            local _, _, errPID = peers.receive(state, pidB2, respWrongPID, nil, 1010)
            test.eq(errPID, "sender PID does not match pending exchange PID")

            -- Wrong challenge response
            local respWrongChallenge: types.Hello = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = "inc-forge",
                challenge = "cB",
                response = "wrong-challenge",
            }
            local _, _, errChal = peers.receive(state, pidB1, respWrongChallenge, nil, 1010)
            test.eq(errChal, "response does not match pending challenge")

            -- Responder already recorded peer incarnation: mismatch rejected
            local stateResp = peers.new(make_config("laptop", "inc-laptop", {"forge"}, 5000))
            if not stateResp then error("stateResp failed") end
            peers.receive(stateResp, pidB1, validHello, "resp-c1", 1000)
            local respWrongInc: types.Hello = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = "inc-changed-midway",
                challenge = "cB",
                response = "resp-c1",
            }
            local _, _, errInc = peers.receive(stateResp, pidB1, respWrongInc, nil, 1010)
            test.eq(errInc, "supervisor_incarnation does not match pending exchange")
        end)

        test.it("expires pending exchange and rejects delayed response", function()
            local state = peers.new(make_config("laptop", "inc-laptop", {"forge"}, 1000))
            if not state then error("state init failed") end
            local pidB = pid("forge", "pid-b-1")

            peers.begin(state, "forge", pidB, "cA", 1000)
            test.is_true(peers.pending(state, "forge") ~= nil)

            -- At t=1500, not expired yet
            test.eq(peers.expire(state, 1500), 0)
            test.is_true(peers.pending(state, "forge") ~= nil)

            -- At t=2000, expired
            test.eq(peers.expire(state, 2000), 1)
            test.is_nil(peers.pending(state, "forge"))

            -- Delayed response arrives at t=2050 -> rejected as unexpected/unsolicited
            local delayedResp: types.Hello = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = "inc-forge",
                challenge = "cB",
                response = "cA",
            }
            local _, _, err = peers.receive(state, pidB, delayedResp, nil, 2050)
            test.eq(err, "unsolicited or unexpected response")
        end)

        test.it("replaces active peer only on completed handshake; stale hello cannot evict", function()
            local state = peers.new(make_config("laptop", "inc-laptop", {"forge"}, 5000))
            if not state then error("state init failed") end

            local pidB1 = pid("forge", "pid-b-1")
            local pidB2 = pid("forge", "pid-b-2")

            -- Establish first active peer with pidB1
            peers.begin(state, "forge", pidB1, "cA1", 1000)
            local replyB1: types.Hello = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = "inc-forge-1",
                challenge = "cB1",
                response = "cA1",
            }
            local _, trans1 = peers.receive(state, pidB1, replyB1, nil, 1010)
            if not trans1 then error("trans1 failed") end
            test.is_nil(trans1.old_peer)
            test.eq(trans1.new_peer.pid, pidB1)
            local cur1 = peers.current(state, "forge")
            if not cur1 then error("expected cur1") end
            test.eq(cur1.pid, pidB1)

            -- Stale hello from old/wrong PID or challenge cannot evict working peer
            local staleHello: types.Hello = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = "inc-forge-old",
                challenge = "cOld",
                response = "fake",
            }
            local _, _, errStale = peers.receive(state, pid("forge", "stale-pid"), staleHello, nil, 1020)
            test.eq(errStale, "unsolicited or unexpected response")
            local curStill = peers.current(state, "forge")
            if not curStill then error("expected curStill") end
            test.eq(curStill.pid, pidB1) -- Active peer intact!

            -- New incoming handshake from restarted peer pidB2
            local newInitialHello: types.Hello = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = "inc-forge-2",
                challenge = "cB2",
                response = nil,
            }
            local replyA2, transPending, errNew = peers.receive(state, pidB2, newInitialHello, "cA2", 1030)
            test.is_nil(errNew)
            test.is_nil(transPending) -- Candidate created in pending, NOT yet active!
            if not replyA2 then error("expected replyA2") end
            -- Working peer is still pidB1 while replacement is in flight!
            local curWorking = peers.current(state, "forge")
            if not curWorking then error("expected curWorking") end
            test.eq(curWorking.pid, pidB1)

            -- Final response completes replacement exchange
            local finalRespB2: types.Hello = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = "inc-forge-2",
                challenge = "cB2",
                response = "cA2",
            }
            local _, transFinal, errFinal = peers.receive(state, pidB2, finalRespB2, nil, 1040)
            test.is_nil(errFinal)
            if not transFinal then error("transFinal failed") end
            -- Owner receives old and new peer transition to invalidate old grants
            if not transFinal.old_peer then error("expected old_peer in replacement transition") end
            test.eq(transFinal.old_peer.pid, pidB1)
            test.eq(transFinal.old_peer.supervisor_incarnation, "inc-forge-1")
            test.eq(transFinal.new_peer.pid, pidB2)
            test.eq(transFinal.new_peer.supervisor_incarnation, "inc-forge-2")

            local curReplaced = peers.current(state, "forge")
            if not curReplaced then error("expected curReplaced") end
            test.eq(curReplaced.pid, pidB2)
        end)

        test.it("refuses allocation at capacity while preserving active peers", function()
            local state = peers.new(make_config("laptop", "inc-laptop", {"node1", "node2"}, 5000, 1, 1))
            if not state then error("state init failed") end

            local pid1 = pid("node1", "p1")
            local pid2 = pid("node2", "p2")

            -- Fill 1 pending slot
            local h1, err1 = peers.begin(state, "node1", pid1, "c1", 1000)
            test.is_true(h1 ~= nil)
            test.is_nil(err1)

            -- Attempting second pending exchange exceeds max_pending = 1
            local h2, err2 = peers.begin(state, "node2", pid2, "c2", 1010)
            test.is_nil(h2)
            test.eq(err2, "pending exchange capacity reached")

            -- Complete exchange for node1 to make it active (max_peers = 1)
            local reply1: types.Hello = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = "inc-1",
                challenge = "rem1",
                response = "c1",
            }
            peers.receive(state, pid1, reply1, nil, 1020)
            test.is_true(peers.current(state, "node1") ~= nil)

            -- Now attempt to establish node2 when max_peers = 1 is already reached
            peers.begin(state, "node2", pid2, "c2", 1030)
            local reply2: types.Hello = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = "inc-2",
                challenge = "rem2",
                response = "c2",
            }
            local _, trans2, errActiveCap = peers.receive(state, pid2, reply2, nil, 1040)
            test.is_nil(trans2)
            test.eq(errActiveCap, "active peer capacity reached")
            -- Existing active peer is preserved!
            test.is_true(peers.current(state, "node1") ~= nil)
            test.is_nil(peers.current(state, "node2"))
        end)

        test.it("returns copies preventing external mutation of internal state", function()
            local state = peers.new(make_config("laptop", "inc-laptop", {"forge"}, 5000))
            if not state then error("state init failed") end
            local pidB = pid("forge", "pid-b-1")

            local hello = peers.begin(state, "forge", pidB, "cA", 1000)
            if not hello then error("begin failed") end
            hello.challenge = "MUTATED"
            local p = peers.pending(state, "forge")
            if not p then error("expected pending") end
            test.eq(p.local_challenge, "cA")

            local reply: types.Hello = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = "inc-forge",
                challenge = "cB",
                response = "cA",
            }
            local _, trans = peers.receive(state, pidB, reply, nil, 1010)
            if not trans then error("receive failed") end
            trans.new_peer.pid = "MUTATED"
            local cur = peers.current(state, "forge")
            if not cur then error("expected cur") end
            test.eq(cur.pid, pidB)

            cur.supervisor_incarnation = "MUTATED"
            local cur2 = peers.current(state, "forge")
            if not cur2 then error("expected cur2") end
            test.eq(cur2.supervisor_incarnation, "inc-forge")
        end)

        test.it("rejects nonce reuse within live active and pending state", function()
            local state = peers.new(make_config("laptop", "inc-laptop", {"node1", "node2"}, 5000))
            if not state then error("state init failed") end

            local pid1 = pid("node1", "p1")
            local pid2 = pid("node2", "p2")

            peers.begin(state, "node1", pid1, "used-nonce", 1000)

            -- Reusing in begin rejected
            local _, errBegin = peers.begin(state, "node2", pid2, "used-nonce", 1010)
            test.eq(errBegin, "nonce already in use in live state")

            -- Reusing in receive rejected
            local incoming: types.Hello = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = "inc-2",
                challenge = "remote-c",
                response = nil,
            }
            local _, _, errRecv = peers.receive(state, pid2, incoming, "used-nonce", 1010)
            test.eq(errRecv, "nonce already in use in live state")
        end)

        test.it("forgets a connection's active and pending peer without losing configuration", function()
            local state = peers.new(make_config("laptop", "inc-laptop", {"forge"}, 5000, 1, 1))
            if not state then error("state init failed") end
            local remote = pid("forge", "first")
            assert(peers.begin(state, "forge", remote, "first-challenge", 1000))
            peers.forget(state, "forge")
            test.is_nil(peers.pending(state, "forge"))
            test.is_true(peers.is_configured(state, "forge"))
            assert(peers.begin(state, "forge", remote, "second-challenge", 1010))
            local _, transition = peers.receive(state, remote, {
                protocol_revision = types.REVISION, supervisor_incarnation = "inc-forge",
                challenge = "remote-challenge", response = "second-challenge",
            }, nil, 1020)
            if not transition then error("peer did not establish") end
            local old = peers.forget(state, "forge")
            if not old then error("missing retired peer") end
            test.eq(old.pid, remote)
            test.is_nil(peers.current(state, "forge"))
            test.is_nil(peers.forget(state, "forge"))
            assert(peers.begin(state, "forge", pid("forge", "replacement"), "third-challenge", 1030))
        end)

        test.it("rejects malformed hello payload before allocating state", function()
            local state = peers.new(make_config("laptop", "inc-laptop", {"forge"}, 5000))
            if not state then error("state init failed") end
            local pidB = pid("forge", "pid-b-1")

            local badPayload = {protocol_revision = "bad.version", challenge = "c"}
            local _, _, err = peers.receive(state, pidB, badPayload, "fresh", 1000)
            test.eq(err, "protocol_revision is not " .. types.REVISION)
            test.is_nil(peers.pending(state, "forge"))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
