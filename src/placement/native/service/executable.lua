-- MIT. A read-only measurement of a host-selected launch target: the
-- content digest of the file the path opens, its kind (an ELF image, a
-- script with its interpreter line, or other bytes), the measurement
-- revision and, when the OS pins the file version, its identity. The
-- digest covers that one file: a script's interpreter and a launcher's
-- targets are not measured, and the kind says so.
--
-- A file version is hashed once: the measurement is recorded with its
-- identity and reused while a fresh stat reports the same identity. A plan
-- carries the identity, and the runner compares it with a fresh stat
-- immediately before exec and refuses any difference; a plan without one
-- is verified by measuring the content again. The runtime executes by
-- path, so a replacement between that check and exec is not excluded.
local fs = require("fs")
local hash = require("hash")
local time = require("time")
local bounds = require("bounds")
local resources = require("resources")
local types = require("types")
local executable_stream = require("executable_stream")
local measurements = require("measurements")
local M = {}
M.REVISION = "bee.executable-measurement@1"
type Measurement = {revision: string, path: string, kind: string, interpreter: string?, size: integer, digest: string, identity: types.ExecutableIdentity?}
type Recorded = {kind: string, interpreter: string?, digest: string}
local function kind_of(head: string): (string, string?)
    if head:sub(1, 4) == "\127ELF" then return "elf", nil end
    if head:sub(1, 2) == "#!" then
        local line = head:match("^#!([^\n]*)") or ""
        return "script", (line:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    return "other", nil
end
local function key_of(path: string): string?
    return hash.sha256(M.REVISION .. "\n" .. path)
end
local function recorded_of(value: unknown): Recorded?
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"kind", "interpreter", "digest"}) then return nil end
    local kind = bounds.member(object.kind, types.EXECUTABLE_KINDS)
    local digest = bounds.digest_hex(object.digest)
    local interpreter: string? = nil
    if object.interpreter ~= nil then interpreter = bounds.text(object.interpreter, 4096) end
    if not kind or not digest or (object.interpreter ~= nil and not interpreter) or (kind == "script") ~= (interpreter ~= nil) then return nil end
    return {kind = kind, interpreter = interpreter, digest = digest}
end
local function recorded_measurement(key: string, identity: measurements.Identity): (Recorded?, string?)
    local db, db_error = measurements.open()
    if not db then return nil, db_error end
    local recorded = recorded_of(measurements.find(db, key, identity))
    db:release()
    return recorded, nil
end
local function record(key: string, path: string, identity: measurements.Identity, measured: Recorded): string?
    local db, db_error = measurements.open()
    if not db then return db_error end
    local record_error = measurements.record(db, key, path, identity, measured)
    db:release()
    return record_error
end
local function host_volume(): (fs.FS?, string?)
    local host_files, host_files_error = resources.host_files()
    if not host_files then return nil, "host files unavailable: " .. tostring(host_files_error) end
    local vol, vol_error = fs.get(host_files)
    if not vol then return nil, "host files unavailable: " .. tostring(vol_error) end
    return vol, nil
end
local function valid_path(path: unknown): (string?, string?)
    if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then return nil, "path must be nonempty text" end
    if path:sub(1, 1) ~= "/" then return nil, "path must be absolute" end
    return path, nil
end
function M.measure(raw_path: unknown): (Measurement?, string?)
    local path, path_error = valid_path(raw_path)
    if not path then return nil, path_error end
    local vol, vol_error = host_volume()
    if not vol then return nil, vol_error end
    local started = time.now():unix_nano()
    local info, stat_error = vol:stat(path)
    if not info then return nil, "executable is not readable: " .. tostring(stat_error) end
    if info.is_dir then return nil, "executable is a directory" end
    local file, open_error = vol:open(path, "r")
    if not file then return nil, "executable cannot be opened: " .. tostring(open_error) end
    local opened = file:stat()
    local size = bounds.integer(opened and opened.size or info.size)
    if not size or size < 0 then
        file:close()
        return nil, "executable has an invalid reported size"
    end
    -- The identity of the opened file version, when the OS pins it and
    -- its last change is old enough that a later write changes it.
    local pinned = measurements.pinned(opened and measurements.settled(opened, started) or nil)
    local key = pinned and key_of(path) or nil
    if pinned and key then
        local recorded, lookup_error = recorded_measurement(key, pinned)
        if lookup_error then
            file:close()
            return nil, "executable measurements unavailable: " .. lookup_error
        end
        if recorded then
            file:close()
            return {revision = M.REVISION, path = path, kind = recorded.kind, interpreter = recorded.interpreter, size = size, digest = recorded.digest, identity = pinned}, nil
        end
    end
    local streamed, stream_error = executable_stream.digest(
        function(chunk_size: integer): (string?, string?) return file:read(chunk_size) end,
        function(): (boolean?, string?) return file:close() end,
        size)
    if not streamed then return nil, stream_error end
    local kind, interpreter = kind_of(streamed.head)
    if pinned and key then
        local after = vol:stat(path)
        if not after or not measurements.same(pinned, measurements.observed(after)) then return nil, "executable changed while it was measured" end
        local record_error = record(key, path, pinned, {kind = kind, interpreter = interpreter, digest = streamed.digest})
        if record_error then return nil, "executable measurement cannot be recorded: " .. record_error end
    end
    return {revision = M.REVISION, path = path, kind = kind, interpreter = interpreter, size = streamed.size, digest = streamed.digest, identity = pinned}, nil
