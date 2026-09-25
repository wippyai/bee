-- MIT. The forwarding pump: a supervised background service that leases the
-- node's due outbox rows across every sender, delivers each through the
-- destination's Hive admission, and settles only on the destination's own
-- reply. Its transport is host-selected and injected; a composition with no
-- sender leaves rows queued rather than inventing one, and this module never
-- depends on the Hive component. Delivery is at least once — the destination
-- deduplicates on the sender's stable idempotency key — so an unknown
-- outcome settles nothing and the row's lease simply lapses.
local process = require("process")
local channel = require("channel")
local time = require("time")
local logger = require("logger")
local database = require("database")
local resources = require("resources")
local outbox = require("outbox")
local pump = require("pump")
local sender = require("sender")

local function settle(outbox_id: string, delivered: boolean, receipt: unknown, error_text: string?): (string?, string?)
    local resource, resource_error = resources.database()
    if not resource then return nil, resource_error or "thread database reference is not linked" end
    local db, open_error = database.open(resource)
    if not db then return nil, open_error or "thread database unavailable" end
    local request: {[string]: unknown} = {outbox_id = outbox_id, delivered = delivered}
    if delivered then request.receipt = receipt else request.error = error_text or "delivery failed" end
    local result = outbox.settle_pump(db, "bee.threads.pump", request)
    db:release()
    if not result.ok then return nil, result.message or "settle refused" end
    return outbox_id, nil
end

local function main()
    local lifecycle = assert(process.events())
    local function once()
        local resource, resource_error = resources.database()
        if not resource then logger:warn("Forwarding pump has no store", {cause = tostring(resource_error)}); return end
        local db, open_error = database.open(resource)
        if not db then logger:warn("Forwarding pump cannot open its store", {cause = tostring(open_error)}); return end
        local claimed = outbox.claim_pump_due(db, "bee.threads.pump", {holder = "bee.threads.pump", limit = pump.BATCH})
        db:release()
        if not claimed.ok then logger:warn("Forwarding pump claim was refused", {cause = tostring(claimed.message)}); return end
        local value = type(claimed.value) == "table" and (claimed.value :: {[string]: unknown}) or {}
        local deliveries = value.deliveries
        if type(deliveries) ~= "table" then return end
        for _, raw_delivery in ipairs(deliveries :: {unknown}) do
            local delivery = type(raw_delivery) == "table" and (raw_delivery :: {[string]: unknown}) or {}
            local outbox_id = tostring(delivery.outbox_id or "")
            local input: {[string]: unknown} = {}
            for name, item in pairs(delivery) do
                if name ~= "outbox_id" then input[name] = item end
            end
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
    while true do
        local ok, err = pcall(once)
        if not ok then logger:error("Forwarding pump round failed", {cause = tostring(err)}) end
        local tick = time.after("1s")
        local selected = channel.select({lifecycle:case_receive(), tick:case_receive()})
        if not selected.ok or selected.channel == lifecycle then break end
    end
end

return {main = main}
