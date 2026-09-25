local bounds = require("bounds")
local base64 = require("base64")
local M = {}
type Operation = "create" | "put" | "append" | "remove" | "list" | "read" | "freeze" | "guide"
type Request = {operation: Operation, workspace_id: string, expected_revision: integer?,
    idempotency_key: string?, path: string?, content: string?, snapshot_digest: string?,
    offset: integer?, limit: integer?, result_digest: string?, owned: boolean?}
local function path(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > 240 or value:find("%c")
        or value:find(":", 1, true) or value:find("\\", 1, true) then return nil end
    for segment in (value .. "/"):gmatch("([^/]*)/") do
        if segment == "" or segment == "." or segment == ".." then return nil end
    end
    return value
end
function M.decode(raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "request must be an object" end
    local op = value.operation
    if op ~= "create" and op ~= "put" and op ~= "append" and op ~= "remove" and op ~= "list" and op ~= "read" and op ~= "freeze" and op ~= "guide" then
        return nil, "unknown workspace operation"
    end
    -- guide is read-only and names no workspace: it returns this destination's
    -- authoring contract, so it is decoded before workspace identity is required.
    if op == "guide" then
        -- A direct caller sends operation alone; the MCP argument decoder
        -- carries the empty sentinel this request returns. Both are accepted,
        -- and no workspace identity is ever consulted for the guide.
        local extra = bounds.fields(value, {"operation", "workspace_id"})
        if extra then return nil, extra end
        -- The facade returns the guide before any workspace is consulted,
        -- so this request carries no workspace identity.
        local request: Request = {operation = "guide", workspace_id = ""}
        return request, nil
    end
    local allowed: {string} = {"operation", "workspace_id"}
    if op == "list" then allowed[#allowed + 1] = "owned" end
    if op == "list" or op == "read" then allowed[#allowed + 1] = "snapshot_digest" end
    if op == "read" then
        allowed[#allowed + 1] = "offset"
        allowed[#allowed + 1] = "limit"
    end
    if op ~= "list" and op ~= "read" and op ~= "guide" then
        allowed[#allowed + 1] = "expected_revision"
        allowed[#allowed + 1] = "idempotency_key"
    end
    if op == "put" or op == "append" or op == "remove" or op == "read" then allowed[#allowed + 1] = "path" end
    if op == "put" or op == "append" then
        allowed[#allowed + 1] = "content"
        allowed[#allowed + 1] = "content_base64"
    end
    if op == "append" then
        allowed[#allowed + 1] = "offset"
        allowed[#allowed + 1] = "result_digest"
    end
    local extra = bounds.fields(value, allowed)
    if extra then return nil, extra end
    local owned = op == "list" and value.owned == true and value.workspace_id == ""
    if value.owned ~= nil and not owned then return nil, "owned listing cannot name a workspace" end
    local identity = owned and "" or bounds.id(value.workspace_id)
    if identity == nil then return nil, "workspace_id must be a bounded identifier" end
    local request: Request = {operation = op :: Operation, workspace_id = identity}
    if owned then request.owned = true end
    if value.snapshot_digest ~= nil then
        local digest = value.snapshot_digest
        if type(digest) ~= "string" or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
            return nil, "snapshot_digest must be a lowercase SHA-256 measurement"
        end
        request.snapshot_digest = digest
    end
    if op == "read" then
        local offset = value.offset == nil and 0 or bounds.count(value.offset)
        local limit = value.limit == nil and 16384 or bounds.count(value.limit)
        if not offset or offset > 4194304 or not limit or limit < 1 or limit > 16384 then
            return nil, "read offset or limit is outside the bounded file window"
        end
        request.offset, request.limit = offset, limit
    end
    if op ~= "list" and op ~= "read" then
        local revision, key = bounds.count(value.expected_revision), bounds.id(value.idempotency_key)
        if not revision or revision >= 9007199254740991 or not key then return nil, "expected_revision and idempotency_key are required" end
        if op == "create" and revision ~= 0 then return nil, "create requires expected_revision zero" end
        request.expected_revision, request.idempotency_key = revision, key
    end
    if op == "put" or op == "append" or op == "remove" or op == "read" then
        local selected = path(value.path)
        if not selected then return nil, "path must be a canonical relative path of at most 240 bytes" end
        request.path = selected
    end
    if op == "append" then
        local offset = bounds.count(value.offset)
        local result_digest = value.result_digest
        if not offset or offset > 4194304 then return nil, "append requires a file offset" end
        if result_digest ~= nil and (type(result_digest) ~= "string" or #result_digest ~= 64
            or not result_digest:match("^[0-9a-f]+$")) then
            return nil, "result_digest must be a lowercase SHA-256 measurement"
        end
        request.offset, request.result_digest = offset, result_digest
    end
    if op == "put" or op == "append" then
        if (value.content == nil) == (value.content_base64 == nil) then return nil, "provide exactly one of content or content_base64" end
        if value.content ~= nil then
            if type(value.content) ~= "string" or #value.content > 4194304
                or (op == "append" and #value.content == 0) then return nil, "content exceeds 4 MiB or is empty" end
            request.content = value.content
        else
            local encoded = value.content_base64
            if type(encoded) ~= "string" or #encoded > 5592408 then return nil, "content_base64 exceeds file bound" end
            local decoded, decode_error = base64.decode(encoded)
            if not decoded or decode_error or #decoded > 4194304
                or (op == "append" and #decoded == 0) then return nil, "invalid base64 content" end
            local normalized, encode_error = base64.encode(decoded)
            if encode_error or normalized ~= encoded then return nil, "content_base64 must be canonical padded base64" end
            request.content = decoded
        end
    end
    return request, nil
end

-- The authoring surface calls the durable object an overlay. Storage keeps its
-- workspace identity internally; this one boundary translates the public name
-- without accepting both dialects.
function M.decode_overlay(raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "request must be an object" end
    local extra = bounds.fields(value, {"operation", "overlay_id", "expected_revision", "idempotency_key",
        "path", "content", "content_base64", "snapshot_digest", "offset", "limit", "result_digest"})
    -- Unknown fields name exactly what the caller sent. This is a strict
    -- boundary, not an alias for an older dialect.
    if extra then return nil, extra end
    if value.operation == "guide" and value.overlay_id ~= nil then
        return nil, "guide names no overlay_id"
    end
    local translated: {[string]: unknown} = {}
    for key, item in pairs(value) do translated[key] = item end
    translated.workspace_id = translated.overlay_id
    translated.overlay_id = nil
    if translated.operation == "list" and translated.workspace_id == nil then
        translated.workspace_id, translated.owned = "", true
    end
    local request, decode_error = M.decode(translated)
    if not request then
        return nil, decode_error and decode_error:gsub("workspace_id", "overlay_id"):gsub("workspace", "overlay") or nil
    end
    return request, nil
end
return M
