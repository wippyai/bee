local exec = require("exec")
local types = require("types")
local resources = require("resources")
local M = {}
-- stdin_close: whether the executor can end a child's stdin after writing,
-- which a launch that reads its input until end of file requires.
type Measurement = {capability: types.Capability, exit_observation: types.ExitObservation, stdin_close: boolean, detail: string}
function M.measure(): Measurement
    local executor_ref, reference_error = resources.executor()
    local executor, executor_error
    if executor_ref then executor, executor_error = exec.get(executor_ref) else executor_error = reference_error end
    if not executor then return {capability = "direct_process", exit_observation = "eof_gated", stdin_close = false, detail = "executor unavailable: " .. tostring(executor_error)} end
    local proc, exec_error = executor:exec("sh -c 'echo $$; ps -o pgid= -p $$'", {process_group = true})
    if not proc then
        executor:release()
        return {capability = "direct_process", exit_observation = "eof_gated", stdin_close = false, detail = "exec refused: " .. tostring(exec_error)}
    end
    local handle = proc :: {[string]: unknown}
    local observation: types.ExitObservation = "eof_gated"
    if type(handle.done) == "function" then observation = "independent" end
    local stdin_close = type(handle.close_stdin) == "function"
    if type(handle.pid) ~= "function" then
        proc:close(true)
        executor:release()
        return {capability = "direct_process", exit_observation = observation, stdin_close = stdin_close, detail = "exec handle carries no pid"}
    end
    local stdout = proc:stdout_stream()
    local started, start_error = proc:start()
    if not started then
        executor:release()
        return {capability = "direct_process", exit_observation = observation, stdin_close = stdin_close, detail = "probe did not start: " .. tostring(start_error)}
    end
    local pid: unknown = (handle.pid :: (unknown) -> unknown)(proc)
    local chunks: {string} = {}
    while true do
        local chunk = stdout:read(256)
        if not chunk then break end
        chunks[#chunks + 1] = tostring(chunk)
    end
    proc:wait()
    stdout:close()
    executor:release()
    if type(pid) ~= "number" then return {capability = "direct_process", exit_observation = observation, stdin_close = stdin_close, detail = "pid unreadable"} end
    local number = math.floor(pid)
    local reported: {string} = {}
    for token in table.concat(chunks):gmatch("%d+") do reported[#reported + 1] = token end
    if reported[1] ~= tostring(number) then return {capability = "direct_process", exit_observation = observation, stdin_close = stdin_close, detail = "pid " .. tostring(number) .. " does not match the child's own " .. tostring(reported[1])} end
    if reported[2] ~= tostring(number) then return {capability = "direct_process", exit_observation = observation, stdin_close = stdin_close, detail = "child pgid " .. tostring(reported[2]) .. " is not its pid"} end
    return {capability = "process_group", exit_observation = observation, stdin_close = stdin_close, detail = "child " .. tostring(number) .. " leads its own group"}
end
return M
