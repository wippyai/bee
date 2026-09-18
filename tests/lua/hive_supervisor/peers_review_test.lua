-- MIT. Independent protocol recovery regressions.
local test = require("test")
local peers = require("peers")
local types = require("types")
type State = peers.State
local function state(node: string, other: string): State
    local value, err = peers.new({local_node = node, local_incarnation = node .. "-inc", configured_nodes = {other}, ttl_ms = 1000})
    if not value then error(tostring(err)) end
    return value
end
local apid = "{alpha@bee.hive:supervisor_host|a1}"
local bpid = "{beta@bee.hive:supervisor_host|b1}"
local function define_tests()
    test.describe("Peer recovery review", function()
        test.it("bounds handshake duration and rejects a backwards clock", function()
            local bad = peers.new({local_node = "alpha", local_incarnation = "a-inc", configured_nodes = {"beta"}, ttl_ms = 60001})
            test.is_nil(bad)
            local a = state("alpha", "beta")
            local initial = peers.begin(a, "beta", bpid, "a-challenge", 10)
            if not initial then error("begin failed") end
            local expired, err = peers.expire(a, 9)
            test.eq(expired, 0)
            test.eq(err, "nowMS moved backwards")
            local pending = peers.pending(a, "beta")
            if not pending then error("backwards clock removed pending exchange") end
            test.eq(pending.expires_at, 1010)
        end)
        test.it("refuses a reflected local challenge", function()
            local a = state("alpha", "beta")
            peers.begin(a, "beta", bpid, "a-challenge", 10)
            local _, transition, err = peers.receive(a, bpid, {
                protocol_revision = types.REVISION, supervisor_incarnation = "b-inc",
                challenge = "a-challenge", response = "a-challenge",
            }, nil, 11)
            test.is_nil(transition)
            test.eq(err, "peer challenge reflects local challenge")
            test.is_nil(peers.current(a, "beta"))
        end)
        test.it("replays the final answer when its first delivery is lost", function()
            local a, b = state("alpha", "beta"), state("beta", "alpha")
            local initial = peers.begin(a, "beta", bpid, "a-challenge", 1)
            if not initial then error("begin failed") end
            local response = peers.receive(b, apid, initial, "b-challenge", 2)
            if not response then error("responder failed") end
            local lost_final, established = peers.receive(a, bpid, response, nil, 3)
            if not lost_final or not established then error("initiator did not establish") end
            test.is_nil(peers.current(b, "alpha"))
            -- Responder retries the same response; the original final is lost.
            local replay, changed, err = peers.receive(a, bpid, response, nil, 4)
            if not replay then error("final response was not replayed: " .. tostring(err)) end
            test.is_nil(changed)
            local _, accepted, accept_err = peers.receive(b, apid, replay, nil, 5)
            if not accepted then error("responder could not recover: " .. tostring(accept_err)) end
            test.eq(accepted.new_peer.pid, apid)
        end)
        test.it("does not allocate another candidate for a completed initial hello", function()
            local a, b = state("alpha", "beta"), state("beta", "alpha")
            local initial = peers.begin(a, "beta", bpid, "a-challenge", 1)
            if not initial then error("begin failed") end
            local response = peers.receive(b, apid, initial, "b-challenge", 2)
            if not response then error("response failed") end
            local final = peers.receive(a, bpid, response, nil, 3)
            if not final then error("final failed") end
            local _, accepted = peers.receive(b, apid, final, nil, 4)
            if not accepted then error("establishment failed") end
            local replay, transition, err = peers.receive(b, apid, initial, nil, 5)
            if not replay then error("completed initial was not replayed: " .. tostring(err)) end
            test.eq(replay.challenge, response.challenge)
            test.is_nil(transition)
            test.is_nil(peers.pending(b, "alpha"))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
