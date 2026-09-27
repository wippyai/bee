-- MIT. A read-only measurement of a host-selected launch target: the
-- content digest of the file the path opens, its kind (an ELF image, a
-- script with its interpreter line, or other bytes) and the measurement
-- revision. The digest covers that one file: a script's interpreter and a
-- launcher's targets are not measured, and the kind says so. The runtime
-- executes by path, so a replacement between measurement and exec is not
-- excluded; the runner measures again immediately before exec and refuses
-- a change, which bounds the window to that call.
local fs = require("fs")
local hash = require("hash")
local bounds = require("bounds")
local resources = require("resources")
local types = require("types")
local executable_stream = require("executable_stream")
local M = {}
M.REVISION = "bee.executable-measurement@1"
-- Without a streaming hasher a file is digested from one string, which is
-- bounded so a runtime without the capability measures scripts and small
-- images and refuses the rest rather than exhausting memory.
type Measurement = {revision: string, path: string, kind: string, interpreter: string?, size: integer, digest: string}
local function kind_of(head: string): (string, string?)
    if head:sub(1, 4) == "\127ELF" then return "elf", nil end
    if head:sub(1, 2) == "#!" then
        local line = head:match("^#!([^\n]*)") or ""
        return "script", (line:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    return "other", nil
end
function M.measure(path: unknown): (Measurement?, string?)
    if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then return nil, "path must be nonempty text" end
    if path:sub(1, 1) ~= "/" then return nil, "path must be absolute" end
    local host_files, host_files_error = resources.host_files()
    if not host_files then return nil, "host files unavailable: " .. tostring(host_files_error) end
    local vol, vol_error = fs.get(host_files)
    if not vol then return nil, "host files unavailable: " .. tostring(vol_error) end
    local info, stat_error = vol:stat(path)
    if not info then return nil, "executable is not readable: " .. tostring(stat_error) end
    if info.is_dir then return nil, "executable is a directory" end
    local size = bounds.integer(info.size)
    if not size or size < 0 then return nil, "executable has an invalid reported size" end
    local file, open_error = vol:open(path, "r")
    if not file then return nil, "executable cannot be opened: " .. tostring(open_error) end
    local streamed, stream_error = executable_stream.digest(
        function(chunk_size: integer): (string?, string?) return file:read(chunk_size) end,
        function(): (boolean?, string?) return file:close() end,
        size)
    if not streamed then return nil, stream_error end
    local kind, interpreter = kind_of(streamed.head)
    return {revision = M.REVISION, path = path, kind = kind, interpreter = interpreter, size = streamed.size, digest = streamed.digest}, nil
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
    local root_path, root_error = resources.directory("bee.placement.native:root")
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
-- verify: the planned measurement still describes what the path opens now.
function M.verify(path: string, planned: types.ExecutableMeasurement): (Measurement?, string?)
    local measured, err = M.measure(path)
    if not measured then return nil, err end
    if measured.revision ~= planned.revision then return nil, "measurement revision " .. measured.revision .. " differs from the planned " .. planned.revision end
    if measured.kind ~= planned.kind then return nil, "executable kind " .. measured.kind .. " differs from the planned " .. planned.kind end
    if measured.digest ~= planned.digest then return nil, "executable changed since the plan measured it: " .. measured.digest .. " now, " .. planned.digest .. " planned" end
    return measured, nil
end
return M
