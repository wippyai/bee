-- MIT. A Hive supervisor admits a local client node only while its host-owned
-- enrollment exists. Enrollment is bounded, typed, and owner-selected; the
-- departure path retires the node and its established or pending exchange.
local test = require("test")
local peers = require("peers")
local enrollment = require("enrollment")
local types = require("types")

local function pid(node: string, tag: string): string
    return "{" .. node .. "@" .. types.SUPERVISOR_HOST .. "|" .. tag .. "}"
end

local function make_config(node: string, nodes: {string}): peers.Config
    return {local_node = node, local_incarnation = "inc-" .. node, configured_nodes = nodes, ttl_ms = 5000}
end

local function define_tests()
    test.describe("Hive supervisor enrollment", function()
        test.it("admits a node enrolled after boot and refuses it after departure", function()
            local state = peers.new(make_config("laptop", {"forge"}))
            if not state then error("state init failed") end
            -- A fresh client node is not configured, so the exchange cannot start.
            test.is_false(peers.is_configured(state, "client-1"))
            local _, begin_err = peers.begin(state, "client-1", pid("client-1", "sp"), "c", 1000)
            test.eq(begin_err, "target node is not configured")

            -- The owner enrolls it; admission now accepts its exchange.
            local enrolled, enroll_err = peers.enroll(state, "client-1")
            test.is_true(enrolled)
            test.is_nil(enroll_err)
            test.is_true(peers.is_configured(state, "client-1"))
            local hello = peers.begin(state, "client-1", pid("client-1", "sp"), "c1", 1010)
            if not hello then error("enrolled node could not begin an exchange") end

            -- Departure retires the node and any exchange it established.
            local retired, retire_err = peers.retire(state, "client-1")
            test.is_true(retired)
            test.is_nil(retire_err)
            test.is_false(peers.is_configured(state, "client-1"))
            test.is_nil(peers.current(state, "client-1"))
            test.is_nil(peers.pending(state, "client-1"))
        end)

        test.it("bounds enrollment and keeps the boot set authoritative", function()
            local state = peers.new(make_config("laptop", {}))
            if not state then error("state init failed") end

            -- The local node is never an enrolled peer.
            local local_ok, local_err = peers.enroll(state, "laptop")
            test.is_false(local_ok)
            test.eq(local_err, "cannot enroll local node")

            -- Enrollment is idempotent-free: a duplicate join is a refusal.
            test.is_true(peers.enroll(state, "client-1"))
            local dup_ok, dup_err = peers.enroll(state, "client-1")
            test.is_false(dup_ok)
            test.eq(dup_err, "node is already enrolled")

            -- Retiring unknown state is a refusal, not a silent success.
            local unknown_ok, unknown_err = peers.retire(state, "client-2")
            test.is_false(unknown_ok)
            test.eq(unknown_err, "node is not enrolled")

            -- Identifiers obey the shared bounds.
            local bad_ok, bad_err = peers.enroll(state, "")
            test.is_false(bad_ok)
            test.eq(bad_err, "node is not an identifier")

            -- The cap is shared with the boot set, so it cannot be widened by
            -- enrolling past it.
            for index = 1, peers.CAP_MAX_NODES do peers.enroll(state, "client-cap-" .. tostring(index)) end
            local over_ok, over_err = peers.enroll(state, "client-over")
            test.is_false(over_ok)
            test.eq(over_err, "enrolled nodes exceed " .. tostring(peers.CAP_MAX_NODES))
        end)

        test.it("decodes a host-selected enrollment list through shared bounds", function()
            -- The host writes one typed entry; the supervisor only reads it.
            local decoded, decode_err = enrollment.decode({nodes = {"client-1", "client-2"}})
            test.is_nil(decode_err)
            if not decoded then error("expected a decoded enrollment") end
            test.eq(#decoded.nodes, 2)

            -- Shape is exact: unknown fields and non-dense lists are refused.
            local _, unknown = enrollment.decode({nodes = {"client-1"}, extra = true})
            test.eq(unknown, "unknown field extra")
            local _, sparse = enrollment.decode({nodes = {[2] = "client-1"}})
            test.is_true(sparse ~= nil)
            local _, not_list = enrollment.decode({nodes = "client-1"})
            test.is_true(not_list ~= nil)
            -- An empty list is a valid, closed enrollment.
            local empty, empty_err = enrollment.decode({nodes = {}})
            test.is_nil(empty_err)
            test.eq(#empty.nodes, 0)
        end)

        test.it("diffs desired, boot and configured sets without touching boot nodes", function()
            -- boot nodes stay configured no matter what the enrollment says, and
            -- only previously-enrolled nodes are retired.
            local boot = {forge = true}
            local configured = {forge = true, ["client-old"] = true}
            local to_enroll, to_retire = enrollment.diff({"client-new"}, boot, configured)
            test.eq(#to_enroll, 1)
            test.eq(to_enroll[1], "client-new")
            test.eq(#to_retire, 1)
            test.eq(to_retire[1], "client-old")

            -- A boot node named in the desired set is never re-enrolled or retired.
            local enroll2, retire2 = enrollment.diff({"forge"}, boot, configured)
            test.eq(#enroll2, 0)
            test.eq(#retire2, 1)
            test.eq(retire2[1], "client-old")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