end
-- capabilities: what this runtime proves about measurement, measured
-- rather than declared. Streaming is the hasher's presence; read-only
-- enforcement is proven by a creating open through the host volume at a
-- path inside the placement's own root, which an enforcing runtime refuses
-- and an older one, ignoring the declaration, performs; that file is then
-- removed through the writable root volume. An ignored declaration
-- reports false, never an affirmative capability.
type Capabilities = {streaming: boolean, read_only_volume: boolean, detail: string}
function M.capabilities(): Capabilities
    local report: Capabilities = {streaming = true, read_only_volume = false, detail = ""}
    local host_files, host_files_error = resources.host_files()
    if not host_files then
        report.detail = "host files unavailable: " .. tostring(host_files_error)
        return report
    end
    local host, host_error = fs.get(host_files)
    if not host then
        report.detail = "host files unavailable: " .. tostring(host_error)
        return report
    end
    local root_path, root_error = resources.directory("bee.placement.native.env:root")
    if not root_path then
        report.detail = "placement root unavailable: " .. tostring(root_error)
        return report
    end
    local probe_name = "measurement-probe-" .. tostring(hash.sha256(tostring(os.time()) .. tostring(math.random())) or "probe"):sub(1, 16)
    local file, open_error = host:open(root_path .. "/" .. probe_name, "wx")
    if not file then
        -- Only the runtime's own read-only refusal proves enforcement; a
        -- permission denial, a missing directory or any other failure
        -- proves nothing and reports unknown.
        local why = tostring(open_error)
        if why:find("read-only", 1, true) then
            report.read_only_volume = true
            report.detail = "a creating open through the host volume is refused as read-only: " .. why
        else
            report.detail = "a creating open through the host volume failed for another reason, so enforcement is unknown: " .. why
        end
        return report
    end
    file:close()
    local root_id = resources.root()
    local root_volume = root_id and fs.get(root_id) or nil
    if root_volume then root_volume:remove("/" .. probe_name) end
    report.detail = "a creating open through the host volume succeeded; the readonly declaration is not enforced by this runtime"
    return report
end
-- verify: the planned measurement still describes what the path opens: the
-- planned identity against a fresh stat, or the content measured again
-- when the plan carries no identity.
function M.verify(path: string, planned: types.ExecutableMeasurement): (Measurement?, string?)
    local identity = planned.identity
    if identity then
        if planned.revision ~= M.REVISION then return nil, "measurement revision " .. M.REVISION .. " differs from the planned " .. planned.revision end
        local vol, vol_error = host_volume()
        if not vol then return nil, vol_error end
        local info, stat_error = vol:stat(path)
        if not info then return nil, "executable is not readable: " .. tostring(stat_error) end
        if not measurements.same(identity, measurements.observed(info)) then return nil, "executable changed since the plan measured it: its file identity differs" end
        return {revision = planned.revision, path = path, kind = planned.kind, interpreter = nil, size = identity.size, digest = planned.digest, identity = identity}, nil
    end
    local measured, err = M.measure(path)
    if not measured then return nil, err end
    if measured.revision ~= planned.revision then return nil, "measurement revision " .. measured.revision .. " differs from the planned " .. planned.revision end
    if measured.kind ~= planned.kind then return nil, "executable kind " .. measured.kind .. " differs from the planned " .. planned.kind end
    if measured.digest ~= planned.digest then return nil, "executable changed since the plan measured it: " .. measured.digest .. " now, " .. planned.digest .. " planned" end
    return measured, nil
end
return M
