-- MIT. Drain both output pipes while bounding the lifetime of a host probe.
local channel = require("channel")
local time = require("time")

local M = {}
M.MAX_OUTPUT_BYTES = 4096
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

local function read_stream(stream: Stream): (string?, string?)
    local chunks: {string} = {}
    local size = 0
    while true do
        local chunk, read_error = stream:read(1024)
        if read_error ~= nil then return nil, tostring(read_error) end
        if chunk == nil or chunk == "" then break end
        if type(chunk) ~= "string" then return nil, "host probe stream returned invalid data" end
        size = size + #(chunk :: string)
        if size > M.MAX_OUTPUT_BYTES then return nil, "host probe output exceeds its bound" end
        chunks[#chunks + 1] = chunk :: string
    end
    return table.concat(chunks), nil
end

function M.capture(proc: Process, stdout: Stream, stderr: Stream, release: Release, timeout_ms: integer?): (string?, integer?, string?)
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
    local function pump(name: "stdout" | "stderr", stream: Stream)
        coroutine.spawn(function()
            local output, read_error = read_stream(stream)
            results:send({kind = "stream", name = name, output = output, error = read_error})
        end)
    end
    pump("stdout", stdout)
    pump("stderr", stderr)

    local exit_received = false
    local waiter_started = false
    local outputs: {[string]: string} = {}
    local streams_received = 0
    local exit: ExitResult? = nil
    local deadline = time.after(tostring(timeout) .. "ms")
    while streams_received < 2 or not exit_received do
        local selected = channel.select({results:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then
            cleanup(true)
            return nil, nil, "host probe timed out"
        end
        local result = selected.value :: Result
        if result.kind == "stream" then
            streams_received = streams_received + 1
            if result.error then
                cleanup(true)
                return nil, nil, result.error
            end
            outputs[result.name] = result.output or ""
            if streams_received == 2 and not waiter_started then
                waiter_started = true
                coroutine.spawn(function()
                    local raw_code, wait_error = proc:wait()
                    local code = type(raw_code) == "number" and raw_code == math.floor(raw_code) and math.floor(raw_code) or nil
                    results:send({kind = "exit", code = code, error = wait_error and tostring(wait_error) or nil})
                end)
            end
        else
            exit = result
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
