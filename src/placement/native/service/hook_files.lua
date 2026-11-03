-- MIT. A hook reader's read of one file a native attempt's CLI wrote under
-- its HOME. The attempt's CLI descriptor declares, in hook_files, the
-- directories under HOME whose files a hook reader may read; a path outside
-- them, or outside the attempt's own HOME, is refused. An isolated HOME is
-- read through the placement root, a machine HOME through a read-only volume
-- rooted at it; neither volume follows a link out of its root.
local fs = require("fs")
local env = require("env")
local bounds = require("bounds")
local store = require("store")
local homes = require("homes")
local resolver = require("resolver")
local M = {}
type Object = {[string]: unknown}
type Reply = {ok: boolean, value: Object?, error: {code: string, message: string}?}
type Home = {volume: fs.FS, base: string, directory: string}
M.MACHINE_HOME = "bee.env:machine_home"
M.MACHINE_FILES = "bee.placement.native.env:machine_home_files"
M.MAX_CHUNK_BYTES = 1048576

local function fail(code: string, message: string): Reply return {ok = false, error = {code = code, message = message}} end

-- canonical: an absolute path with no empty, dot or dot-dot component.
local function canonical(path: string): boolean
    if path:sub(1, 1) ~= "/" or path == "/" or path:sub(-1) == "/" or path:find("//", 1, true) then return false end
    for part in path:gmatch("[^/]+") do
        if part == "." or part == ".." then return false end
    end
    return true
end

local function home_of(request: Object): (Home?, string?)
    local refs = bounds.object(request.environment_refs) or {}
    local launch = bounds.object(request.launch) or {}
    if refs.HOME == M.MACHINE_HOME then
        local directory = env.get(M.MACHINE_HOME)
        local volume = fs.get(M.MACHINE_FILES)
        if type(directory) ~= "string" or not canonical(directory) or not volume then return nil, "machine HOME is unavailable" end
        return {volume = volume, base = "", directory = directory}, nil
    end
    if refs.HOME ~= nil then return nil, "attempt HOME is not one placement owns" end
    local owner, attempt = bounds.id(request.owner_id), bounds.id(request.attempt_id)
    local session = bounds.id(request.session_ref)
    if not owner or not attempt then return nil, "attempt request has no identity" end
    local key: string?
    local kind = homes.ATTEMPTS
    if launch.home_ref ~= nil and session then
        key, kind = homes.session_key(owner, session), homes.SESSIONS
    else
        key = homes.attempt_key(owner, attempt)
    end
    if not key then return nil, "attempt HOME key is unavailable" end
    local base = "/" .. kind .. "/" .. key .. "/home"
    local directory, directory_error = homes.os_path(base)
    if not directory then return nil, directory_error end
    local volume, volume_error = homes.private_volume()
    if not volume then return nil, volume_error end
    return {volume = volume, base = base, directory = directory}, nil
end

-- admitted: the path relative to HOME when it lies under one of the
-- descriptor's hook_files directories.
local function admitted(path: string, home: Home, directories: {string}): (string?, string?)
    local prefix = home.directory .. "/"
    if not canonical(path) or path:sub(1, #prefix) ~= prefix then return nil, "path is outside the attempt's HOME" end
    local relative = path:sub(#prefix + 1)
    for _, directory in ipairs(directories) do
        if relative:sub(1, #directory + 1) == directory .. "/" then return relative, nil end
    end
    return nil, "path is outside the hook files the attempt's CLI declares under its HOME"
end

-- read: {attempt_id, path, offset, length} -> {size, data}; length 0 reads
-- only the file's size.
function M.read(raw: unknown): Reply
    local item = bounds.object(raw)
    if not item or bounds.fields(item, {"attempt_id", "path", "offset", "length"}) then return fail("INVALID", "request names attempt_id, path, offset and length") end
    local attempt_id, path = bounds.id(item.attempt_id), bounds.line(item.path, 4096)
    local offset, length = bounds.count(item.offset), bounds.count(item.length)
    if not attempt_id or not path or not offset or not length or length > M.MAX_CHUNK_BYTES then return fail("INVALID", "request names attempt_id, path, offset and length") end
    local db, open_error = store.open()
    if not db then return fail("STORAGE", tostring(open_error)) end
    local row = store.row(db, attempt_id)
    db:release()
    if not row then return fail("NOT_FOUND", "attempt is not recorded") end
    local request, request_error = store.request(row)
    if not request then return fail("STORAGE", tostring(request_error)) end
    local pinned, pin_error = resolver.pin()
    if not pinned then return fail("UNAVAILABLE", tostring(pin_error)) end
    local _, renderer_error, descriptor = resolver.configure_renderer(pinned, request.binding_ref, nil)
    if renderer_error then return fail("UNAVAILABLE", renderer_error) end
    local directories = descriptor and descriptor.hook_files or {}
    local home, home_error = home_of(request)
    if not home then return fail("DENIED", tostring(home_error)) end
    local relative, outside = admitted(path, home, directories)
    if not relative then return fail("DENIED", tostring(outside)) end
    local target = home.base .. "/" .. relative
    local info = home.volume:stat(target)
    if not info or info.type ~= "file" then return fail("NOT_FOUND", "hook file is not a regular file") end
    local size = math.floor(tonumber(info.size) or 0)
    if length == 0 then return {ok = true, value = {size = size, data = ""}} end
    if offset > size then return fail("INVALID", "offset is past the end of the file") end
    local file, file_error = home.volume:open(target, "r")
    if not file then return fail("NOT_FOUND", tostring(file_error)) end
    local _, seek_error = file:seek("set", offset)
    local wanted = math.min(length, size - offset)
    local data: unknown = wanted > 0 and file:read(wanted) or ""
    file:close()
    if seek_error or type(data) ~= "string" or #data ~= wanted then return fail("STORAGE", "hook file is unreadable") end
    return {ok = true, value = {size = size, data = data}}
end

return M
