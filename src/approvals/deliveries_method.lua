-- MIT. Delivery state for one request: the requester or a workspace manager
-- sees where its thread projection stands and may return an exhausted
-- delivery to the queue.
local security = require("security")
local bounds = require("bounds")
local service = require("service")
local outbox = require("outbox")
local function fail(code: string, message: string): service.Reply
    return {ok = false, error = {code = code, message = message}, value = nil, replayed = false}
end
local function handle(request: unknown): service.Reply
    local object = bounds.object(request) or {}
    local unknown_field = bounds.fields(object, {"approval_id", "redeliver"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local read = service.read({approval_id = object.approval_id})
    if not read.ok then return read end
    local view = read.value :: {[string]: unknown}
    local approval_id = tostring(view.approval_id)
    local db, open_error = service.open()
    if not db then return fail("STORAGE", open_error or "open approval store") end
    if object.redeliver ~= nil then
        local event_id = bounds.id(object.redeliver)
        if not event_id then
            db:release()
            return fail("INVALID", "redeliver is not an event identifier")
        end
        if not security.can(service.MANAGE, tostring(view.workspace_id)) then
            db:release()
            return fail("DENIED", "only a workspace manager returns a delivery to the queue")
        end
        if event_id:sub(1, #approval_id + 1) ~= approval_id .. ":" then
            db:release()
            return fail("INVALID", "event does not belong to this request")
        end
        local _, redeliver_error = outbox.redeliver(db, event_id)
        if redeliver_error then
            db:release()
            local code, message = redeliver_error:match("^([A-Z_]+): (.*)$")
            return fail(code or "STORAGE", message or redeliver_error)
        end
    end
    local deliveries, list_error = outbox.deliveries(db, approval_id)
    db:release()
    if not deliveries then return fail("STORAGE", list_error or "read deliveries") end
    return {ok = true, error = nil, value = {approval_id = approval_id, deliveries = deliveries}, replayed = false}
end
return {handle = handle}
