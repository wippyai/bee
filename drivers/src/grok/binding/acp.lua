-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local json = require("json")
local canonical = require("canonical")
local events = require("events")
local driver_types = require("driver_types")
type Object = {[string]: unknown}
local M = {}
local function write(id: string, method: string, params: Object): string
    return assert(canonical.encode({jsonrpc = "2.0", id = id, method = method, params = params})) .. "\n"
end
function M.launch(raw: unknown, prepare: (unknown) -> unknown): unknown
    local input = bounds.object(raw)
    if not input or input.permission_exchange ~= true then return prepare(raw) end
    if input.effort ~= nil then return {ok = false, error = "Grok ACP has no admitted effort response route"} end
    local mode = bounds.text(input.permission_mode)
    if mode and mode ~= "default" then return {ok = false, error = "Grok ACP approval exchange requires default permission mode"} end
    local reply = assert(bounds.object(prepare(raw)))
    if reply.ok ~= true then return reply end
    local launch = assert(bounds.object(reply.launch))
    launch.argv = {"agent", "stdio"}
    launch.stdin = write("bee:init", "initialize", {protocolVersion = 1, clientCapabilities = {}, clientInfo = {name = "bee", version = "1"}})
    launch.stdin_eof = nil
    launch.session_end = "stdin_close"
    return reply
