-- MIT. A Hive peer that restarts announces itself from a new supervisor. Its
-- authenticated initial hello replaces any exchange this node still holds
-- toward the peer's previous supervisor, so the session is established with
-- the peer's current supervisor instead of waiting on a process that is gone.
local test = require("test")
local peers = require("peers")
local types = require("types")

local function pid(node: string, tag: string): string
    return "{" .. node .. "@" .. types.SUPERVISOR_HOST .. "|" .. tag .. "}"
end

local function hello(incarnation: string, challenge: string, response: string?): types.Hello
    return {protocol_revision = types.REVISION, supervisor_incarnation = incarnation, challenge = challenge, response = response}
end

local function node(): peers.State
    local state = peers.new({local_node = "hive-a", local_incarnation = "inc-a", configured_nodes = {"hive-b"}, ttl_ms = 10000})
    if not state then error("state init failed") end
    return state
end

-- completes the exchange the fresh supervisor started and returns the peer.
local function complete(state: peers.State, fresh: string, answer: types.Hello?, now: integer): peers.Peer?
    if not answer then error("the fresh supervisor's hello was refused") end
    test.eq(answer.response, "b-new-challenge")
    local _, transition, err = peers.receive(state, fresh, hello("inc-b2", "b-new-challenge", answer.challenge), nil, now)
    test.is_nil(err)
    if not transition then error("the exchange with the fresh supervisor did not establish") end
    return peers.current(state, "hive-b")
end

local function define_tests()
    test.describe("Hive peer restart", function()
        test.it("replaces an outbound exchange toward the previous supervisor", function()
            local state = node()
            local stale, fresh = pid("hive-b", "0x0000c"), pid("hive-b", "0x0000d")
            test.not_nil(peers.begin(state, "hive-b", stale, "a-stale-challenge", 1000))
            local answer, _, err = peers.receive(state, fresh, hello("inc-b2", "b-new-challenge"), "a-new-challenge", 1500)
            test.is_nil(err)
            local peer = complete(state, fresh, answer, 1600)
            if not peer then error("no established peer") end
            test.eq(peer.pid, fresh)
            test.eq(peer.supervisor_incarnation, "inc-b2")
        end)

        test.it("replaces an answered exchange with the previous supervisor", function()
            local state = node()
            local stale, fresh = pid("hive-b", "0x0000c"), pid("hive-b", "0x0000d")
            test.not_nil(peers.receive(state, stale, hello("inc-b1", "b-old-challenge"), "a-old-challenge", 1000))
            local answer, _, err = peers.receive(state, fresh, hello("inc-b2", "b-new-challenge"), "a-new-challenge", 1500)
            test.is_nil(err)
            local peer = complete(state, fresh, answer, 1600)
            if not peer then error("no established peer") end
            test.eq(peer.pid, fresh)
        end)

        test.it("replaces an answered exchange when the restarted supervisor reuses its process id", function()
            local state = node()
            local same = pid("hive-b", "0x0000c")
            test.not_nil(peers.receive(state, same, hello("inc-b1", "b-old-challenge"), "a-old-challenge", 1000))
            local answer, _, err = peers.receive(state, same, hello("inc-b2", "b-new-challenge"), "a-new-challenge", 1500)
            test.is_nil(err)
            local peer = complete(state, same, answer, 1600)
            if not peer then error("no established peer") end
            test.eq(peer.supervisor_incarnation, "inc-b2")
        end)

        test.it("keeps an exchange with the current supervisor against its own stale response", function()
            local state = node()
            local stale, fresh = pid("hive-b", "0x0000c"), pid("hive-b", "0x0000d")
            test.not_nil(peers.begin(state, "hive-b", fresh, "a-challenge", 1000))
            local _, _, err = peers.receive(state, stale, hello("inc-b1", "b-old", "a-challenge"), nil, 1100)
            test.eq(err, "sender PID does not match pending exchange PID")
            test.eq((peers.pending(state, "hive-b") :: peers.PendingInfo).pid, fresh)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
