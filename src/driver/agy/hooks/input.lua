-- MIT. Reads an Agy hook's stdin as the Bee hook payload. Tool gates map to
-- tool fields; PreInvocation and Stop carry no prompt or answer, so the turn
-- is read from the conversation transcript, from its end back to the latest
-- prompt, through the placement that owns the session's HOME. The reply is
-- {payload}, {skip = true} for an invocation that holds no new prompt, or
-- {error}.
local funcs = require("funcs")
local json = require("json")
local bounds = require("bounds")

local M = {}
type Object = {[string]: unknown}
type Chunk = (integer, integer) -> ({size: integer, data: string}?, string?)
type Reply = {payload: Object?, skip: boolean?, error: string?}

M.HOOK_FILE = "bee.placement.native.binding:hook_file"
M.TRANSCRIPT = ".system_generated/logs/transcript_full.jsonl"
M.MAX_TEXT_BYTES = 24576
M.MAX_LINE_BYTES = 1048576
M.MAX_TURN_BYTES = 33554432
M.CHUNK_BYTES = 65536

local function fail(message: string): Reply return {error = message} end

local function segment(value: unknown, limit: integer): string?
    if type(value) ~= "string" or #value == 0 or #value > limit then return nil end
    if value:sub(1, 1) == "." or value:find("[^A-Za-z0-9_.:-]") then return nil end
    return value
end

local function integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= math.floor(value) then return nil end
    return math.floor(value)
end

local function tool_gate(hook: Object, event: string, conversation: string): Reply
    local call = bounds.object(hook.toolCall)
    local name = call and segment(call.name, 128)
    local args = call and bounds.object(call.args)
    if not name or not args then return fail("invalid Agy permission request") end
    local payload: Object = {session_id = conversation, tool_name = name, tool_input = args, hook_event_name = event}
    if event == "PreToolUse" then
        local step = integer(hook.stepIdx)
        if not step or step < 0 then return fail("invalid Agy tool occurrence") end
        payload.tool_call_id = tostring(step)
    end
    return {payload = payload}
end

-- lines hands each line of the file to visit, last line first, until visit
-- stops or the file begins. One turn spans at most MAX_TURN_BYTES and one
-- record MAX_LINE_BYTES.
local function lines(read_chunk: Chunk, size: integer, visit: (string) -> (boolean, string?)): string?
    local pending = ""
    local offset = size
    while true do
        while true do
            local cut = pending:find("\n[^\n]*$")
            if not cut then break end
            local line = pending:sub(cut + 1)
            pending = pending:sub(1, cut - 1)
            if line:match("%S") then
                local more, visit_error = visit(line)
                if visit_error or not more then return visit_error end
            end
        end
        if #pending > M.MAX_LINE_BYTES then return "Agy transcript record exceeds its bound" end
        if offset == 0 then
            if not pending:match("%S") then return nil end
            local _, visit_error = visit(pending)
            return visit_error
        end
        if size - offset >= M.MAX_TURN_BYTES then return "Agy turn exceeds its transcript bound" end
        local read = math.min(M.CHUNK_BYTES, offset)
        offset = offset - read
        local chunk, read_error = read_chunk(offset, read)
        if not chunk or #chunk.data ~= read then return "unreadable Agy transcript: " .. tostring(read_error) end
        pending = chunk.data .. pending
    end
end

-- reader reads the transcript through the session's placement, which admits
-- only the directories the Agy descriptor declares in hook_files.
local function reader(attempt_id: string, path: string): Chunk
    return function(offset: integer, length: integer): ({size: integer, data: string}?, string?)
        local reply, call_error = funcs.call(M.HOOK_FILE, {attempt_id = attempt_id, path = path, offset = offset, length = length})
        local result = bounds.object(reply)
        if call_error or not result then return nil, tostring(call_error) end
        if result.ok ~= true then return nil, tostring((bounds.object(result.error) or {}).message) end
        local value = bounds.object(result.value) or {}
        local size = bounds.count(value.size)
        if not size or type(value.data) ~= "string" then return nil, "hook file reply is malformed" end
        return {size = size, data = value.data}, nil
    end
