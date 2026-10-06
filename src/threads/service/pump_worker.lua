-- MIT. The forwarding pump: a supervised background service that leases the
-- node's due outbox rows across every sender, delivers each through the
-- destination's Hive admission, and settles only on the destination's own
-- reply, sent through the node's Hive sender. Delivery is at least once — the destination
-- deduplicates on the sender's stable idempotency key — so an unknown
-- outcome settles nothing and the row's lease simply lapses.
local logger = require("logger")
local worker = require("worker")
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

local function main()
    local function once()
        local db, open_error = database.open()
        if not db then logger:warn("Forwarding pump cannot open its store", {cause = tostring(open_error)}); return end
        local claimed = outbox.claim_pump_due(db, {holder = "bee.threads.pump", limit = pump.BATCH})
        db:release()
        local deliveries, decode_error = pump.claimed(claimed)
        if not deliveries then logger:error("Forwarding pump received a malformed claim", {cause = tostring(decode_error)}); return end
        for _, delivery in ipairs(deliveries) do
            local outbox_id = delivery.outbox_id
            local input = bounds.object(delivery)
            if not input then logger:error("Forwarding pump decoded a non-object delivery", {outbox_id = outbox_id}); return end
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
    -- A failed round is reported and the next round runs on the next tick.
    worker.run({every = "1s", pass = function(): boolean
        local ok, err = pcall(once)
        if not ok then logger:error("Forwarding pump round failed", {cause = tostring(err)}) end
        return true
    end})
end

return {main = main}
