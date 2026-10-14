-- SPDX-License-Identifier: MIT
local process = require("process")
local channel = require("channel")
local http = require("http_client")
local json = require("json")
local bounds = require("bounds")
local framing = require("framing")
local events = require("events")
local observer_types = require("observer_types")
local delivery = require("delivery")
local function main(input: observer_types.Input)
    local state = events.new()
    local session_id: string? = nil
    local stopping = false
    local released = false
    local operation = "startup"
    local stream: http.StreamReader? = nil
    local controls = assert(process.listen(input.topic .. ".control", {message = true}))
    local signals = assert(process.events())
    local function report(kind: string, detail: string)
        process.send(input.owner, input.topic, {kind = kind, detail = detail})
    end
    local function get(path: string): unknown
        operation = "GET " .. path
        local reply = http.get(input.endpoint .. path, {timeout = "10s", headers = {["x-opencode-directory"] = input.working_directory}})
        if reply then operation = operation .. " (HTTP " .. tostring(reply.status_code) .. ")" end
        if not reply or reply.status_code ~= 200 then error("OpenCode read failed: " .. path) end
        return json.decode(assert(reply.body))
    end
    local function post(path: string, body: unknown): unknown
        operation = "POST " .. path
        local reply = http.post(input.endpoint .. path, {timeout = "10s", headers = {["Content-Type"] = "application/json", ["x-opencode-directory"] = input.working_directory}, body = json.encode(body)})
        if reply then operation = operation .. " (HTTP " .. tostring(reply.status_code) .. ")" end
        if not reply or reply.status_code < 200 or reply.status_code >= 300 then error("OpenCode write failed: " .. path) end
        return reply.body and reply.body ~= "" and json.decode(reply.body) or nil
    end
    local admitted: {[string]: boolean} = {}
    for _, name in ipairs(input.hooks) do admitted[name] = true end
    local function deliver(row: {[string]: unknown})
        if not admitted[tostring(row.hook_event_name)] then return end
        delivery.send({
            submit = function(payload: {[string]: unknown}): {[string]: unknown}?
                local reply = http.post(input.hook_endpoint, {timeout = payload.hook_event_name == "PermissionRequest" and "240s" or "10s",
                    headers = {Authorization = "Bearer " .. input.hook_token, ["Content-Type"] = "application/json"}, body = json.encode(payload)})
                if not reply or reply.status_code < 200 or reply.status_code >= 300 then error("hook endpoint refused delivery") end
                return reply.body and reply.body ~= "" and bounds.object(json.decode(reply.body)) or nil
            end,
            permission = function(id: string, decision: {[string]: unknown}) post("/permission/" .. id .. "/reply", decision) end,
            record = function(detail: string) report("delivery_failed", detail) end,
        }, row)
    end
    local function deliver_all(rows: {{[string]: unknown}})
        for _, row in ipairs(rows) do
            if row.hook_event_name == "PermissionRequest" then coroutine.spawn(function() deliver(row) end) else deliver(row) end
        end
        if state.failure then report("mapping_failed", state.failure); state.failure = nil end
    end
    local function snapshot(id: string)
        deliver_all(events.snapshot(state, id, assert(bounds.array(get("/session/" .. id .. "/message"), 4096))))
    end
    local function reconcile()
        for _, raw in ipairs(assert(bounds.array(get("/session"), 4096))) do
            local info = bounds.object(raw)
            if info and (info.id == session_id or state.sessions[tostring(info.id)]) then
                deliver_all(events.event(state, {type = "session.updated", properties = {info = info}}))
            end
        end
        for id in pairs(state.sessions) do snapshot(id) end
        local statuses = bounds.object(get("/session/status")) or {}
        deliver_all(events.statuses(state, statuses))
        for _, raw in ipairs(assert(bounds.array(get("/permission"), 4096))) do
            local permission = bounds.object(raw)
            if permission then deliver_all(events.event(state, {type = "permission.asked", properties = permission})) end
        end
    end
    local prompt: string? = nil
    local model: string? = nil
    for i, arg in ipairs(input.argv) do
        if arg == "--session" or arg == "-s" then session_id = input.argv[i + 1]
        elseif arg == "--prompt" then prompt = input.argv[i + 1]
        elseif arg == "--model" or arg == "-m" then model = input.argv[i + 1] end
    end
    coroutine.spawn(function()
        while not stopping do
            local selected = channel.select({controls:case_receive(), signals:case_receive()})
            if not selected.ok then return end
            if selected.channel == signals or tostring(selected.value:from()) == input.owner then
                local data = selected.channel == controls and bounds.object(selected.value:payload():data()) or nil
                if data and data.command == "release" then
                    released = true
                    if prompt and session_id then
                        local body: {[string]: unknown} = {parts = {{type = "text", text = prompt}}}
                        if model then local provider, name = model:match("^([^/]+)/(.+)$"); if provider then body.model = {providerID = provider, modelID = name} end end
                        local ok = pcall(post, "/session/" .. session_id .. "/prompt_async", body)
                        if not ok then report("prompt_failed", "OpenCode initial prompt submission failed") end
                    end
                else
                    stopping = true
                    if stream then stream:close() end
                    return
                end
            end
        end
    end)
    local first = true
    local ok = pcall(function()
        while not stopping do
            operation = "GET /event"
            local response = http.get(input.endpoint .. "/event", {stream = true, timeout = "0s", headers = {["x-opencode-directory"] = input.working_directory}})
            if response then operation = operation .. " (HTTP " .. tostring(response.status_code) .. ")" end
            if not response or response.status_code ~= 200 or not response.stream then error("OpenCode event subscription failed") end
            stream = response.stream
            if first then
                if not session_id then
                    local session = assert(bounds.object(post("/session", json.decode("{}"))))
                    session_id = assert(bounds.id(session.id))
                end
                reconcile()
                process.send(input.owner, input.topic, {kind = "ready", arguments = {"attach", input.endpoint, "--dir", input.working_directory, "--session", session_id}})
                first = false
            else
                report("reconnected", "OpenCode stream reconnected; rereading session messages")
                reconcile()
            end
            local framer = framing.new()
            while not stopping do
                local chunk = stream:read(8192)
                if not chunk or chunk == "" then break end
                for _, line in ipairs(assert(framing.feed(framer, chunk))) do
                    if line:sub(1, 5) == "data:" then
                        local event = bounds.object(json.decode(line:sub(6)))
                        if event then
                            operation = "event " .. tostring(event.type)
                            local properties = bounds.object(event.properties) or {}
                            local id = bounds.id(properties.sessionID)
                            local info = bounds.object(properties.info)
                            id = id or (info and bounds.id(info.sessionID))
                            if id and state.sessions[id] then
                                local status = bounds.object(properties.status) or {}
                                if event.type == "session.idle" or (event.type == "session.status" and status.type == "idle") then
                                    snapshot(id)
                                elseif event.type == "message.updated" and info and info.role == "user" then
                                    local message_id = assert(bounds.id(info.id))
                                    deliver_all(events.snapshot(state, id, {get("/session/" .. id .. "/message/" .. message_id)}))
                                end
                            end
                            deliver_all(events.event(state, event))
                        end
                    end
                end
            end
            stream:close()
            stream = nil
            if not stopping and not released then error("OpenCode stream ended before window startup") end
        end
    end)
    if stream then stream:close() end
    deliver_all(events.finish(state))
    if not ok and not stopping then report("failed", "OpenCode observer stopped during " .. operation) end
    process.send(input.owner, input.topic, {kind = "stopped"})
    process.unlisten(controls)
end
return {main = main}