end
function M.normalize(raw: unknown): Object
    local request = bounds.object(raw)
    if not request or bounds.fields(request, {"state", "index", "envelope", "eof", "resumed", "context"}) then return {ok = false, error = "ACP request must be an exact object"} end
    if request.eof ~= nil and type(request.eof) ~= "boolean" then return {ok = false, error = "ACP eof must be a boolean"} end
    if request.context ~= nil and not bounds.object(request.context) then return {ok = false, error = "ACP context must be an object"} end
    local context = bounds.object(request.context) or {}
    local options = bounds.object(context.options) or {}
    local state: Object = {acp = true, phase = "initialize", answer = ""}
    if request.state ~= nil then
        local encoded = canonical.encode(request.state, 32768)
        local decoded = encoded and bounds.object(json.decode(encoded))
        if not decoded then return {ok = false, error = "ACP state is not an object"} end
        state = decoded
    end
    local phase = bounds.member(state.phase, {"initialize", "session", "model", "prompt", "ended"})
    local answer = bounds.text(state.answer, events.MAX_TEXT_BYTES)
    local session = state.session_id == nil and nil or bounds.id(state.session_id)
    local index = bounds.count(request.index)
    if not phase or not answer or not index or (state.session_id ~= nil and not session)
        or bounds.fields(state, {"acp", "phase", "answer", "session_id", "terminal"}) then return {ok = false, error = "ACP state is invalid"} end
    if state.acp ~= true or ((phase == "prompt" or phase == "model") and not session) then return {ok = false, error = "ACP state has an invalid phase identity"} end
    if state.terminal ~= nil then
        local decoded = driver_types.decode_terminal(state.terminal)
        if not decoded or phase ~= "ended" then return {ok = false, error = "ACP terminal checkpoint is invalid"} end
    elseif phase == "ended" then return {ok = false, error = "ACP terminal checkpoint is absent"} end
    local observations: {Object} = {}
    local writes: {string} = {}
    local terminal: Object? = nil
    local function finish(outcome: string, reason: string?): Object
        terminal = {outcome = outcome, answer = answer ~= "" and answer or nil, resume_ref = session,
            error = reason and {code = "acp_terminal", message = reason, retryable = false} or nil}
        state.phase = "ended"; state.terminal = terminal
        return {ok = true, state = state, observations = observations, writes = writes, terminal = terminal}
    end
    if request.eof == true then
        if phase == "ended" then return {ok = true, state = state, observations = {}, terminal = state.terminal} end
        return finish("uncertain", "Grok ACP ended without its prompt result")
    end
    local envelope = bounds.object(request.envelope)
    if not envelope or envelope.jsonrpc ~= "2.0" then return {ok = false, error = "ACP envelope must be a JSON-RPC 2.0 object"} end
    if phase == "ended" then return {ok = true, state = state, observations = {events.notice("grok-acp:" .. tostring(index), "warning", "after_terminal", "ACP envelope after prompt completion")}} end
    local result = bounds.object(envelope.result)
    if envelope.error ~= nil and (envelope.id == "bee:init" or envelope.id == "bee:session" or envelope.id == "bee:prompt" or envelope.id == "bee:model") then
        return finish("failed", "Grok ACP refused " .. tostring(envelope.id))
    end
    if envelope.id == "bee:init" and phase == "initialize" then
        local meta = result and bounds.object(result._meta)
        local cwd = meta and bounds.text(meta.currentWorkingDirectory, 4096)
        if not result or result.protocolVersion ~= 1 or not cwd or cwd:sub(1, 1) ~= "/" then return {ok = false, error = "Grok ACP initialization omitted its working directory or version"} end
        local params: Object = {cwd = cwd, mcpServers = json.decode("[]"), _meta = {authMethodId = meta and bounds.id(meta.defaultAuthMethodId)}}
        local mode = bounds.text(options.permission_mode) or "default"
        if mode ~= "default" then return {ok = false, error = "Grok ACP approval exchange requires default permission mode"} end
        local resume = bounds.id(context.resume_ref)
        local method = resume and "session/load" or "session/new"
        if resume then params.sessionId = resume end
        writes[1] = write("bee:session", method, params)
        state.phase = "session"
    elseif envelope.id == "bee:session" and phase == "session" then
        session = result and bounds.id(result.sessionId) or bounds.id(context.resume_ref)
        local brief = bounds.text(context.brief, 32768)
        if not session or not brief then return {ok = false, error = "Grok ACP session omitted its identity or prompt"} end
        state.session_id = session
        local model = bounds.id(options.model)
        if model then
            state.phase = "model"
            writes[1] = write("bee:model", "session/set_model", {sessionId = session, modelId = model})
            observations = {events.session("grok-acp:session", "started", session)}
        else
            state.phase = "prompt"
            observations = {events.session("grok-acp:session", "started", session), events.turn("grok-acp:turn", "started", nil, nil)}
            writes[1] = write("bee:prompt", "session/prompt", {sessionId = session, prompt = {{type = "text", text = brief}}})
        end
    elseif envelope.id == "bee:model" and phase == "model" then
        local brief = bounds.text(context.brief, 32768)
        if not result or not brief then return {ok = false, error = "Grok ACP model response or prompt is invalid"} end
        state.phase = "prompt"
        observations = {events.turn("grok-acp:turn", "started", nil, nil)}
        writes[1] = write("bee:prompt", "session/prompt", {sessionId = session, prompt = {{type = "text", text = brief}}})
    elseif envelope.method == "session/request_permission" then
        local params = bounds.object(envelope.params)
        local tool = params and bounds.object(params.toolCall)
        local choices = params and bounds.array(params.options, 8)
        local id = bounds.count(envelope.id)
        local input = tool and bounds.object(tool.rawInput)
        local meta = tool and bounds.object(tool._meta)
        local definition = meta and bounds.object(meta["x.ai/tool"])
        local name = definition and bounds.id(definition.name)
        local allow, deny = false, false
        if choices then for _, raw_choice in ipairs(choices) do
            local choice = bounds.object(raw_choice)
            if choice and choice.kind == "allow_once" and choice.optionId == "allow-once" then allow = true end
            if choice and choice.kind == "reject_once" and choice.optionId == "reject-once" then deny = true end
        end end
        if phase ~= "prompt" or not params or params.sessionId ~= session or not id or not input or not name or not allow or not deny then
            return {ok = false, error = "Grok ACP permission request has an unsupported identity or response option"}
        end
        observations[1] = {type = "extension", event_key = "grok-acp:permission:" .. tostring(index), data = {type = "extension",
            event_name = "grok.permission", event_revision = "1", payload_json = canonical.encode({request_id = tostring(id), tool_name = name,
                tool_input = input, prompt = tool and tool.title})}}
    elseif envelope.method == "session/update" and phase == "prompt" then
        local params = bounds.object(envelope.params)
        local update = params and bounds.object(params.update)
        if not params or params.sessionId ~= session then return {ok = false, error = "Grok ACP update belongs to a different session"} end
        if update and update.sessionUpdate == "agent_message_chunk" then
            local content = bounds.object(update.content)
            local text = content and content.type == "text" and bounds.text(content.text, events.MAX_TEXT_BYTES)
            if not text or #answer + #text > events.MAX_TEXT_BYTES then return {ok = false, error = "Grok ACP answer exceeds its bound"} end
            state.answer = answer .. text
            observations = events.text("grok-acp:text:" .. tostring(index), "answer", "append", text, "answer")
        end
    elseif envelope.id == "bee:prompt" and phase == "prompt" then
        local reason = result and bounds.text(result.stopReason)
        if reason == "end_turn" then return finish("succeeded", nil) end
        if reason == "cancelled" then return finish("cancelled", nil) end
        return finish("uncertain", "Grok ACP prompt ended with " .. tostring(reason))
    end
    return {ok = true, state = state, observations = observations, writes = writes, terminal = terminal}
end
return M
