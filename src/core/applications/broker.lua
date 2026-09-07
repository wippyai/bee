-- Instance lifecycle and terminal capability owner. No bundled-app identities.
local process = require("process")
local security = require("security")
local channel = require("channel")
local tty = require("tty")
local uuid = require("uuid")
local time = require("time")
local registry = require("registry")
local ctx = require("ctx")
local contract = require("contract")
local catalog = require("catalog")
local lifecycle = require("lifecycle")
local appearance = require("appearance")
type Waiter = {request_id: string, recipient: string, control: boolean}
type Checkpoint = {request_id: string, pid: string, deadline: number}
type Instance = {view_id: string, instance_id: string, execution_pid: string, view: tty.Viewport,
    descriptor: contract.Descriptor, binding: contract.Binding, mount: string, launch_token: string,
    state: lifecycle.State, open_request: string, opened: boolean, ready_received: boolean, resume_state: string, waiters: {Waiter}, attempts: integer}
local function now(): number return time.now():unix_nano() / 1000000000 end
local function main(owner: string, initial_preferences: unknown)
    local bootstrap: unknown = ctx.get("bee.workspace_owner")
    if bootstrap ~= owner or owner == "" then error("Untrusted broker bootstrap") end
    local requests = assert(process.listen("bee.app.request", {message = true}))
    local app_ready = assert(process.listen("bee.application.ready", {message = true}))
    local appearance_requests = assert(process.listen("bee.appearance.request", {message = true}))
    local appearance_states = assert(process.listen("bee.appearance.state", {message = true}))
    local controls = assert(process.listen("bee.application.control", {message = true}))
    local checkpoints = assert(process.listen("bee.application.checkpoint", {message = true}))
    local persisted = assert(process.listen("bee.application.persisted", {message = true}))
    local checkpoint_waiters: {[string]: Checkpoint} = {}
    local events = assert(process.events())
    assert(process.monitor(owner))
    local ticker = assert(time.ticker("100ms"))
    local ticks = ticker:channel()
    local bindings = catalog.bindings()
    local instances: {[string]: Instance} = {}
    local pending: {[string]: boolean} = {}
    local fingerprints: {[string]: string} = {}
    local completed: {[string]: contract.Reply} = {}
    local completed_order: {string} = {}
    local recipient = ""
    local preferences = appearance.decode(initial_preferences) or appearance.defaults()
    local appearance_revision = 0
    local preference_waiters: {[string]: Waiter} = {}
    local scope_cache: {[string]: security.Scope} = {}
    local base, base_error = security.policy("bee:base_app_policy")
    if base_error then error(tostring(base_error)) end
    local boundary, boundary_error = security.policy("bee:app_boundary_policy")
    if boundary_error then error(tostring(boundary_error)) end
    local private_core, private_error = security.policy("bee:core_spawn_boundary")
    if private_error then error(tostring(private_error)) end
    local storage_boundary, storage_error = security.policy("bee:workspace_storage_boundary")
    if storage_error then error(tostring(storage_error)) end
    for _, binding in ipairs(bindings) do
        local policies: {security.Policy} = {base, boundary, private_core, storage_boundary}
        for _, name in ipairs(binding.policies) do
            local policy, err = security.policy(name)
            if err then error(tostring(err)) end
            policies[#policies + 1] = policy
        end
        scope_cache[binding.definition_id] = security.new_scope(policies)
    end
    local function emit(reply: contract.Reply, remember: boolean?)
        if remember and reply.request_id ~= "" then
            pending[reply.request_id] = nil
            if not completed[reply.request_id] then completed_order[#completed_order + 1] = reply.request_id end
            completed[reply.request_id] = reply
            if #completed_order > 128 then
                local oldest = table.remove(completed_order, 1)
                completed[oldest] = nil; fingerprints[oldest] = nil
            end
        end
        assert(process.send(owner, "bee.app.reply", reply))
    end
    local function identified(item: Instance, op: contract.ReplyOp, request_id: string, code: string?, message: string?): contract.Reply
        local reply = contract.reply(request_id, op, code, message)
        reply.id, reply.instance_id, reply.title, reply.mount = item.view_id, item.instance_id, item.descriptor.title, item.mount
        reply.icon = item.descriptor.icon
        reply.definition_id, reply.resume_schema = item.descriptor.definition_id, item.descriptor.resume_schema
        reply.restart_policy, reply.resume_state = item.descriptor.restart_policy, item.resume_state
        return reply
    end
    local function appearance_state(item: Instance, request_id: string?, code: string?, message: string?)
        process.send(item.execution_pid, "bee.appearance.state", {version = 1, request_id = request_id or "",
            revision = appearance_revision, theme = preferences.theme, background = preferences.background, taskbar = preferences.taskbar,
            error_code = code or "", error = message or ""})
    end
    local function find_pid(pid: string): Instance?
        for _, item in pairs(instances) do if item.execution_pid == pid then return item end end
        return nil
    end
    local function mount(item: Instance): string?
        if recipient == "" then return "Desktop is not attached" end
        local value, err = item.view:mount(recipient, {observe = true, input = true, resize = true})
        if not value then return tostring(err) end
        item.mount = value
        return nil
    end
    local function control_result(waiter: Waiter, code: string, message: string)
        process.send(waiter.recipient, "bee.application.result", {version = 1, request_id = waiter.request_id,
            error_code = code, error = message})
    end
    local function finish(item: Instance, failed: boolean)
        item.view:close()
        instances[item.view_id] = nil
        for id, waiter in pairs(preference_waiters) do
            if waiter.recipient == item.execution_pid then preference_waiters[id] = nil end
        end
        if not item.opened then
            emit(identified(item, "open", item.open_request, item.state.failure ~= "" and item.state.failure or "startup_failed", "Application did not become ready"), true)
        else
            emit(identified(item, "closed", "", failed and "application_failed" or "", failed and "Application failed" or ""))
        end
        for _, waiter in ipairs(item.waiters) do
            if waiter.control then control_result(waiter, "", "")
            else emit(identified(item, "close", waiter.request_id), true) end
        end
    end
    local function transition(item: Instance, event: string)
        if event == "ready" then
            item.ready_received = true
            if recipient == "" then return end
        end
        local next_state, effect = lifecycle.reduce(item.state, event, now())
        item.state = next_state
        if effect == "opened" then
            local err = mount(item)
            if err then
                item.state = {phase = "terminating", deadline = now() + 1, failure = "attachment_failed"}
                process.terminate(item.execution_pid)
            else
                item.opened = true
                emit(identified(item, "open", item.open_request), true)
                appearance_state(item)
            end
        elseif effect == "close" then
            local _, err = item.view:send({type = "close"})
            if err then item.state = {phase = "stopping", deadline = now(), failure = item.state.failure} end
        elseif effect == "terminate" then
            item.attempts = item.attempts + 1
            local _, err = process.terminate(item.execution_pid)
            if err or item.attempts >= 3 then
                -- Do not claim EXIT or lose ownership when termination fails.
                for _, waiter in ipairs(item.waiters) do
                    if waiter.control then control_result(waiter, "termination_pending", tostring(err or "Waiting for process exit"))
                    else emit(identified(item, "close", waiter.request_id, "termination_pending", tostring(err or "Waiting for process exit")), true) end
                end
                item.waiters = {}
                if item.attempts >= 3 then item.state.deadline = 0 end
            end
        elseif effect == "closed" or effect == "failed" then finish(item, effect == "failed") end
    end
    local function stop(item: Instance, waiter: Waiter, force: boolean)
        if #item.waiters >= 16 then
            if waiter.control then control_result(waiter, "busy", "Too many pending stop requests")
            else emit(identified(item, "close", waiter.request_id, "busy", "Too many pending stop requests"), true) end
            return
        end
        item.waiters[#item.waiters + 1] = waiter
        if force then item.attempts = 0 end
        transition(item, force and "force_stop" or "stop")
    end
    assert(process.send(owner, "bee.application.catalog", {version = 1, items = catalog.items(bindings)}))
    assert(process.send(owner, "bee.app.ready", {version = 1}))
    local running = true
    while running do
        local selected = channel.select({requests:case_receive(), app_ready:case_receive(), appearance_requests:case_receive(),
            appearance_states:case_receive(), controls:case_receive(), checkpoints:case_receive(), persisted:case_receive(), events:case_receive(), ticks:case_receive()})
        if not selected.ok then break end
        if selected.channel == events then
            local event = selected.value
            if event.kind == process.event.CANCEL or (event.kind == process.event.EXIT and tostring(event.from) == owner) then break end
            if event.kind == process.event.EXIT then
                local item = find_pid(tostring(event.from))
                if item then transition(item, "exit") end
            end
        elseif selected.channel == ticks then
            for id, waiter in pairs(checkpoint_waiters) do
                if now() >= waiter.deadline then
                    process.send(waiter.pid, "bee.application.checkpoint_result", {version = 1, request_id = waiter.request_id,
                        error_code = "timeout", error = "Checkpoint persistence timed out"})
                    checkpoint_waiters[id] = nil
                end
            end
            for _, item in pairs(instances) do transition(item, "tick") end
        elseif selected.channel == checkpoints then
            local msg = selected.value
            local item = find_pid(tostring(msg:from()))
            local data: unknown = msg:payload():data()
            if item and type(data) == "table" and data.version == 1 and data.instance_id == item.instance_id
                and data.id == item.view_id and data.launch_token == item.launch_token then
                local request_id = contract.text(data.request_id, 80)
                if request_id and request_id ~= "" then
                    if item.descriptor.restart_policy == "never" or data.resume_schema ~= item.descriptor.resume_schema
                        or type(data.resume_state) ~= "string" or #data.resume_state > 65536 then
                        process.send(item.execution_pid, "bee.application.checkpoint_result", {version = 1, request_id = request_id,
                            error_code = "invalid_checkpoint", error = "Checkpoint does not match the application contract"})
                    else
                        for id, waiter in pairs(checkpoint_waiters) do
                            if waiter.pid == item.execution_pid then
                                process.send(waiter.pid, "bee.application.checkpoint_result", {version = 1, request_id = waiter.request_id,
                                    error_code = "superseded", error = "A newer checkpoint replaced this request"})
                                checkpoint_waiters[id] = nil
                            end
                        end
                        local routed_id = uuid.v7()
                        checkpoint_waiters[routed_id] = {request_id = request_id, pid = item.execution_pid, deadline = now() + 5}
                        local record = identified(item, "open", routed_id)
                        record.resume_state = data.resume_state
                        item.resume_state = data.resume_state
                        process.send(owner, "bee.application.checkpoint", record)
                    end
                end
            end
        elseif selected.channel == persisted and selected.value:from() == owner then
            local data: unknown = selected.value:payload():data()
            if type(data) == "table" and data.version == 1 and type(data.request_id) == "string" then
                local waiter = checkpoint_waiters[data.request_id]
                if waiter then
                    process.send(waiter.pid, "bee.application.checkpoint_result", {version = 1, request_id = waiter.request_id,
                        error_code = type(data.error_code) == "string" and data.error_code or "invalid_result",
                        error = type(data.error) == "string" and data.error or "Invalid persistence result"})
                    checkpoint_waiters[data.request_id] = nil
                end
            end
        elseif selected.channel == app_ready then
            local msg = selected.value
            local item = find_pid(tostring(msg:from()))
            local data: unknown = msg:payload():data()
            if item and type(data) == "table" and data.version == 1 and data.instance_id == item.instance_id
                and data.view_id == item.view_id and data.launch_token == item.launch_token then transition(item, "ready") end
        elseif selected.channel == appearance_states then
            local msg = selected.value
            local data: unknown = msg:payload():data()
            if msg:from() == owner and type(data) == "table" and data.version == 1 then
                local prefs = appearance.decode(data)
                if prefs and type(data.revision) == "number" and data.revision >= appearance_revision then
                    preferences, appearance_revision = prefs, math.floor(data.revision)
                    local theme = appearance.theme(preferences.theme)
                    for _, item in pairs(instances) do
                        local _, err = item.view:set_page({foreground = theme.text, background = theme.surface})
                        appearance_state(item, nil, err and "page_failed" or "", err and tostring(err) or "")
                    end
                end
                if type(data.request_id) == "string" then
                    local waiter = preference_waiters[data.request_id]
                    local item = waiter and find_pid(waiter.recipient)
                    if item and waiter then appearance_state(item, waiter.request_id, type(data.error_code) == "string" and data.error_code or "", type(data.error) == "string" and data.error or "") end
                    preference_waiters[data.request_id] = nil
                end
            end
        elseif selected.channel == appearance_requests then
            local msg = selected.value
            local item = find_pid(tostring(msg:from()))
            local data: unknown = msg:payload():data()
            if item and type(data) == "table" and data.version == 1 then
                local request_id = contract.text(data.request_id, 80)
                if request_id and request_id ~= "" then
                    if data.op == "state" then appearance_state(item, request_id)
                    elseif data.op == "set" then
                        local prefs = appearance.decode(data)
                        if not item.binding.appearance_write then appearance_state(item, request_id, "permission_denied", "Appearance changes are not granted")
                        elseif not prefs then appearance_state(item, request_id, "invalid_argument", "Invalid appearance")
                        else
                            -- One outstanding appearance write per app bounds waiter storage.
                            for id, waiter in pairs(preference_waiters) do
                                if waiter.recipient == item.execution_pid then
                                    appearance_state(item, waiter.request_id, "superseded", "A newer appearance request replaced this one")
                                    preference_waiters[id] = nil
                                end
                            end
                            local routed_id = uuid.v7()
                            preference_waiters[routed_id] = {request_id = request_id, recipient = item.execution_pid, control = false}
                            local sent, err = process.send(owner, "bee.appearance.request", {version = 1, op = "appearance", request_id = routed_id,
                                theme = prefs.theme, background = prefs.background, taskbar = prefs.taskbar})
                            if not sent then
                                preference_waiters[routed_id] = nil
                                appearance_state(item, request_id, "unavailable", tostring(err))
                            end
                        end
                    end
                end
            end
        elseif selected.channel == controls then
            local msg = selected.value
            local actor = find_pid(tostring(msg:from()))
            local data: unknown = msg:payload():data()
            if actor and type(data) == "table" and data.version == 1 then
                local request_id, pid = contract.text(data.request_id, 80), contract.text(data.execution_pid, 160)
                if request_id and request_id ~= "" and pid and (data.op == "stop" or data.op == "force_stop") then
                    local waiter: Waiter = {request_id = request_id, recipient = actor.execution_pid, control = true}
                    local item = find_pid(pid)
                    if not actor.binding.application_stop then control_result(waiter, "permission_denied", "Application control is not granted")
                    elseif not item then control_result(waiter, "protected_process", "Core processes are protected")
                    else stop(item, waiter, data.op == "force_stop") end
                end
            end
        elseif selected.channel == requests and selected.value:from() == owner then
            local req = contract.request(selected.value:payload():data())
            if req then
                local fingerprint = req.op .. "\0" .. req.id .. "\0" .. req.definition_id .. "\0" .. req.recipient .. "\0" .. req.restore_instance_id .. "\0" .. req.restore_view_id .. "\0" .. req.resume_schema .. "\0" .. tostring(#req.resume_state) .. ":" .. req.resume_state .. contract.argument_fingerprint(req.arguments)
                local cached = completed[req.request_id]
                if fingerprints[req.request_id] and fingerprints[req.request_id] ~= fingerprint then
                    emit(contract.reply(req.request_id, "open", "request_conflict", "Request ID was reused for another operation"))
                elseif cached then
                    if cached.op == "open" and cached.error_code == "" then
                        local item = instances[cached.id]
                        if item and item.state.phase == "ready" then emit(identified(item, "focus", req.request_id))
                        else emit(contract.reply(req.request_id, "open", "request_expired", "Original application has stopped")) end
                    else emit(cached) end
                elseif not pending[req.request_id] then
                    pending[req.request_id] = true
                    fingerprints[req.request_id] = fingerprint
                    if req.op == "shutdown" then running = false
                    elseif req.op == "bind" then
                        recipient = req.recipient
                        local reply = contract.reply(req.request_id, "bind")
                        local function rebind(item: Instance)
                            local view = item.view
                            if item.mount ~= "" then
                                local _, err = view:revoke(item.mount)
                                if err then reply.error_code, reply.error = "revoke_failed", tostring(err) end
                                item.mount = ""
                            end
                            if recipient ~= "" and not item.opened and item.ready_received then transition(item, "ready")
                            elseif recipient ~= "" and item.opened then
                                local err = mount(item)
                                if err then reply.error_code, reply.error = "attachment_failed", err end
                                emit(identified(item, "attached", req.request_id, err and "attachment_failed" or "", err))
                            end
                        end
                        for _, item in pairs(instances) do rebind(item) end
                        emit(reply, true)
                    elseif req.op == "close" then
                        local item = instances[req.id]
                        if item then stop(item, {request_id = req.request_id, recipient = owner, control = false}, false)
                        else emit(contract.reply(req.request_id, "close", "not_found", "View is no longer open"), true) end
                    elseif req.op == "open" then
                        local binding: contract.Binding? = nil
                        for _, candidate in ipairs(bindings) do if candidate.definition_id == req.definition_id then binding = candidate; break end end
                        local descriptor = binding and catalog.descriptor(req.definition_id)
                        local existing: Instance? = nil
                        local count = 0
                        for _, item in pairs(instances) do
                            count = count + 1
                            if descriptor and descriptor.singleton and item.descriptor.definition_id == req.definition_id then existing = item end
                        end
                        if existing then
                            if existing.state.phase == "ready" then emit(identified(existing, "focus", req.request_id), true)
                            else emit(contract.reply(req.request_id, "open", "busy", "Application is changing state"), true) end
                        elseif not binding or not descriptor then emit(contract.reply(req.request_id, "open", "not_admitted", "Application is not admitted"), true)
                        elseif req.restore_instance_id ~= "" and (req.resume_schema ~= descriptor.resume_schema or descriptor.restart_policy == "never") then
                            emit(contract.reply(req.request_id, "open", "incompatible_checkpoint", "Application checkpoint schema is incompatible"), true)
                        elseif req.restore_view_id ~= "" and instances[req.restore_view_id] then
                            emit(contract.reply(req.request_id, "open", "identity_conflict", "View identity is already active"), true)
                        elseif recipient == "" then emit(contract.reply(req.request_id, "open", "not_attached", "Desktop is not attached"), true)
                        elseif count >= 16 then emit(contract.reply(req.request_id, "open", "instance_limit", "Desktop instance limit reached"), true)
                        else
                            local view_id = req.restore_view_id ~= "" and req.restore_view_id or uuid.v7()
                            local instance_id = req.restore_instance_id ~= "" and req.restore_instance_id or uuid.v7()
                            local token = uuid.v7()
                            local theme = appearance.theme(preferences.theme)
                            local view, err = tty.viewport({width = 60, height = 16, page = {foreground = theme.text, background = theme.surface}})
                            if not view then emit(contract.reply(req.request_id, "open", "viewport_failed", tostring(err)), true)
                            else
                                local grant, grant_err = view:grant()
                                if not grant then view:close(); emit(contract.reply(req.request_id, "open", "grant_failed", tostring(grant_err)), true)
                                else
                                    local version = assert(registry.current_version())
                                    local pid, spawn_err = process.with_options({terminal = grant}):with_scope(scope_cache[req.definition_id])
                                        :spawn_monitored(req.definition_id, "bee:workers", {version = 1, broker_pid = tostring(process.pid()), workspace_pid = owner,
                                            instance_id = instance_id, view_id = view_id, definition_id = req.definition_id,
                                            definition_revision = descriptor.definition_revision, registry_revision = version:string(), launch_token = token, resume_schema = descriptor.resume_schema, resume_state = req.resume_state, arguments = req.arguments})
                                    if not pid then view:close(); emit(contract.reply(req.request_id, "open", "spawn_failed", tostring(spawn_err)), true)
                                    else
                                        instances[view_id] = {view_id = view_id, instance_id = instance_id, execution_pid = tostring(pid), view = view,
                                            descriptor = descriptor, binding = binding, mount = "", launch_token = token,
                                            state = lifecycle.start(now()), open_request = req.request_id, opened = false, ready_received = false, resume_state = req.resume_state, waiters = {}, attempts = 0}
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    ticker:stop()
    -- Workspace exit is bounded; per-app graceful deadlines are for normal stop.
    for _, item in pairs(instances) do process.terminate(item.execution_pid); item.view:close() end
    process.unlisten(requests); process.unlisten(app_ready); process.unlisten(appearance_requests)
    process.unlisten(appearance_states); process.unlisten(controls)
    process.unlisten(checkpoints); process.unlisten(persisted)
end
return {main = main}
