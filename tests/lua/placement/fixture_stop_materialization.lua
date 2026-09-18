-- MIT. The writer opens the fixture login FIFO, waits until the real
-- credential broker has opened its reader, then stops the attempt before
-- releasing a valid projection reply to the materialization runner.
local fs = require("fs")
local funcs = require("funcs")

type Request = {source_ref: string, attempt_id: string, content: string}
type Reply = {ok: boolean, stopped: unknown?, written: boolean?, error: string?}

local function handle(value: unknown): Reply
    if type(value) ~= "table" then return {ok = false, error = "fixture request is not an object"} end
    local request = value :: Request
    if type(request.source_ref) ~= "string" or type(request.attempt_id) ~= "string" or type(request.content) ~= "string" then
        return {ok = false, error = "fixture request is incomplete"}
    end
    local volume, volume_error = fs.get(request.source_ref)
    if not volume then return {ok = false, error = tostring(volume_error or "fixture source unavailable")} end
    -- Opening the writer blocks until broker.materialize has opened the
    -- provider source for reading. This makes the ownership transition occur
    -- inside the asynchronous credential call, rather than relying on sleep.
    local file, open_error = volume:open("/auth.json", "w")
    if not file then return {ok = false, error = tostring(open_error or "open fixture fifo")} end
    local stopped, stop_error = funcs.call("bee.placement.native:stop", {attempt_id = request.attempt_id, mode = "cooperative"})
    if stop_error or type(stopped) ~= "table" or (stopped :: {[string]: unknown}).ok ~= true then
        file:close()
        local failure = type(stopped) == "table" and (stopped :: {[string]: unknown}).error
        local code = type(failure) == "table" and (failure :: {[string]: unknown}).code or nil
        local message = type(failure) == "table" and (failure :: {[string]: unknown}).message or nil
        return {ok = false, error = tostring(stop_error or code or "stop was refused") .. (message and (": " .. tostring(message)) or "")}
    end
    local stop_object = stopped :: {[string]: unknown}
    local stop_value = stop_object.value
    local stop_state = stop_object.execution_state
    if type(stop_value) == "table" then stop_state = (stop_value :: {[string]: unknown}).execution_state end
    local written, write_error = file:write(request.content)
    file:close()
    if not written then return {ok = false, error = tostring(write_error or "write fixture fifo")} end
    return {ok = true, stopped = stopped, stop_state = stop_state, written = true}
end

return {handle = handle}
