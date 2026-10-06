-- MIT. Drain both pipes of a host process and observe completion or a
-- caller-declared wait bound.
local channel = require("channel")
local time = require("time")

local M = {}
M.MAX_OUTPUT_BYTES = 4096
M.MAX_BOUND_BYTES = 1048576
M.DEADLINE_MS = 3000

type Stream = {
    read: (Stream, integer) -> (unknown, unknown),
    close: (Stream) -> unknown,
}
type Process = {
    wait: (Process) -> (unknown, unknown),
    close: (Process, boolean) -> unknown,
}
type Release = () -> ()
type ReadResult = {kind: "stream", name: "stdout" | "stderr", output: string?, error: string?}
type ExitResult = {kind: "exit", code: integer?, error: string?}
type Result = ReadResult | ExitResult
type Object = {[string]: unknown}

local function read_stream(stream: Stream, maximum: integer): (string?, string?)
    local chunks: {string} = {}
    local size = 0
    while true do
        local chunk, read_error = stream:read(1024)
        if read_error ~= nil then return nil, tostring(read_error) end
        if chunk == nil or chunk == "" then break end
        if type(chunk) ~= "string" then return nil, "host probe stream returned invalid data" end
        size = size + #(chunk)
        if size > maximum then return nil, "host probe output exceeds its bound" end
        chunks[#chunks + 1] = chunk
    end
    return table.concat(chunks), nil
end

function M.capture(proc: Process, stdout: Stream, stderr: Stream, release: Release, timeout_ms: integer?, maximum_bytes: integer?): (string?, integer?, string?)
    local maximum: integer = maximum_bytes or math.floor(M.MAX_OUTPUT_BYTES)
    if maximum < 1 or maximum > M.MAX_BOUND_BYTES then return nil, nil, "invalid host probe output bound" end
    local timeout = timeout_ms or M.DEADLINE_MS
    local finished = false
    local function cleanup(force: boolean)
        if finished then return end
        finished = true
        if force then proc:close(true) end
        stdout:close()
        stderr:close()
        release()
    end
    local results = channel.new(3)
    local next_result: integer = 0
    local results_pending: {[integer]: Result} = {}
    local function send_results(value: Result)
        next_result = next_result + 1
        results_pending[next_result] = value
        results:send(next_result)
    end
    local function pump(name: "stdout" | "stderr", stream: Stream)
        coroutine.spawn(function()
            local output, read_error = read_stream(stream, maximum)
            local sent: Result = {kind = "stream", name = name, output = output, error = read_error}
            send_results(sent)
        end)
    end
    pump("stdout", stdout)
    pump("stderr", stderr)

    local exit_received = false
    local waiter_started = false
    local outputs: {[string]: string} = {}
    local streams_received = 0
    local exit: ExitResult? = nil
    local deadline = timeout > 0 and time.after(tostring(timeout) .. "ms") or nil
    while streams_received < 2 or not exit_received do
        local cases = {results:case_receive()}
        if deadline then cases[#cases + 1] = deadline:case_receive() end
        local selected = channel.select(cases)
        if not selected.ok or selected.channel == deadline then
            cleanup(true)
            return nil, nil, "host probe exceeded the caller-declared wait bound of " .. tostring(timeout) .. "ms (timed out)"
        end
        local serial = selected.value
        if type(serial) ~= "number" then error("invalid completion identity") end
        local result = assert(results_pending[math.floor(serial)], "missing completion")
        results_pending[math.floor(serial)] = nil
        if result.kind == "stream" then
            streams_received = streams_received + 1
            if result.error then
                cleanup(true)
                return nil, nil, result.error
            end
            outputs[assert(result.name)] = result.output or ""
            if streams_received == 2 and not waiter_started then
                waiter_started = true
                coroutine.spawn(function()
                    local raw_code, wait_error = proc:wait()
                    local code = type(raw_code) == "number" and raw_code == math.floor(raw_code) and math.floor(raw_code) or nil
                    local sent: Result = {kind = "exit", code = code, error = wait_error and tostring(wait_error) or nil}
                    send_results(sent)
                end)
            end
        else
            exit = {kind = "exit", code = result.code, error = result.error}
            exit_received = true
            if result.error then
                cleanup(true)
                return nil, nil, "host probe wait failed: " .. result.error
            end
            if result.code == nil then
                cleanup(true)
                return nil, nil, "host probe did not return an exit code"
            end
        end
    end
    cleanup(false)
    return outputs.stdout .. outputs.stderr, exit and exit.code or nil, nil
end

return M
