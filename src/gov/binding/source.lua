-- SPDX-License-Identifier: MIT
local fs = require("fs")
local base64 = require("base64")
local hash = require("hash")
local bounds = require("bounds")
local transaction = require("transaction")
local protocol = require("protocol")
local M = {}
type Read = (string, string, integer, integer) -> (string?, string?)
type Result = transaction.Result

function M.path(folder_raw: unknown, path_raw: unknown): (string?, string?, string?)
    local folder = bounds.object(folder_raw)
    local root = folder and bounds.id(folder.root_ref) or nil
    local directory = folder and folder.directory or nil
    if not root or type(directory) ~= "string" or folder.subpath ~= "" then
        return nil, nil, "source requires a workspace with its own admitted filesystem root"
    end
    if type(path_raw) ~= "string" then return nil, nil, "source path is missing" end
    local path = path_raw
    if path:sub(1, 1) == "/" then
        local prefix = directory:gsub("/+$", "") .. "/"
        if directory:sub(1, 1) ~= "/" or path:sub(1, #prefix) ~= prefix then
            return nil, nil, "source path is outside the literal filesystem root; use a path relative to the admitted workdir"
        end
        path = path:sub(#prefix + 1)
    end
    local relative = bounds.subpath(path, 240)
    if not relative or relative == "" or relative ~= path then return nil, nil, "source path is not canonical" end
    for segment in path:gmatch("[^/]+") do
        local lower = segment:lower()
        if segment:sub(1, 1) == "." or lower:find("credential", 1, true)
            or lower == "auth.json" or lower == "secrets" or lower:match("%.pem$")
            or lower:match("%.key$") then
            return nil, nil, "source path is private"
        end
    end
    return root, path, nil
end

function M.read_with(read: Read, folder: unknown, request: protocol.Request): Result
    local root, path, invalid = M.path(folder, request.path)
    if not root or not path then return transaction.failure("DENIED", invalid or "source path denied") end
    local offset, limit = request.offset or 0, request.limit or 16384
    local bytes, read_error = read(root, path, offset, limit + 1)
    if not bytes then return transaction.failure("UNAVAILABLE", read_error or "source unavailable") end
    local content = bytes:sub(1, limit)
    local encoded, encoding_error = base64.encode(content)
    local digest, digest_error = hash.sha256(content)
    if not encoded or not digest then return transaction.failure("INTERNAL", tostring(encoding_error or digest_error)) end
    return transaction.success({path = path, offset = offset, content_base64 = encoded,
        window_digest = digest, next_offset = offset + #content, eof = #bytes <= limit}, false)
end

local function read(root: string, path: string, offset: integer, limit: integer): (string?, string?)
    local volume, volume_error = fs.get(root)
    if not volume then return nil, tostring(volume_error or "source volume unavailable") end
    local file, open_error = volume:open(path, "r")
    if not file then return nil, tostring(open_error or "source file unavailable") end
    local position, seek_error = file:seek("set", offset)
    if not position then file:close(); return nil, tostring(seek_error or "source seek failed") end
    local bytes, read_error = file:read(limit)
    local _, close_error = file:close()
    if read_error and read_error:kind() ~= errors.NOT_FOUND then return nil, tostring(read_error) end
    if close_error then return nil, tostring(close_error) end
    return bytes or "", nil
end

function M.read(folder: unknown, request: protocol.Request): Result
    return M.read_with(read, folder, request)
end
return M
