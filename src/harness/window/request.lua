-- MIT. Private broker-to-managed-window launch envelope.
--
-- The broker application boundary transports strings, so this decoder accepts
-- exactly one JSON object and constructs the launch-admission request from the
-- authenticated workspace in the broker launch.  It deliberately offers no
-- caller-selected environment or transport: this actor only owns native
-- window execution.
local json = require("json")
local bounds = require("bounds")

local M = {}
M.MAX_ARGUMENT_BYTES = 16384

type Request = {
    request_id: string,
    definition_ref: string,
    workspace_id: string,
    brief: string,
    mode: "window",
    workdir: string?,
    thread_id: string?,
}

function M.decode(arguments: {string}, workspace_id: string): (Request?, string?)
    if #arguments ~= 1 then return nil, "managed window needs exactly one launch request" end
    local encoded = arguments[1]
    if #encoded > M.MAX_ARGUMENT_BYTES then return nil, "managed window launch request is too large" end
    local value: unknown, decode_error = json.decode(encoded)
    if decode_error then return nil, "managed window launch request is not JSON" end
    local object = bounds.object(value)
    if not object then return nil, "managed window launch request must be an object" end
    local unknown_field = bounds.fields(object, {"request_id", "definition_ref", "brief", "workdir", "thread_id"})
    if unknown_field then return nil, unknown_field end
    local request_id = bounds.id(object.request_id)
    local definition_ref = bounds.id(object.definition_ref)
    local brief = bounds.text(object.brief, M.MAX_ARGUMENT_BYTES)
    if not request_id then return nil, "request_id is not an identifier" end
    if not definition_ref then return nil, "definition_ref is not an identifier" end
    if not brief then return nil, "brief must be bounded text" end
    local workdir: string? = nil
    if object.workdir ~= nil then
        workdir = bounds.id(object.workdir)
        if not workdir then return nil, "workdir is not an identifier" end
    end
    local thread_id: string? = nil
    if object.thread_id ~= nil then
        thread_id = bounds.id(object.thread_id)
        if not thread_id then return nil, "thread_id is not an identifier" end
    end
    return {request_id = request_id, definition_ref = definition_ref, workspace_id = workspace_id,
        brief = brief, mode = "window", workdir = workdir, thread_id = thread_id}, nil
end

return M
