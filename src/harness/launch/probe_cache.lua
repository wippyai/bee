-- MIT. Probe outputs measured from a CLI's exact executable file. A version
-- or help probe depends only on that file and its arguments, so its output is
-- reused while the resolved file keeps its size, mode and modification time,
-- and measured again once the CLI changes on disk.
local sql = require("sql")
local fs = require("fs")
local env = require("env")
local hash = require("hash")
local time = require("time")
local canonical = require("canonical")
local resources = require("resources")
local M = {}
M.DB = "bee:db"
M.PATH_REF = "bee.placement.native.env:placement_path"

type Identity = {path: string, size: integer, modified: integer, mode: integer}
type Capture = ({string}) -> (string?, integer?, string?, boolean?)

local function executable(mode: integer): boolean
    local permissions = mode % 512
    return permissions % 2 == 1 or math.floor(permissions / 8) % 2 == 1 or math.floor(permissions / 64) % 2 == 1
end

-- resolve finds the file the host executor runs for name: name itself when
-- it holds a slash, otherwise the first executable regular file named name on
-- the executor's PATH. Stat follows links, so an upgrade that repoints a link
-- changes the identity.
function M.resolve(name: string): Identity?
    local volume_ref = resources.host_files()
    if not volume_ref then return nil end
    local volume = fs.get(volume_ref)
    if not volume then return nil end
    local candidates: {string} = {}
    if name:find("/", 1, true) then
        candidates[1] = name
    else
        local search, search_error = env.get(M.PATH_REF)
        if search_error or type(search) ~= "string" then return nil end
        for directory in search:gmatch("[^:]+") do
            if directory:sub(1, 1) == "/" then candidates[#candidates + 1] = (directory:gsub("/+$", "")) .. "/" .. name end
        end
    end
    for _, candidate in ipairs(candidates) do
        local info = volume:stat(candidate)
        if info and not info.is_dir and executable(math.floor(info.mode)) then
            return {path = candidate, size = math.floor(info.size), modified = math.floor(info.modified), mode = math.floor(info.mode)}
        end
    end
    return nil
end

local function key(identity: Identity, args: {string}, home: string?): string?
    local encoded = canonical.encode({path = identity.path, args = args, home = home or ""})
    if not encoded then return nil end
    return hash.sha256(encoded)
end

local function stored(db: sql.DB, digest: string, identity: Identity): (string?, integer?)
    local rows = db:query("SELECT size, modified, mode, exit_code, output FROM bee_harness_probe_outputs WHERE key_digest = ?", {digest})
    local row = rows and rows[1]
    if not row or row.size ~= identity.size or row.modified ~= identity.modified or row.mode ~= identity.mode then return nil, nil end
    if type(row.output) ~= "string" or type(row.exit_code) ~= "number" then return nil, nil end
    return row.output, math.floor(row.exit_code)
end

local function store(db: sql.DB, digest: string, identity: Identity, output: string, code: integer)
    db:execute("INSERT INTO bee_harness_probe_outputs (key_digest, executable_path, size, modified, mode, exit_code, output, measured_at) " ..
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(key_digest) DO UPDATE SET executable_path = excluded.executable_path, " ..
        "size = excluded.size, modified = excluded.modified, mode = excluded.mode, exit_code = excluded.exit_code, " ..
        "output = excluded.output, measured_at = excluded.measured_at",
        {digest, identity.path, identity.size, identity.modified, identity.mode, code, output, time.now():format_rfc3339()})
end

-- measure returns the output and exit code of argv: the stored measurement of
-- the same file and arguments when the file is unchanged, otherwise a fresh
-- capture, which is stored once it completes with an exit code. home is part
-- of the key because the probe runs with it.
function M.measure(argv: {string}, home: string?, capture: Capture): (string?, integer?, string?, boolean?)
    local identity = M.resolve(argv[1])
    local args: {string} = {}
    for index = 2, #argv do args[#args + 1] = argv[index] end
    local digest = identity and key(identity, args, home)
    local db = identity and digest and sql.get(M.DB) or nil
    if not identity or not digest or not db then return capture(argv) end
    local output, code = stored(db, digest, identity)
    if output and code then
        db:release()
        return output, code, nil, false
    end
    local measured, measured_code, probe_error, missing = capture(argv)
    if not probe_error and measured and measured_code then store(db, digest, identity, measured, measured_code) end
    db:release()
    return measured, measured_code, probe_error, missing
end

return M