end

local function transcript_turn(hook: Object, event: string, conversation: string, attempt_id: string): Reply
    if event == "UserPromptSubmit" and hook.invocationNum ~= nil and hook.invocationNum ~= 0 then return {skip = true} end
    if event == "Stop" and (hook.fullyIdle ~= true or (hook.error ~= nil and hook.error ~= "")) then return fail("Agy turn did not complete") end
    if event ~= "UserPromptSubmit" and event ~= "Stop" then return fail("unsupported Agy transcript event") end
    local artifact = type(hook.artifactDirectoryPath) == "string" and hook.artifactDirectoryPath or ""
    if artifact:sub(1, 1) ~= "/" or artifact:find("//", 1, true) or artifact:find("/%.%.?/") or artifact:find("/%.%.?$")
        or artifact:match("[^/]+$") ~= conversation or hook.transcriptPath ~= artifact .. "/" .. M.TRANSCRIPT then
        return fail("invalid Agy transcript path")
    end
    local read_chunk = reader(attempt_id, artifact .. "/" .. M.TRANSCRIPT)
    local info, info_error = read_chunk(0, 0)
    if not info then return fail("Agy transcript unavailable: " .. tostring(info_error)) end
    local initial = integer(hook.initialNumSteps) or 0
    local prompt, answer = "", ""
    local prompt_index = 0
    local found, taken, answered = false, false, false
    local read_error = lines(read_chunk, info.size, function(line: string): (boolean, string?)
        local step = bounds.object((json.decode(line)))
        if not step then return false, "invalid Agy transcript record" end
        local index = integer(step.step_index) or 0
        if event == "UserPromptSubmit" and index >= initial then return true, nil end
        if step.type == "USER_INPUT" and step.source == "USER_EXPLICIT" and step.status == "DONE" then
            prompt, prompt_index, found = type(step.content) == "string" and step.content or "", index, true
            return false, nil
        end
        if step.source == "MODEL" then
            if event == "UserPromptSubmit" then
                taken = true
                return false, nil
            end
            if step.type == "PLANNER_RESPONSE" and step.status == "DONE" and not answered then
                answer, answered = type(step.content) == "string" and step.content or "", true
            end
        end
        return true, nil
    end)
    if read_error then return fail(read_error) end
    if taken then return {skip = true} end
    if found then
        local start = "<USER_REQUEST>\n"
        if prompt:sub(1, #start) == start then
            local ending = prompt:find("\n</USER_REQUEST>", #start + 1, true)
            if not ending then return fail("invalid Agy prompt record") end
            prompt = prompt:sub(#start + 1, ending - 1)
        end
    end
    if not found or prompt == "" or #prompt > M.MAX_TEXT_BYTES then return fail("Agy prompt is unavailable or exceeds its bound") end
    local payload: Object = {session_id = conversation, prompt_id = tostring(prompt_index), hook_event_name = event}
    if event == "UserPromptSubmit" then
        payload.prompt = prompt
    else
        if answer == "" or #answer > M.MAX_TEXT_BYTES then return fail("Agy answer is unavailable or exceeds its bound") end
        payload.last_assistant_message = answer
    end
    return {payload = payload}
end

function M.read(raw: unknown): Reply
    local request = bounds.object(raw)
    local event = request and bounds.id(request.event)
    local body = request and request.body
    local attempt_id = request and bounds.id(request.attempt_id)
    if not event or type(body) ~= "string" or not attempt_id then return fail("Agy hook input names its event, body and attempt") end
    local hook = bounds.object((json.decode(body)))
    local conversation = hook and segment(hook.conversationId, 160)
    if not hook or not conversation then return fail("invalid Agy hook identity") end
    if event == "PermissionRequest" or event == "PreToolUse" then return tool_gate(hook, event, conversation) end
    return transcript_turn(hook, event, conversation, attempt_id)
end

return M
