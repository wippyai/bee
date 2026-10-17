-- MIT. Measurements of host executable files: a content digest or a probe
-- output, each recorded with the identity of the file version it was taken
-- from and reused only while a fresh stat reports the same identity.
--
-- An identity is the device, inode, size, status change time and
-- modification time the OS reports. A write, rename or chmod changes the
-- inode or the status change time, so equal complete identities name the
-- same file version without reading it. Windows reports only the
-- modification time and a virtual filesystem reports none: such an
-- identity is incomplete and pins no content digest. Device, inode and
-- times are decimal text, since nanosecond times exceed what a JSON number
-- carries exactly.
local sql = require("sql")
local json = require("json")
local time = require("time")
local bounds = require("bounds")
local node_database = require("node_database")
local types = require("types")
local M = {}
-- A filesystem stamps changes with a coarse clock: a write within the same
-- tick as the stamp a measurement saw leaves the identity unchanged. A
-- measurement is recorded only for a file whose last change precedes the
-- measurement by more than the coarsest stamp granularity in use (two
-- seconds), so any later write carries a later stamp.
M.GRANULE_NS = 2000000000

type Identity = {dev: string?, ino: string?, size: integer, ctime_ns: string?, mtime_ns: string}
type Info = {size: number, dev: unknown, ino: unknown, ctime_ns: unknown, mtime_ns: unknown}

local function whole(value: unknown): integer?
    if type(value) ~= "number" then return nil end
    return math.tointeger(value)
end

local function decimal(value: unknown): string?
    if type(value) == "string" then return value:match("^%d+$") and value or nil end
    local number = whole(value)
    if number == nil or number < 0 then return nil end
    return string.format("%d", number)
end

-- observed: the identity a stat result reports, or nil when it reports no
-- modification time.
function M.observed(info: Info): Identity?
    local size, mtime_ns = bounds.integer(info.size), decimal(info.mtime_ns)
    if size == nil or size < 0 or mtime_ns == nil then return nil end
    return {dev = decimal(info.dev), ino = decimal(info.ino), size = size, ctime_ns = decimal(info.ctime_ns), mtime_ns = mtime_ns}
end

-- settled: the observed identity of a file whose last change precedes
-- started_ns by more than GRANULE_NS, or nil.
function M.settled(info: Info, started_ns: integer): Identity?
    local identity = M.observed(info)
    if not identity then return nil end
    local changed = whole(info.ctime_ns) or whole(info.mtime_ns)
    if changed == nil or changed >= started_ns - M.GRANULE_NS then return nil end
    return identity
end

-- pinned: the identity as a plan carries it, when it is complete.
function M.pinned(identity: Identity?): types.ExecutableIdentity?
    if not identity then return nil end
    local dev, ino, ctime_ns = identity.dev, identity.ino, identity.ctime_ns
    if not dev or not ino or not ctime_ns then return nil end
    return {dev = dev, ino = ino, size = identity.size, ctime_ns = ctime_ns, mtime_ns = identity.mtime_ns}
end

function M.same(left: Identity?, right: Identity?): boolean
    if left == nil or right == nil then return false end
    return left.dev == right.dev and left.ino == right.ino and left.size == right.size
        and left.ctime_ns == right.ctime_ns and left.mtime_ns == right.mtime_ns
end

local function text(value: unknown): string?
    if type(value) == "string" then return value end
    return nil
end

-- find: the measurement recorded under key for this file version.
function M.find(db: sql.DB, key: string, identity: Identity): unknown
    local rows = db:query("SELECT dev, ino, size, ctime_ns, mtime_ns, measurement FROM bee_placement_executable_measurements WHERE key_digest = ?", {key})
    local row = rows and rows[1]
    if not row then return nil end
    local size, mtime_ns = bounds.integer(row.size), text(row.mtime_ns)
    if size == nil or mtime_ns == nil or type(row.measurement) ~= "string" then return nil end
    local recorded: Identity = {dev = text(row.dev), ino = text(row.ino), size = size, ctime_ns = text(row.ctime_ns), mtime_ns = mtime_ns}
    if not M.same(recorded, identity) then return nil end
    local decoded, decode_error = json.decode(row.measurement)
    if decode_error then return nil end
    return decoded
end

-- record: the measurement of this file version under key, replacing the
-- measurement of an earlier version.
function M.record(db: sql.DB, key: string, path: string, identity: Identity, measurement: unknown): string?
    local encoded, encode_error = json.encode(measurement)
    if not encoded then return "measurement cannot be encoded: " .. tostring(encode_error) end
    local _, err = db:execute("INSERT INTO bee_placement_executable_measurements (key_digest, path, dev, ino, size, ctime_ns, mtime_ns, measurement, measured_at) " ..
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(key_digest) DO UPDATE SET path = excluded.path, dev = excluded.dev, ino = excluded.ino, " ..
        "size = excluded.size, ctime_ns = excluded.ctime_ns, mtime_ns = excluded.mtime_ns, measurement = excluded.measurement, measured_at = excluded.measured_at",
        {key, path, identity.dev or sql.NULL, identity.ino or sql.NULL, identity.size, identity.ctime_ns or sql.NULL, identity.mtime_ns, encoded, time.now():format_rfc3339()})
    if err then return tostring(err) end
    return nil
end

function M.open(): (sql.DB?, string?)
    return node_database.open()
end

return M
