-- SPDX-License-Identifier: MIT
local logger = require("logger")
local bounds = require("bounds")
local database = require("database")
local outbox = require("outbox")
local pump = require("pump")
local sender = require("sender")

local function settle(outbox_id: string, delivered: boolean, receipt: unknown, error_text: string?): (string?, string?)
    local db, open_error = database.open()
    if not db then return nil, open_error or "thread database unavailable" end
    local request: {[string]: unknown} = {outbox_id = outbox_id, delivered = delivered}
    if delivered then request.receipt = receipt else request.error = error_text or "delivery failed" end
    local result = outbox.settle_pump(db, request)
    db:release()
    if not result.ok then return nil, result.message or "settle refused" end
    return outbox_id, nil
end

local function round()
    local db, open_error = database.open()
    if not db then error(open_error or "thread database unavailable") end
    local claimed = outbox.claim_pump_due(db, {holder = "bee.threads.pump", limit = pump.BATCH})
    db:release()
    local deliveries, decode_error = pump.claimed(claimed)
    if not deliveries then error(decode_error or "malformed forwarding claim") end
    for _, delivery in ipairs(deliveries) do
        local outbox_id = delivery.outbox_id
        local input = bounds.object(delivery)
        if not input then error("non-object forwarding delivery") end
        input.outbox_id = nil
        local reply, transport_error = sender.deliver(input, {timeout = "25s"})
        local outcome = pump.outcome(reply, transport_error)
        if outcome.decision == "delivered" then
            local _, settle_error = settle(outbox_id, true, outcome.receipt, nil)
            if settle_error then logger:warn("Forwarded send was not acknowledged", {outbox_id = outbox_id, cause = tostring(settle_error)}) end
        elseif outcome.decision == "failed" then
            local _, settle_error = settle(outbox_id, false, nil, outcome.message)
            if settle_error then logger:warn("Forwarded send failure was not recorded", {outbox_id = outbox_id, cause = tostring(settle_error)}) end
        end
    end

end
return {round = round}
