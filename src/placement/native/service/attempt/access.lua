-- MIT. Attempt lookup for placement operations: owner check, attempt load, named requests, recorded rows and runner authority.
local bounds = require("bounds")
local types = require("types")
local store = require("store")
local part_preparation = require("part_preparation")
type Reply = part_preparation.Reply
local fail = part_preparation.fail
local actor = part_preparation.actor
local M = {}
local function owned(attempt: types.Attempt): Reply?
    local caller = actor()
    if not caller then return fail("UNAUTHENTICATED", "no actor") end
    if caller ~= attempt.owner_id then return fail("FORBIDDEN", "the attempt belongs to another owner") end
    return nil
end
local function load(attempt_id: unknown): (types.Attempt?, Reply?, store.Row?)
    local id = bounds.id(attempt_id)
    if not id then return nil, fail("INVALID", "attempt_id is not an identifier") end
    local db, open_error = store.open()
    if not db then return nil, fail("STORAGE", open_error or "open placement store") end
    local attempt, read_error = store.attempt(db, id)
    local row = store.row(db, id)
    db:release()
    if read_error then return nil, fail("STORAGE", read_error) end
    if not attempt then return nil, fail("NOT_FOUND", "attempt is not recorded") end
    local denied = owned(attempt)
    if denied then return nil, denied end
    return attempt, nil, row
end
-- Requests that name only an attempt: {attempt_id}.
local function named(value: unknown): (string?, Reply?)
    local object = bounds.object(value)
    if not object then return nil, fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id"})
    if unknown_field then return nil, fail("INVALID", unknown_field) end
    local id = bounds.id(object.attempt_id)
    if not id then return nil, fail("INVALID", "attempt_id is not an identifier") end
    return id, nil
end
local function recorded_row(attempt_id: string): (store.Row?, string?)
    local db, open_error = store.open()
    if not db then return nil, open_error end
    local row, row_error = store.row(db, attempt_id)
    db:release()
    return row, row_error
end
local function runner_authority(attempt_id: string): (string?, string?)
    local db, open_error = store.open()
    if not db then return nil, open_error or "open placement store" end
    local token, token_error = store.runner_authority(db, attempt_id, nil)
    db:release()
    return token, token_error
end
M.owned = owned
M.load = load
M.named = named
M.recorded_row = recorded_row
M.runner_authority = runner_authority
return M
