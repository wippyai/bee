-- MIT. Runs one command through an executor under the caller's scope and
-- reports which step the runtime refused, or the process output.
local exec = require("exec")
type Request = {executor: string, command: string, work_dir: string?, env: {[string]: string}?}
type Result = {ok: boolean, stage: string?, error: string?, output: string?, code: integer?}
local function run(request: Request): Result
    local executor, get_error = exec.get(request.executor)
    if not executor then return {ok = false, stage = "get", error = tostring(get_error)} end
    local process, exec_error = executor:exec(request.command, {work_dir = request.work_dir, env = request.env})
    if not process then
        executor:release()
        return {ok = false, stage = "exec", error = tostring(exec_error)}
    end
    local stdout = assert(process:stdout_stream())
    assert(process:start())
    local chunks: {string} = {}
    while true do
        local data = stdout:read()
        if not data or data == "" then break end
        chunks[#chunks + 1] = data
    end
    local code = process:wait()
    executor:release()
    return {ok = true, output = table.concat(chunks), code = code}
end
return {run = run}
