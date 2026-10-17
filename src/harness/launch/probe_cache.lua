-- MIT. Probe outputs measured from a CLI's exact executable file. A version
-- or help probe depends only on that file version and its arguments, so its
-- output is recorded among the executable measurements with the file
-- identity and reused while a fresh stat reports the same identity.
local fs = require("fs")
local env = require("env")
local hash = require("hash")
local time = require("time")
local bounds = require("bounds")
local canonical = require("canonical")
local resources = require("resources")
local measurements = require("measurements")
local M = {}
M.DB = "bee:db"
M.PATH_REF = "bee.placement.native.env:placement_path"

type Resolved = {path: string, size: integer, mode: integer, info: measurements.Info}
type Capture = ({string}) -> (string?, integer?, string?, boolean?)

local function executable(mode: integer): boolean
    local permissions = mode % 512
    return permissions % 2 == 1 or math.floor(permissions / 8) % 2 == 1 or math.floor(permissions / 64) % 2 == 1
end

-- resolve finds the file the host executor runs for name: name itself when
-- it holds a slash, otherwise the first executable regular file named name on
-- the executor's PATH. Stat follows links, so an upgrade that repoints a link
-- changes the identity.
function M.resolve(name: string): Resolved?
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
            return {path = candidate, size = math.floor(info.size), mode = math.floor(info.mode), info = info}
        end
    end
    return nil
end

local function key(path: string, args: {string}, home: string?): string?
    local encoded = canonical.encode({path = path, args = args, home = home or ""})
    if not encoded then return nil end
    return hash.sha256(encoded)
end

local function stored(digest: string, identity: measurements.Identity): (string?, integer?)
    local db = measurements.open()
    if not db then return nil, nil end
    local recorded = bounds.object(measurements.find(db, digest, identity))
    db:release()
    if not recorded or type(recorded.output) ~= "string" then return nil, nil end
    local code = bounds.integer(recorded.exit_code)
    if code == nil then return nil, nil end
    return recorded.output, code
end

local function store(digest: string, path: string, identity: measurements.Identity, output: string, code: integer)
    local after = M.resolve(path)
    if not after or not measurements.same(identity, measurements.observed(after.info)) then return end
    local db = measurements.open()
    if not db then return end
    measurements.record(db, digest, path, identity, {exit_code = code, output = output})
    db:release()
end

-- measure returns the output and exit code of argv: the recorded measurement
-- of the same file version and arguments, otherwise a fresh capture, which
-- is recorded once it completes with an exit code from a file version that
-- held through the probe. home is part of the key because the probe runs
-- with it.
function M.measure(argv: {string}, home: string?, capture: Capture): (string?, integer?, string?, boolean?)
    local started = time.now():unix_nano()
    local resolved = M.resolve(argv[1])
    local identity = resolved and measurements.settled(resolved.info, started) or nil
    local args: {string} = {}
    for index = 2, #argv do args[#args + 1] = argv[index] end
    local digest = resolved and identity and key(resolved.path, args, home) or nil
    if not resolved or not identity or not digest then return capture(argv) end
    local output, code = stored(digest, identity)
    if output and code then return output, code, nil, false end
    local measured, measured_code, probe_error, missing = capture(argv)
    if not probe_error and measured and measured_code then store(digest, resolved.path, identity, measured, measured_code) end
    return measured, measured_code, probe_error, missing
end

return M
