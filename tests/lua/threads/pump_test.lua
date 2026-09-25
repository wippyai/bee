-- MIT. The forwarding pump's pure decisions: how one delivery attempt's
-- reply maps onto the durable outbox row behind it. A committed destination
-- reply settles the row; a final refusal fails it; anything that leaves the
-- outcome unknown settles nothing so the delivery repeats under the same key.
local test = require("test")
local pump = require("pump")

local function define_tests()
    test.describe("Forwarding pump decisions", function()
        test.it("settles a delivered row on the destination's committed reply", function()
            local outcome = pump.outcome({ok = true, value = {record_id = "record-1"}}, nil)
            test.eq(outcome.decision, "delivered")
            test.eq((outcome.receipt :: {[string]: unknown}).record_id, "record-1")
        end)
        test.it("fails a row only on a destination refusal that is final", function()
            for _, code in ipairs({"DENIED", "NOT_FOUND", "CONFLICT", "INVALID_ARGUMENT", "INVALID_STATE"}) do
                local outcome = pump.outcome({ok = false, error = {code = code, message = "refused"}}, nil)
                test.eq(outcome.decision, "failed")
                test.eq(outcome.code, code)
            end
        end)
        test.it("leaves an unknown outcome unsettled so the delivery repeats", function()
            -- An ambiguous internal or busy refusal, a malformed reply and any
            -- transport error must never settle a row.
            for _, code in ipairs({"INTERNAL", "BUSY", "UNAVAILABLE", "UNCERTAIN", "DEADLINE_EXCEEDED"}) do
                test.eq(pump.outcome({ok = false, error = {code = code, message = "later"}}, nil).decision, "unknown")
            end
            test.eq(pump.outcome({ok = true, value = {}}, "send failed").decision, "unknown")
            test.eq(pump.outcome({ok = false}, nil).decision, "unknown")
            test.eq(pump.outcome(nil, nil).decision, "unknown")
        end)
        test.it("bounds a pump claim and its settle request", function()
            local claim = assert(pump.claim_request({holder = "pump-1"}))
            test.eq(claim.limit, pump.BATCH)
            local page = assert(pump.claim_request({holder = "pump-1", limit = 4}))
            test.eq(page.limit, 4)
            test.is_nil(pump.claim_request({holder = "pump-1", limit = 0}))
            test.is_nil(pump.claim_request({limit = 4}))
            test.is_nil(pump.claim_request({holder = "pump-1", extra = true}))
            local settled = assert(pump.settle_request({outbox_id = "row-1", delivered = true, receipt = {record_id = "r"}}))
            test.eq(settled.delivered, true)
            test.is_nil(pump.settle_request({outbox_id = "row-1", delivered = false, receipt = {r = 1}}))
            test.is_nil(pump.settle_request({outbox_id = "row-1", delivered = true, error = "x"}))
            test.is_nil(pump.settle_request({delivered = true}))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
