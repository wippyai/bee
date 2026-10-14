-- MIT. The live platform documentation: the site the offline corpus is
-- selected from, at the manifest's base. It answers search, a page, the table
-- of contents and the curated llms.txt index, each as one bounded window of
-- the fetched text; the docs web policy limits requests to that site.
local http_client = require("http_client")
local M = {}
type Request = {operation: string, query: string?, path: string?, offset: integer, limit: integer}
type Window = {content: string, offset: integer, next_offset: integer?, eof: boolean, size: integer, source: string}

local function encode(text: string): string
    return (text:gsub("([^%w%-%.%_%~ ])", function(c: string): string return string.format("%%%02X", string.byte(c)) end):gsub(" ", "+"))
end

function M.url(base: string, request: Request): string
    if request.operation == "web_search" then return base .. "/search?q=" .. encode(tostring(request.query)) end
    if request.operation == "web_read" then return base .. "/path/en/" .. tostring(request.path) end
    if request.operation == "web_toc" then return base .. "/toc" end
    return assert(base:match("^(https://[^/]+)")) .. "/llms.txt"
end

function M.window(source: string, body: string, offset: integer, limit: integer): Window
    local start = math.min(offset, #body)
    local content = body:sub(start + 1, start + limit)
    local next_offset = start + #content
    return {content = content, offset = start, next_offset = next_offset < #body and next_offset or nil,
        eof = next_offset >= #body, size = #body, source = source}
end

function M.fetch(base: string, request: Request): (Window?, string?, string?)
    local url = M.url(base, request)
    local response, request_error = http_client.get(url)
    if not response then return nil, "UNAVAILABLE", "the documentation site is unreachable: " .. tostring(request_error) end
    if response.status_code == 404 then return nil, "NOT_FOUND", "no documentation page at " .. url end
    if response.status_code ~= 200 then return nil, "UNAVAILABLE", "the documentation site answered " .. tostring(response.status_code) end
    return M.window(url, tostring(response.body or ""), request.offset, request.limit), nil, nil
end

return M
