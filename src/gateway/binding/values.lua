-- MIT. Values for the gateway authority.
local sql = require("sql")
local hash = require("hash")
local time = require("time")
local crypto = require("crypto")
local base64 = require("base64")
local bounds = require("bounds")
local canonical = require("canonical")
local node_database = require("node_database")
local registry = require("registry")
local part_model = require("part_model")
local identity = require("identity")
local M = {}
type Reply = part_model.Reply
local FORMAT = "2006-01-02T15:04:05.000Z07:00"
local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}}
end
local function succeed(value: unknown): Reply
    return {ok = true, value = value}
end
local function now_ms(): integer
    return math.floor(time.now():unix_nano() / 1000000)
end
local function stamp(ms: integer): string
    return time.unix(math.floor(ms / 1000), (ms % 1000) * 1000000):utc():format(FORMAT)
end
local actor = identity.actor

local function text(value: unknown): string?
    if type(value) ~= "string" then return nil end
    return value
end
local function integer(value: unknown): integer?
    return bounds.integer(value)
end
local function reference(id: string, field: string, what: string): (string?, string?)
    local entry, err = registry.get(id)
    if err or not entry then return nil, what .. " reference is not in the registry" end
    local data = entry.data
    if type(data) ~= "table" then return nil, what .. " reference has no data" end
    local target = (data)[field]
    if type(target) ~= "string" or target == "" then return nil, what .. " reference is not linked" end
    return target, nil
end
local function open(): (sql.DB?, Reply?)
    local db, open_error = node_database.open()
    if not db then return nil, fail("STORAGE", open_error or "open gateway store") end
    return db, nil
end
local function digest_of(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest request" end
    return sum, nil
end
local function token_hash(token: string): (string?, string?)
    local sum, hash_error = hash.sha256(token)
    if hash_error or not sum then return nil, "digest token" end
    return sum, nil
end
local function random_text(): (string?, string?)
    local raw, random_error = crypto.random.bytes(part_model.TOKEN_BYTES)
    if random_error or not raw then return nil, "generate random bytes" end
    local encoded, encode_error = base64.encode(raw)
    if encode_error or not encoded then return nil, "encode random bytes" end
    return encoded, nil
end
-- SQLite stores absent optional text as NULL or an empty string.
local function optional_text(value: unknown, limit: integer): (string?, boolean)
    if value == nil then return nil, true end
    local declared = bounds.text(value, limit)
    if not declared then return nil, false end
    if declared == "" then return nil, true end
    return declared, true
end
local function optional_timestamp(value: unknown): (string?, boolean)
    local declared, valid = optional_text(value, 64)
    if not valid or not declared then return declared, valid end
    local parsed, parse_error = time.parse(FORMAT, declared)
    if parse_error or not parsed then return nil, false end
    return declared, true
end
M.FORMAT = FORMAT
M.actor = actor
M.digest_of = digest_of
M.fail = fail
M.integer = integer
M.now_ms = now_ms
M.open = open
M.optional_text = optional_text
M.optional_timestamp = optional_timestamp
M.random_text = random_text
M.reference = reference
M.stamp = stamp
M.succeed = succeed
M.token_hash = token_hash
return M
