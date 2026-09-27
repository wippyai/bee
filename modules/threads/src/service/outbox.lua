-- MIT. Validated coordination for the Threads forwarding outbox.
local sql = require("sql")
local json = require("json")
local bounds = require("bounds")
local transaction = require("transaction")
local repository = require("repository")
local M = {}
M.BATCH = 16
type Result = transaction.Result
local function failure(code: string, detail: string): Result
    return transaction.failure(code, detail)
end
local function storage(detail: string): Result
    return transaction.storage_failure(detail)
end
local function claim_request(request: unknown): (string?, integer?, string?)
    local object = bounds.object(request)
    if not object then return nil, nil, "request must be an object" end
    if bounds.fields(object, {"holder", "limit"}) then return nil, nil, "claim takes holder and limit only" end
    local holder = bounds.id(object.holder)
    if not holder then return nil, nil, "holder is not an identifier" end
    local limit = object.limit == nil and M.BATCH or bounds.integer(object.limit)
    if not limit or limit < 1 or limit > M.BATCH then return nil, nil, "limit is bounded by the outbox batch" end
    return holder, limit, nil
end
local function settle_request(request: unknown): (string?, boolean?, string?, string?, string?)
    local object = bounds.object(request)
    if not object then return nil, nil, nil, nil, "request must be an object" end
    local extra = bounds.fields(object, {"outbox_id", "delivered", "receipt", "error"})
    if extra then return nil, nil, nil, nil, extra end
    local outbox_id = bounds.id(object.outbox_id)
    if not outbox_id or type(object.delivered) ~= "boolean" then return nil, nil, nil, nil, "outbox_id and delivered are required" end
    local receipt_json: string? = nil
    if object.receipt ~= nil then
        receipt_json = json.encode(object.receipt)
        if not receipt_json then return nil, nil, nil, nil, "receipt is not encodable" end
    end
    local error_text: string? = nil
    if object.error ~= nil then
        error_text = bounds.text(object.error)
        if error_text == nil then return nil, nil, nil, nil, "error must be text" end
    end
    return outbox_id, object.delivered, receipt_json, error_text, nil
end
function M.claim_pump_due(db: sql.DB, request: unknown): Result
    local holder, limit, invalid = claim_request(request)
    if not holder or not limit then return failure("INVALID_ARGUMENT", invalid or "invalid claim") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local deliveries, err = repository.claim_pump_due(tx, holder :: string, limit :: integer)
        if err then return err end
        return transaction.success({deliveries = deliveries or {}}, false)
    end)
end
function M.settle_pump(db: sql.DB, request: unknown): Result
    local outbox_id, delivered, receipt_json, error_text, invalid = settle_request(request)
    if not outbox_id or delivered == nil then return failure("INVALID_ARGUMENT", invalid or "invalid settlement") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local err = repository.settle_pump(tx, outbox_id :: string, delivered :: boolean, receipt_json, error_text)
        if err then return err end
        return transaction.success({outbox_id = outbox_id, delivered = delivered}, false)
    end)
end
function M.claim_deliveries(db: sql.DB, actor: string, request: unknown): Result
    local holder, limit, invalid = claim_request(request)
    if not holder or not limit then return failure("INVALID_ARGUMENT", invalid or "invalid claim") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local claimed, err = repository.claim(tx, actor, holder :: string, limit :: integer)
        if err then return err end
        local deliveries: {unknown} = {}
        for _, row in ipairs(claimed or {}) do
            local delivery, decode_error = repository.delivery(row)
            if not delivery then return storage("decode claimed forwarding delivery: " .. tostring(decode_error)) end
            deliveries[#deliveries + 1] = delivery
        end
        return transaction.success({deliveries = deliveries}, false)
    end)
end
function M.settle_delivery(db: sql.DB, actor: string, request: unknown): Result
    local outbox_id, delivered, receipt_json, error_text, invalid = settle_request(request)
    if not outbox_id or delivered == nil then return failure("INVALID_ARGUMENT", invalid or "invalid settlement") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local err = repository.settle(tx, actor, outbox_id :: string, delivered :: boolean, receipt_json, error_text)
        if err then return err end
        return transaction.success({outbox_id = outbox_id, delivered = delivered}, false)
    end)
end
return M
