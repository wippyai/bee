-- MIT. Read-only package browser state. All reads go through the public Hub API.
local json = require("json")
local base64 = require("base64")
local text = require("text")
local M = {}
type Object = {[string]: unknown}
type Intent = {operation: string, request: Object}
type Reply = {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean}
type Row = {key: string, label: string, kind: string, value: unknown}
type State = {open: boolean, component: string, version: string, digest: string?, mode: string,
    resource: string, path: string, rows: {Row}, selected: integer, lines: {string}, notice: string,
    next_offset: integer?, offset: integer, pending: boolean}
function M.new(): State
    return {open = false, component = "", version = "", digest = nil, mode = "entries", resource = "", path = ".",
        rows = {}, selected = 1, lines = {}, notice = "", next_offset = nil, offset = 0, pending = false}
end
local function object(raw: unknown): Object?
    return type(raw) == "table" and raw :: Object or nil
end
local function list(raw: unknown, limit: integer): {unknown}?
    if type(raw) ~= "table" then return nil end
    local count = 0
    for key in pairs(raw) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil end
        count = count + 1
        if count > limit then return nil end
    end
    local result: {unknown} = {}
    for index = 1, count do
        local item = (raw :: {[integer]: unknown})[index]
        if item == nil then return nil end
        result[index] = item
    end
    return result
end
local function clean(raw: unknown, bound: integer): string?
    if type(raw) ~= "string" or #raw == 0 or #raw > bound or raw:find("%c") then return nil end
    return raw
