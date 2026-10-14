-- SPDX-License-Identifier: MIT
local registry = require("registry")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local bounds = require("bounds")
local resolver = require("resolver")
local resources = require("resources")
local quote = require("quote")
local types = require("types")
local exec = require("exec")
local observer_protocol = require("observer_protocol")
local M = {}
type Request = {binding_ref: string, profile_id: string, profile_digest: string, action_id: string, launch: {executable: string}, gateway: types.Gateway?}
type Declaration = {process: string, server_arguments: {string}, endpoint_pattern: string}
type Handle = {arguments: {string}, release: () -> (), stop: () -> ()}
type IO = {server: ({string}) -> (string?, (() -> ())?), spawn: (string) -> boolean, ready: () -> {string}?, release: () -> (), stop: () -> (), record: (string, string) -> ()}
function M.readiness(receive: () -> {[string]: unknown}?, record: (string, string) -> ()): {string}?
    while true do
        local reply = receive()
        if not reply then return nil end
        if reply.kind == "ready" then
            local values = bounds.array(reply.arguments, 128)
            if not values then return nil end
            local arguments: {string} = {}
            for _, value in ipairs(values) do
                local argument = bounds.text(value, 32768)
                if not argument then return nil end
                arguments[#arguments + 1] = argument
            end
            return arguments
        end
        record("observer." .. tostring(reply.kind), bounds.text(reply.detail, 512) or "observer event")
        if reply.kind == "failed" or reply.kind == "stopped" then return nil end
    end
end
function M.lifecycle(io: IO, declaration: Declaration): Handle?
    local server_ok, endpoint, close_server = pcall(function() return io.server(declaration.server_arguments) end)
    if not server_ok or not endpoint or not close_server then io.record("observer.failed", "local server did not report an endpoint"); return nil end
    local spawned, spawn_ok = pcall(function() return io.spawn(endpoint) end)
    if not spawned or not spawn_ok then close_server(); io.record("observer.failed", "observer could not start"); return nil end
    local ready_ok, arguments = pcall(function() return io.ready() end)
    if not ready_ok or not arguments then pcall(io.stop); close_server(); io.record("observer.failed", "observer did not become ready"); return nil end
    io.record("observer.ready", "event subscription ready at " .. endpoint)
    local stopped = false
    return {arguments = arguments, release = io.release, stop = function()
        if stopped then return end
        stopped = true
        local stopped_ok = pcall(function() io.stop() end)
        local closed_ok = pcall(function() close_server() end)
        if not stopped_ok or not closed_ok then io.record("observer.stop_failed", "observer or local server shutdown failed") end
        io.record("observer.stopped", "window observer and local server stopped")
    end}
end
function M.discover(request: Request): (Declaration?, string?)
    local pinned = assert(registry.snapshot())
    local profile, err = resolver.profile(pinned, request.binding_ref, request.profile_id)
    if not profile then return nil, err end
    if not profile.observer then return nil, nil end
    local binding = assert(pinned:get(request.binding_ref))
    local binding_meta = assert(bounds.object(binding.meta))
    local profiles_ref = assert(bounds.id(binding_meta.profiles_ref))
    local profile_entry = assert(pinned:get(profiles_ref))
    local profile_data = assert(bounds.object(profile_entry.data))
    local measurements, measurement_error = observer_protocol.collect(pinned, request.binding_ref, profile_data)
    if not measurements then return nil, measurement_error end
    local measured_digest = observer_protocol.digest(profile_data, measurements)
    if measured_digest ~= request.profile_digest then return nil, "window observer changed since admission" end
    local measurement = measurements[request.profile_id]
    local candidate = measurement and bounds.object(measurement.declaration)
    if not candidate then return nil, "observer declaration is unavailable" end
    local data = bounds.object(candidate.data)
    if candidate.kind ~= "registry.entry" or not data then return nil, "observer declaration is invalid" end
    local target = bounds.id(data.process)
    local args = bounds.array(data.server_arguments, 32)
    local pattern = bounds.text(data.endpoint_pattern, 128)
    if not target or not args or not pattern then return nil, "observer declaration requires a process, server arguments and endpoint pattern" end
    local entry = pinned:get(target)
    if not entry or entry.kind ~= "process.lua" then return nil, "observer process unavailable" end
    local arguments: {string} = {}
    for _, raw in ipairs(args) do
        local argument = bounds.text(raw, 1024)
        if not argument then return nil, "observer server argument is invalid" end
        arguments[#arguments + 1] = argument
    end
    return {process = target, server_arguments = arguments, endpoint_pattern = pattern}, nil
end
function M.start(request: Request, executor: exec.Executor, argv: {string}, working_directory: string, environment: {[string]: string}, record: (string, string) -> ()): Handle?
    local declaration, discovery_error = M.discover(request)
    if discovery_error then record("observer.failed", discovery_error); return nil end
    if not declaration then return nil end
    local gateway = request.gateway
    local token = gateway and gateway.hook_destination and environment[gateway.hook_destination]
    if not gateway or not token then record("observer.failed", "observer has no admitted hook delivery authority"); return nil end
    local topic = "bee.window.observer." .. assert(uuid.v4())
    local replies = assert(process.listen(topic, {message = true}))
    local child: string? = nil
    local closed = false
    local receiving = false
    local stopped_signal = channel.new(1)
    local function receive(timeout: string): {[string]: unknown}?
        local selected = channel.select({replies:case_receive(), time.after(timeout):case_receive()})
        if selected.ok and selected.channel == replies and child and tostring(selected.value:from()) == child then return bounds.object(selected.value:payload():data()) end
        return nil
    end
    local io: IO = {
        record = record,
        server = function(arguments: {string}): (string?, (() -> ())?)
            local command = {request.launch.executable}
            for _, arg in ipairs(arguments) do command[#command + 1] = arg end
            local server = executor:exec(quote.line(command), {work_dir = working_directory, env = environment, process_group = true})
            if not server then return nil, nil end
            local stdout = server:stdout_stream()
            local stderr = server:stderr_stream()
            if not server:start() then server:close(); return nil, nil end
            local discovered = channel.new(1)
            coroutine.spawn(function()
                local content = ""
                while #content < 16384 do
                    local chunk = stdout:read(1024)
                    if not chunk or chunk == "" then break end
                    content = content .. chunk
                    local endpoint = content:match(declaration.endpoint_pattern)
                    if endpoint then discovered:send(endpoint); return end
                end
                discovered:send(false)
            end)
            coroutine.spawn(function() while true do local chunk = stderr:read(4096); if not chunk or chunk == "" then return end end end)
            local selected = channel.select({discovered:case_receive(), time.after("20s"):case_receive()})
            local endpoint = selected.ok and selected.channel == discovered and bounds.text(selected.value, 128) or nil
            local function close() server:close(); stdout:close(); stderr:close() end
            if not endpoint then close(); return nil, nil end
            return endpoint, close
        end,
        spawn = function(endpoint: string): boolean
            local host = resources.runner_host()
            if not host then return false end
            local pid = process.spawn(declaration.process, host, {endpoint = endpoint, hook_endpoint = "http://" .. gateway.endpoint .. "/hook/" .. request.action_id,
                hook_token = token, hooks = gateway.hooks, working_directory = working_directory, argv = argv, owner = process.pid(), topic = topic})
            child = pid and tostring(pid) or nil
            return child ~= nil
        end,
        ready = function(): {string}?
            local deadline = assert(time.after("20s"))
            return M.readiness(function(): {[string]: unknown}?
                local selected = channel.select({replies:case_receive(), deadline:case_receive()})
                if not selected.ok or selected.channel ~= replies then return nil end
                if child and tostring(selected.value:from()) == child then return bounds.object(selected.value:payload():data()) end
                return {kind = "ignored", detail = "unrecognized observer sender"}
            end, record)
        end,
        release = function()
            if child then process.send(child, topic .. ".control", {command = "release"}) end
            receiving = true
            coroutine.spawn(function()
                while not closed do
                    local message, ok = replies:receive()
                    if not ok or closed then return end
                    if child and tostring(message:from()) == child then
                        local data = bounds.object(message:payload():data())
                        if data and data.kind == "stopped" then stopped_signal:send(true); return end
                        if data then record("observer." .. tostring(data.kind), bounds.text(data.detail, 512) or "observer event") end
                    end
                end
            end)
        end,
        stop = function()
            if child then
                process.send(child, topic .. ".control", {command = "stop"})
                local stopped = false
                if receiving then
                    local selected = channel.select({stopped_signal:case_receive(), time.after("3s"):case_receive()})
                    stopped = selected.ok and selected.channel == stopped_signal
                else
                    local reply = receive("3s")
                    stopped = reply ~= nil and reply.kind == "stopped"
                end
                if not stopped then process.cancel(child, "window observer shutdown deadline"); record("observer.stop_failed", "observer did not acknowledge shutdown") end
            end
            closed = true
            process.unlisten(replies)
        end,
    }
    local handle = M.lifecycle(io, declaration)
    if not handle then process.unlisten(replies) end
    return handle
end
return M
