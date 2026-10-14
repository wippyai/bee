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
    local proc, exec_error = executor:exec("true", {process_group = true})
    if not proc then
        executor:release()
        return {capability = "direct_process", exit_observation = "independent", stdin_close = true, detail = "runtime refused process_group: " .. tostring(exec_error)}
    end
    proc:close()
    executor:release()
    return {capability = "process_group", exit_observation = "independent", stdin_close = true,
        detail = "runtime accepts process_group; Process.done observes child exit independently"}
end
return M
