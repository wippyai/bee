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
local resources = require("resources")
local types = require("types")
local M = {}
M.REVISION = "bee.executable-measurement@1"
M.CHUNK_BYTES = 262144
-- Without a streaming hasher a file is digested from one string, which is
-- bounded so a runtime without the capability measures scripts and small
-- images and refuses the rest rather than exhausting memory.
M.ONE_SHOT_MAX_BYTES = 8388608
type Measurement = {revision: string, path: string, kind: string, interpreter: string?, size: integer, digest: string}
local function kind_of(head: string): (string, string?)
    if head:sub(1, 4) == "\127ELF" then return "elf", nil end
    if head:sub(1, 2) == "#!" then
        local line = head:match("^#!([^\n]*)") or ""
        return "script", (line:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    return "other", nil
end
local function streaming(): boolean
    return type((hash :: {[string]: unknown}).new) == "function"
end
function M.measure(path: unknown): (Measurement?, string?)
    if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then return nil, "path must be nonempty text" end
    if path:sub(1, 1) ~= "/" then return nil, "path must be absolute" end
    local vol, vol_error = fs.get(resources.HOST_FILES)
    if not vol then return nil, "host files unavailable: " .. tostring(vol_error) end
    local info, stat_error = vol:stat(path)
    if not info then return nil, "executable is not readable: " .. tostring(stat_error) end
    if info.is_dir then return nil, "executable is a directory" end
    local size = math.floor(tonumber(info.size) or 0)
    local file, open_error = vol:open(path, "r")
    if not file then return nil, "executable cannot be opened: " .. tostring(open_error) end
    local head = ""
    local digest: string? = nil
    if streaming() then
        local constructor = (hash :: {[string]: unknown}).new :: (string) -> (any, unknown)
        local hasher, hasher_error = constructor("sha256")
        if not hasher then
            file:close()
            return nil, "hasher unavailable: " .. tostring(hasher_error)
        end
        local total = 0
        while true do
            local chunk: unknown = file:read(M.CHUNK_BYTES)
            if type(chunk) ~= "string" or chunk == "" then break end
            local data = chunk :: string
            if head == "" then head = data:sub(1, 256) end
            hasher:update(data)
            total = total + #data
        end
        file:close()
        size = total
        digest = tostring(hasher:sum())
    else
        file:close()
        if size > M.ONE_SHOT_MAX_BYTES then return nil, "this runtime cannot hash a stream and the executable exceeds " .. tostring(M.ONE_SHOT_MAX_BYTES) .. " bytes" end
        local content, read_error = vol:readfile(path)
        if type(content) ~= "string" then return nil, "executable cannot be read: " .. tostring(read_error) end
        head = content:sub(1, 256)
        size = #content
        local sum, hash_error = hash.sha256(content)
        if not sum then return nil, "digest failed: " .. tostring(hash_error) end
        digest = sum
    end
    local kind, interpreter = kind_of(head)
    return {revision = M.REVISION, path = path, kind = kind, interpreter = interpreter, size = size, digest = digest :: string}, nil
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
    local report: Capabilities = {streaming = streaming(), read_only_volume = false, detail = ""}
    local host, host_error = fs.get(resources.HOST_FILES)
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
