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
    expected_plan_digest: string?,
    saved_profile_id: string?,
    saved_profile_revision: integer?,
}

function M.decode(arguments: {string}, workspace_id: string): (Request?, string?)
    if #arguments ~= 1 then return nil, "managed window needs exactly one launch request" end
    local encoded = arguments[1]
    if #encoded > M.MAX_ARGUMENT_BYTES then return nil, "managed window launch request is too large" end
    local value: unknown, decode_error = json.decode(encoded)
    if decode_error then return nil, "managed window launch request is not JSON" end
    local object = bounds.object(value)
    if not object then return nil, "managed window launch request must be an object" end
    local unknown_field = bounds.fields(object, {"request_id", "definition_ref", "brief", "workdir", "thread_id", "expected_plan_digest", "saved_profile_id", "saved_profile_revision"})
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
    local saved_id, saved_revision = bounds.id(object.saved_profile_id), bounds.count(object.saved_profile_revision)
    if object.saved_profile_id ~= nil or object.saved_profile_revision ~= nil then
        if not saved_id or not saved_revision or saved_revision < 1 then return nil, "saved profile needs identity and positive revision" end
        if object.expected_plan_digest == nil then return nil, "saved profile needs the selected launch plan digest" end
    end
    local expected_plan_digest: string? = nil
    if object.expected_plan_digest ~= nil then
        local digest = bounds.text(object.expected_plan_digest, 64)
        if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
            return nil, "expected_plan_digest must be a lowercase SHA-256 hex digest"
        end
        expected_plan_digest = digest
    end
    return {request_id = request_id, definition_ref = definition_ref, workspace_id = workspace_id, expected_plan_digest = expected_plan_digest,
        saved_profile_id = saved_id, saved_profile_revision = saved_revision,
        brief = brief, mode = "window", workdir = workdir, thread_id = thread_id}, nil
end

return M
