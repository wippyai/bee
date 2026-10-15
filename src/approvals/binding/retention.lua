-- MIT. Retention for the approvals authority.
local sql = require("sql")
local security = require("security")
local bounds = require("bounds")
local store = require("store")
local lifecycle = require("lifecycle")
local part_model = require("part_model")
local part_projections = require("part_projections")
local part_records = require("part_records")
local part_values = require("part_values")
local M = {}
type Result = part_model.Result
type Object = part_model.Object
local failure = part_values.failure
local storage = part_values.storage
local success = part_values.success
local stamp = part_values.stamp
local decode_row = part_records.decode_row
local expire_if_due = part_projections.expire_if_due
-- reconcile: the owner expires every pending request past its deadline and
-- forgets requests whose lifetime ended a retention window ago and whose
-- deliveries are all acknowledged, together with their history, inbox
-- changes and deliveries. An idempotency key older than that horizon can
-- create a fresh request; that is the advertised dedupe horizon.
local function op_reconcile(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    if not security.can(part_model.OWN, "*") then return failure("DENIED", "caller is not the approval owner") end
    local due, due_error = store.due(tx, now, part_model.EXPIRE_BOUND)
    if due_error or not due then return storage("read due requests") end
    local expired = 0
    for _, raw in ipairs(due) do
        local row, decode_error = decode_row(raw, tx)
        if not row then return storage("decode due approval: " .. tostring(decode_error)) end
        local settled, settle_error, expired_now = expire_if_due(tx, row, now)
        if not settled then return storage(settle_error or "expire request") end
        if expired_now then expired = expired + 1 end
    end
    local expired_effects, effect_error = lifecycle.expire_effects(tx, now, stamp(now))
    if expired_effects == nil then return storage(effect_error or "expire effect admission") end
    local horizon = now - part_model.RETENTION_MS
    local stale, stale_error = store.retained(tx, horizon, now, part_model.EXPIRE_BOUND)
    if stale_error or not stale then return storage("read retained requests") end
    local forgotten = 0
    for _, raw in ipairs(stale) do
        local retained = bounds.object(raw)
        local approval_id = retained and bounds.id(retained.approval_id)
        if not approval_id then return storage("retained approval identity is corrupt") end
        local delete_error = store.forget(tx, approval_id)
        if delete_error then return storage("forget retained request") end
        forgotten = forgotten + 1
    end
    local grant_error = store.forget_grants(tx,horizon)
    if grant_error then return storage(grant_error) end
    return success({expired = expired, expired_effects = expired_effects, forgotten = forgotten, more = #due == part_model.EXPIRE_BOUND or expired_effects == part_model.EXPIRE_BOUND}, expired == 0 and forgotten == 0 and expired_effects == 0)
end
M.op_reconcile = op_reconcile
return M