end
local function lines(raw: string): {string}
    local result: {string} = {}
    for row in (raw .. "\n"):gmatch("([^\n]*)\n") do result[#result + 1] = text.bound(row, 32768) end
    return result
end
local function definition_lines(raw: string): {string}
    local result: {string} = {}
    local row, depth, quoted, escaped = "", 0, false, false
    local function flush()
        if row ~= "" then result[#result + 1] = string.rep("  ", math.min(depth, 16)) .. row; row = "" end
    end
    for index = 1, #raw do
        local char = raw:sub(index, index)
        if quoted then
            row = row .. char
            if escaped then escaped = false elseif char == "\\" then escaped = true elseif char == '"' then quoted = false end
        elseif char == '"' then quoted = true; row = row .. char
        elseif char == "{" or char == "[" then row = row .. char; flush(); depth = depth + 1
        elseif char == "}" or char == "]" then flush(); depth = math.max(0, depth - 1); row = char
        elseif char == "," then row = row .. char; flush()
        elseif char == ":" then row = row .. ": "
        else row = row .. char end
    end
    flush()
    return result
end
local function request(state: State, operation: string, offset: integer): Intent
    state.pending, state.notice, state.offset = true, "Loading package contents…", offset
    state.rows, state.lines, state.selected, state.next_offset = {}, {}, 1, nil
    local value: Object = {component = state.component, version = state.version}
    if state.digest then value.expected_digest = state.digest end
    if operation ~= "state" then
        value.resource, value.path, value.offset = state.resource, state.path, offset
        value.limit = operation == "files" and 100 or 32768
    end
    return {operation = operation, request = value}
end
function M.start(state: State, component: string, version: string): Intent
    state.open, state.component, state.version, state.digest, state.mode = true, component, version, nil, "entries"
    state.resource, state.path = "", "."
    return request(state, "state", 0)
end
function M.move(state: State, delta: integer)
    state.selected = math.floor(math.max(1, math.min(#state.rows, state.selected + delta)))
end
function M.activate(state: State, key: string?): Intent?
    if state.pending then return nil end
    local row = state.rows[state.selected]
    if key then
        row = nil
        for index, item in ipairs(state.rows) do if item.key == key then row = item; state.selected = index; break end end
    end
    if not row then return nil end
    if row.kind == "resource" then
        state.resource, state.path, state.mode = row.key, ".", "files"
        return request(state, "files", 0)
    elseif row.kind == "directory" or row.kind == "file" then
        state.path = state.path == "." and row.key or (state.path .. "/" .. row.key)
        state.mode = row.kind == "directory" and "files" or "file"
        return request(state, state.mode == "file" and "read_file" or "files", 0)
    else
        local encoded = json.encode(row.value)
        state.mode, state.rows = "entry", {}
        state.resource, state.path = "", row.label
        state.lines = definition_lines(encoded and encoded:sub(1, 32768) or "Entry cannot be represented as JSON")
        state.notice = encoded and #encoded > 32768 and "Entry preview truncated at 32 KiB" or "Read-only entry definition"
    end
    return nil
end
function M.back(state: State): Intent
    if state.mode == "files" and state.path ~= "." or state.mode == "file" then
        state.path = state.path:match("^(.*)/[^/]+$") or "."
        state.mode = "files"
        return request(state, "files", 0)
    end
    state.mode = "entries"
    return request(state, "state", 0)
end
function M.previous(state: State): Intent?
    if state.pending or state.offset == 0 or state.mode == "entries" or state.mode == "entry" then return nil end
    return request(state, state.mode == "file" and "read_file" or "files", math.floor(math.max(0, state.offset - (state.mode == "file" and 32768 or 100))))
end
function M.next(state: State): Intent?
    if state.pending or not state.next_offset then return nil end
    return request(state, state.mode == "file" and "read_file" or "files", state.next_offset)
end
function M.apply(state: State, operation: string, reply: Reply)
    state.pending = false
    local value = object(reply.value)
    local function fail(message: string) state.notice = text.bound(message, 512); state.rows, state.lines, state.next_offset = {}, {}, nil end
    if not reply.ok or not value then fail((reply.code or "UNAVAILABLE") .. ": " .. (reply.message or "Package contents unavailable")); return end
    local measured = clean(value.digest, 64)
    if value.component ~= state.component or value.version ~= state.version or not measured or #measured ~= 64
        or not measured:match("^[0-9a-f]+$") or (state.digest ~= nil and state.digest ~= measured) then
        fail("Package changed; reopen Contents"); return
    end
    local rows: {Row} = {}
    if operation == "state" then
        local entries, resources = list(value.entries, 16384), list(value.resources, 16384)
        if not entries or not resources then fail("Invalid package state"); return end
        for _, raw in ipairs(resources) do
            local row = object(raw)
            local id = row and clean(row.id, 256)
            if not row or not id then fail("Invalid package resource"); return end
            rows[#rows + 1] = {key = id, label = id .. " · Files", kind = "resource", value = nil}
        end
        for _, raw in ipairs(entries) do
            local row = object(raw)
            local id, kind = row and clean(row.id, 256), row and clean(row.kind, 160)
            if not row or not id or not kind then fail("Invalid package entry"); return end
            rows[#rows + 1] = {key = "entry/" .. id, label = id .. " · " .. kind, kind = "entry", value = row}
        end
        state.notice = tostring(#rows) .. " entries and resources · read-only"
    elseif operation == "files" then
        local files = list(value.files, 100)
        if not files then fail("Invalid directory listing"); return end
        for _, raw in ipairs(files) do
            local row = object(raw)
            local name = row and clean(row.name, 1024)
            if not row or not name or name == "." or name == ".." or name:find("[/\\]") or (row.type ~= "directory" and row.type ~= "file") then fail("Invalid package filename"); return end
            rows[#rows + 1] = {key = name, label = name .. (row.type == "directory" and "/" or ""), kind = row.type :: string, value = nil}
        end
        state.notice = #rows == 0 and "This directory is empty" or "Read-only packaged files"
    elseif operation == "read_file" then
        local encoded = value.content_base64
        if type(encoded) ~= "string" then fail("Invalid file response"); return end
        if #encoded > 45000 or value.offset ~= state.offset then fail("Invalid file response"); return end
        local decoded = base64.decode(encoded)
        if not decoded or #decoded > 32768 then fail("Invalid file contents"); return end
        if decoded:find("%z") then state.lines = {"Binary file · text preview unavailable"}
        else state.lines = lines(decoded) end
        state.notice = "Bytes " .. tostring(state.offset) .. "–" .. tostring(state.offset + #decoded) .. " · read-only"
    else fail("Unexpected package response"); return end
    if value.next_offset ~= nil then
        local next_offset = tonumber(value.next_offset)
        if next_offset then
            if type(value.next_offset) ~= "number" or next_offset ~= math.floor(next_offset) or next_offset <= state.offset then fail("Invalid package continuation"); return end
            state.next_offset = math.floor(next_offset)
        else fail("Invalid package continuation"); return end
    else state.next_offset = nil end
    state.digest, state.rows = measured, rows
end
return M
