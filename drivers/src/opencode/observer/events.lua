-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local M = {}
M.HOOKS = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Stop", "StopFailure", "SessionEnd"}
type Object = {[string]: unknown}
type Message = {info: Object, parts: {[string]: Object}}
type Session = {messages: {[string]: Message}, order: {string}, prompts: {[string]: boolean}, permissions: {[string]: boolean}, tools: {[string]: boolean}, active: string?, stopped: {[string]: boolean}, ended: boolean, failed: boolean}
type State = {sessions: {[string]: Session}, failure: string?}
function M.new(): State return {sessions = {}} end
local function text(message: Message): string
    local parts: {string} = {}
    local ids: {string} = {}
    for id in pairs(message.parts) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local part = message.parts[id]
        if part.type == "text" and part.synthetic ~= true and part.ignored ~= true and type(part.text) == "string" then parts[#parts + 1] = part.text end
    end
    return table.concat(parts, "\n")
end
local function record(event: string, session: string, fields: Object?): Object
    local row: Object = {hook_event_name = event, session_id = session}
    for key, value in pairs(fields or {}) do row[key] = value end
    return row
end
local function session_start(state: State, info: Object): {Object}
    local id = bounds.id(info.id)
    if not id or info.parentID ~= nil or state.sessions[id] then return {} end
    state.sessions[id] = {messages = {}, order = {}, prompts = {}, permissions = {}, tools = {}, stopped = {}, ended = false, failed = false}
    return {record("SessionStart", id, {source = "startup"})}
end
local function message_update(session: Session, info: Object)
    local id = bounds.id(info.id)
    if not id then return end
    if not session.messages[id] then
        local created: Message = {info = info, parts = {}}
        session.messages[id] = created
        session.order[#session.order + 1] = id
    end
    session.messages[id].info = info
end
local function prompt(session: Session, id: string, session_id: string): {Object}
    local message = session.messages[id]
    if not message or message.info.role ~= "user" or session.prompts[id] then return {} end
    local content = text(message)
    if content == "" then return {} end
    session.prompts[id] = true
    session.active = id
    session.failed = false
    return {record("UserPromptSubmit", session_id, {prompt_id = id, prompt = content})}
end
local function part_update(session: Session, part: Object, session_id: string): {Object}
    local message_id = bounds.id(part.messageID)
    local part_id = bounds.id(part.id)
    if not message_id or not part_id then return {} end
    local message = session.messages[message_id]
    if part.type ~= "tool" then
        if message then message.parts[part_id] = part end
        return prompt(session, message_id, session_id)
    end
    local tool = bounds.id(part.tool)
    local call = bounds.id(part.callID)
    local status = bounds.object(part.state)
    if not tool or not call or not status then return {} end
    local key_base = message_id .. ":" .. call .. ":"
    if session.tools[key_base .. "PostToolUse"] or session.tools[key_base .. "PostToolUseFailure"] then return {} end
    if message then message.parts[part_id] = part end
    local name: string? = nil
    if status.status == "running" then name = "PreToolUse"
    elseif status.status == "completed" then name = "PostToolUse"
    elseif status.status == "error" then name = "PostToolUseFailure" end
    if not name then return {} end
    local key = key_base .. name
    if session.tools[key] then return {} end
    session.tools[key] = true
    return {record(name, session_id, {tool_name = tool, tool_use_id = call, tool_input = status.input or {}, tool_response = status.output, error = status.error})}
end
local function stop(state: State, session: Session, id: string): {Object}
    local active = session.active
    if not active or session.stopped[active] then return {} end
    for i = #session.order, 1, -1 do
        local message = session.messages[session.order[i]]
        local info = message.info
        if info.role == "assistant" and info.parentID == active then
            if info.error ~= nil then session.failed = true end
            local time = bounds.object(info.time)
            if not session.failed and info.finish == "stop" and time and type(time.completed) == "number" then
                session.stopped[active] = true
                return {record("Stop", id, {prompt_id = active, last_assistant_message = text(message), stop_hook_active = false})}
            end
        end
    end
    if session.failed then
        session.stopped[active] = true
        return {record("StopFailure", id, {prompt_id = active, error = "OpenCode turn failed"})}
    end
    state.failure = "OpenCode idle omitted a completed reply"
    return {}
end
function M.snapshot(state: State, id: string, messages: {unknown}): {Object}
    local session: Session? = state.sessions[id]
    if not session then return {} end
    local rows: {Object} = {}
    for _, raw in ipairs(messages) do
        local message = bounds.object(raw)
        local info = message and bounds.object(message.info)
        if info and message then
            message_update(session, info)
            local parts = bounds.array(message.parts, 4096) or {}
            for _, raw_part in ipairs(parts) do
                local part = bounds.object(raw_part)
                if part then
                    for _, row in ipairs(part_update(session, part, id)) do rows[#rows + 1] = row end
                end
            end
        end
    end
    return rows
end
function M.event(state: State, event: Object): {Object}
    local properties = bounds.object(event.properties) or {}
    local info = bounds.object(properties.info)
    if event.type == "session.created" or event.type == "session.updated" then return info and session_start(state, info) or {} end
    local id = bounds.id(properties.sessionID) or (info and bounds.id(info.sessionID))
    local part = bounds.object(properties.part)
    id = id or (part and bounds.id(part.sessionID))
    if event.type == "session.deleted" then id = info and bounds.id(info.id) end
    if not id or not state.sessions[id] then return {} end
    local session: Session = state.sessions[id]
    if event.type == "message.updated" and info then message_update(session, info); return prompt(session, tostring(info.id), id) end
    if event.type == "message.part.updated" and part then return part_update(session, part, id) end
    if event.type == "permission.asked" then
        local permission_id = bounds.id(properties.id)
        if not permission_id or session.permissions[permission_id] then return {} end
        session.permissions[permission_id] = true
        local tool = bounds.object(properties.tool) or {}
        local input = properties.metadata or {}
        local name = properties.permission
        for _, message in pairs(session.messages) do
            for _, known in pairs(message.parts) do
                if known.type == "tool" and known.callID == tool.callID then
                    local status = bounds.object(known.state)
                    if status then input = status.input or input; name = known.tool end
                end
            end
        end
        return {record("PermissionRequest", id, {tool_name = name, tool_use_id = tool.callID or properties.id, tool_input = input, permission_id = permission_id})}
    end
    if event.type == "session.error" then session.failed = true end
    if event.type == "session.idle" then return stop(state, session, id) end
    if event.type == "session.status" and (bounds.object(properties.status) or {}).type == "idle" then return stop(state, session, id) end
    if event.type == "session.deleted" and not session.ended then session.ended = true; return {record("SessionEnd", id, {reason = "clear"})} end
    return {}
end
function M.statuses(state: State, statuses: Object): {Object}
    local rows: {Object} = {}
    for id in pairs(state.sessions) do
        for _, row in ipairs(M.event(state, {type = "session.status", properties = {sessionID = id, status = statuses[id] or {type = "idle"}}})) do rows[#rows + 1] = row end
    end
    return rows
end
function M.finish(state: State): {Object}
    local rows: {Object} = {}
    for id, session in pairs(state.sessions) do
        if not session.ended then session.ended = true; rows[#rows + 1] = record("SessionEnd", id, {reason = "prompt_input_exit"}) end
    end
    return rows
end
return M
