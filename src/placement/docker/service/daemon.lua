-- SPDX-License-Identifier: MIT
local exec = require("exec")
local channel = require("channel")
local json = require("json")
local bounds = require("bounds")
local resources = require("resources")
local quote = require("quote")
local M = {}
type Channel = channel.Channel
type Reader = {read: (Reader, integer) -> (unknown, unknown)}
function M.command(argv: {string}, progress: ((string) -> ())?, cancel: Channel<boolean>?): (string?, string?, integer?)
    local ref, ref_error = resources.executor()
    local executor = ref and exec.get(ref) or nil
    if not executor then return nil, ref_error or "host executor unavailable" end
    local child, child_error = executor:exec(quote.line(argv), {process_group = true})
    if not child then executor:release(); return nil, tostring(child_error) end
    local stdout, stdout_error = child:stdout_stream()
    local stderr, stderr_error = child:stderr_stream()
    if not stdout or not stderr then child:close(true); executor:release(); return nil, tostring(stdout_error or stderr_error) end
    local output: {string} = {}
    local errors: {string} = {}
    local total = 0
    local failure: string? = nil
    local function drain(stream: Reader, buffer: {string})
        while true do
            local chunk, read_error = stream:read(4096)
            if read_error then failure = tostring(read_error); child:close(true); break end
            if chunk == nil or chunk == "" then break end
            if type(chunk) ~= "string" then failure = "command stream returned invalid data"; child:close(true); break end
            total = total + #chunk
            if total > 1048576 then failure = "command output exceeds its 1048576-byte protocol bound"; child:close(true); break end
            buffer[#buffer + 1] = chunk
            if progress then progress(chunk) end
        end
    end
    local stdout_reader: Reader = {read = function(_self: Reader, size: integer): (unknown, unknown) return stdout:read(size) end}
    local stderr_reader: Reader = {read = function(_self: Reader, size: integer): (unknown, unknown) return stderr:read(size) end}
    local started, start_error = child:start()
    if not started then child:close(true); executor:release(); return nil, tostring(start_error) end
    local finished = channel.new(2)
    coroutine.spawn(function() drain(stderr_reader, errors); finished:send(true) end)
    coroutine.spawn(function() drain(stdout_reader, output); finished:send(true) end)
    for _ = 1, 2 do
        local cases = {finished:case_receive()}
        if cancel then cases[#cases + 1] = cancel:case_receive() end
        local selected = channel.select(cases)
        if not selected.ok or selected.channel == cancel then
            child:close(true); executor:release()
            return nil, "runtime image build cancelled; inspect its recorded result before another launch"
        end
    end
    local raw_code, wait_error = child:wait()
    local code = type(raw_code) == "number" and raw_code == math.floor(raw_code) and math.floor(raw_code) or nil
    stdout:close(); stderr:close(); executor:release()
    if failure then return nil, failure, code end
    if wait_error then return nil, tostring(wait_error), code end
    if code == nil then return nil, "command wait returned no integer exit code" end
    if code ~= 0 then return nil, argv[1] .. " exit " .. tostring(code) .. ": " .. table.concat(errors) .. table.concat(output), code end
    return table.concat(output), nil, code
end
function M.decode_response(output: string): (unknown, string?, boolean?)
    local body, status = output:match("^([%s%S]*)\n(%d%d%d)$")
    if not body or not status then return nil, "Docker response has no HTTP status" end
    local code = assert(tonumber(status))
    local decoded, decode_error = json.decode(body)
    if code >= 400 then
        local value = bounds.object(decoded)
        local message = value and bounds.text(value.message, 65536)
        if not message then return nil, "Docker HTTP " .. status .. ": " .. body end
        return nil, "Docker HTTP " .. status .. ": " .. message, code == 404
    end
    if body == "" then return true, nil end
    if decode_error then return nil, "Docker response JSON: " .. tostring(decode_error) end
    return decoded, nil
end
function M.request(method: string, endpoint: string, cancel: Channel<boolean>?): (unknown, string?, boolean?)
    local output, err = M.command({"curl", "--disable", "--noproxy", "*", "--silent", "--show-error", "--unix-socket", "/var/run/docker.sock",
        "--request", method, "--write-out", "\n%{http_code}", "http://docker" .. endpoint}, nil, cancel)
    if not output then return nil, err end
    return M.decode_response(output)
end
function M.inspect(kind: string, ref: string, cancel: Channel<boolean>?): ({[string]: unknown}?, string?)
    local suffix = kind == "network" and "" or "/json"
    local result, err, absent = M.request("GET", "/" .. kind .. "s/" .. ref .. suffix, cancel)
    if absent then return nil, nil end
    if err then return nil, err end
    local object = bounds.object(result)
    if not object then return nil, "Docker " .. kind .. " inspection returned no object" end
    return object, nil
end
function M.containers(image: string): ({unknown}?, string?)
    local filters = assert(json.encode({ancestor = {image}}))
    local escaped = filters:gsub("([^A-Za-z0-9_.~-])", function(value) return string.format("%%%02X", assert(value:byte())) end)
    local result, err = M.request("GET", "/containers/json?all=true&filters=" .. escaped)
    if err then return nil, err end
    local rows = bounds.array(result, 1024)
    if not rows then return nil, "Docker container inventory is malformed or exceeds its 1024-entry protocol bound" end
    return rows, nil
end
return M
