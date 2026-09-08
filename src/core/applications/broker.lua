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
local attachment = require("attachment")
local appearance = require("appearance")
local interaction = require("interaction")
local interactions = require("interactions")
local shutdown = require("shutdown")
type Waiter = {request_id: string, recipient: string, control: boolean}
type Checkpoint = {request_id: string, pid: string, deadline: number}
type Instance = {view_id: string, instance_id: string, execution_pid: string, view: tty.Viewport,
    descriptor: contract.Descriptor, binding: contract.Binding, attachment: attachment.Record?, launch_token: string,
    negotiate_close: boolean?, close_request_id: string?, announced_title: string?, title_dirty: boolean?, state: lifecycle.State, open_request: string, opened: boolean, resume_state: string, waiters: {Waiter}, attempts: integer}
local function now(): number return time.now():unix_nano() / 1000000000 end
local function main(owner: string, initial_preferences: unknown)
    local bootstrap: unknown = ctx.get("bee.workspace_owner")
    if bootstrap ~= owner or owner == "" then error("Untrusted broker bootstrap") end
    local workspace_id = contract.workspace_id(ctx.get("bee.workspace_id"))
    if not workspace_id then
        error("Invalid workspace identity bootstrap")
    end
    local requests = assert(process.listen("bee.app.request", {message = true}))
    local shutdown_requests = assert(process.listen("bee.application.shutdown", {message = true}))
    local close_replies = assert(process.listen("bee.application.close.reply", {message = true}))
    local queries = assert(process.listen("bee.application.query", {message = true}))
    local answers = assert(process.listen("bee.interaction.response", {message = true}))
    local titles = assert(process.listen("bee.application.title", {message = true}))
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
    local dialogs = interactions.new()
    local shutdown_plan: shutdown.State? = nil
    local shutdown_dialog: interaction.Spec? = nil
    local quit_sent = false
    local cleanup_request = ""
    local cleanup_deadline = 0
    local cleanup_complete = false
    local function publish_dialogs()
        local items: {interaction.Wire} = {}
        for _, spec in ipairs(interactions.snapshot(dialogs)) do items[#items + 1] = interaction.wire(spec) end
        process.send(owner, "bee.interaction.state", {version = 1, items = items, shutdown = shutdown_dialog and interaction.wire(shutdown_dialog) or nil})
    end
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
        reply.workspace_id = workspace_id
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
        reply.workspace_id = workspace_id
        reply.id, reply.instance_id, reply.title, reply.mount = item.view_id, item.instance_id, item.announced_title or item.descriptor.title, attachment.reference(item.attachment)
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
        local result = attachment.replace(item.view, item.attachment, recipient)
        item.attachment = result.attachment
        if result.error ~= "" then return result.error end
        return nil
    end
    local function control_result(waiter: Waiter, code: string, message: string)
        process.send(waiter.recipient, "bee.application.result", {version = 1, request_id = waiter.request_id,
            error_code = code, error = message})
    end
    local function refresh_shutdown()
        local plan = shutdown_plan
        if not plan then return end
        if not shutdown.ready(plan) or quit_sent then return end
        if not shutdown.needs_confirmation(plan) then
            quit_sent = true
            emit(contract.reply(plan.request_id, "quit"))
            return
        end
        local decisions = shutdown.decisions(plan)
        local names, unresponsive = "", 0
        for _, decision in ipairs(decisions) do
            if #names + #decision.title < 240 then names = names .. (names == "" and "" or ", ") .. decision.title end
            if decision.force then unresponsive = unresponsive + 1 end
        end
        local message = "Stop all applications and running work? Unsaved changes may be lost. " .. names
        if unresponsive > 0 then message = message .. ". " .. tostring(unresponsive) .. " application(s) did not respond." end
        if not shutdown_dialog or shutdown_dialog.message ~= message then
            shutdown_dialog = {request_id = uuid.v7(), id = "bee.workspace:shutdown", instance_id = "workspace",
                kind = "confirm", title = "Quit Bee?", message = message, accept = "Quit Bee", initial = ""}
            publish_dialogs()
        end
    end
    local function finish(item: Instance, failed: boolean)
        if shutdown_plan then shutdown.remove(shutdown_plan, item.view_id) end
        if interactions.remove(dialogs, item.view_id) then publish_dialogs() end
        item.view:close()
        instances[item.view_id] = nil
        for id, waiter in pairs(preference_waiters) do
            if waiter.recipient == item.execution_pid then preference_waiters[id] = nil end
        end
        if cleanup_request ~= "" then
            -- Keep recovery records when the workspace itself is shutting down.
            return
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
    local function discard_dialog(item: Instance)
        local pending_dialog = interactions.remove(dialogs, item.view_id)
        if pending_dialog then
            if not pending_dialog.closing then
                process.send(item.execution_pid, "bee.application.query.result", {version = 1,
                    request_id = pending_dialog.client_request_id, id = item.view_id, instance_id = item.instance_id,
                    action = "cancel", value = "", error = ""})
            end
            publish_dialogs()
        end
    end
    local function close_prompt(item: Instance, title: string, message: string, accept: string)
        local spec: interaction.Spec = {request_id = uuid.v7(), id = item.view_id, instance_id = item.instance_id,
            kind = "confirm", title = title, message = message, accept = accept, initial = ""}
        if interactions.add(dialogs, spec, item.close_request_id or "", item.execution_pid, true) then publish_dialogs() end
    end
    local function transition(item: Instance, event: lifecycle.Event)
        local next_state, effect = lifecycle.reduce(item.state, event, now())
        item.state = next_state
        if effect == "opened" then
            -- Readiness belongs to the producer. A missing or failed consumer
            -- attachment must not turn a ready application into a startup failure.
            item.opened = true
            local attachment_error: string? = nil
            if recipient ~= "" then attachment_error = mount(item) end
            emit(identified(item, "open", item.open_request), true)
            appearance_state(item)
            if attachment_error then
                emit(identified(item, "attached", item.open_request, "attachment_failed", attachment_error))
            end
        elseif effect == "query_close" then
            discard_dialog(item)
            process.send(item.execution_pid, "bee.application.close", {version = 1, request_id = item.close_request_id,
                id = item.view_id, instance_id = item.instance_id})
        elseif effect == "close_timeout" then
            if shutdown_plan and shutdown_plan.pending[item.view_id] then
                shutdown.record(shutdown_plan, item.view_id, item.announced_title or item.descriptor.title, "Application did not respond", true)
                refresh_shutdown()
            else close_prompt(item, "Application did not respond", "Force stopping may lose unsaved work.", "Force stop") end
        elseif effect == "close_cancelled" then
            discard_dialog(item)
            process.send(item.execution_pid, "bee.application.close.result", {version = 1, request_id = item.close_request_id,
                id = item.view_id, instance_id = item.instance_id, action = "cancel"})
            item.close_request_id = nil
            for _, waiter in ipairs(item.waiters) do
                if waiter.control then control_result(waiter, "cancelled", "Close cancelled")
                else emit(identified(item, "close", waiter.request_id, "cancelled", "Close cancelled"), true) end
            end
            item.waiters = {}
        elseif effect == "close" then
            discard_dialog(item)
            item.close_request_id = nil
            local _, err = item.view:send({type = "close"})
            if err then item.state = {phase = "stopping", deadline = now(), failure = item.state.failure} end
        elseif effect == "terminate" then
            discard_dialog(item)
            item.close_request_id = nil
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
        if shutdown_plan and not force then
            if waiter.control then control_result(waiter, "busy", "Quit confirmation pending")
            else emit(identified(item, "close", waiter.request_id, "busy", "Quit confirmation pending"), true) end
            return
        end
        if #item.waiters >= 16 then
            if waiter.control then control_result(waiter, "busy", "Too many pending stop requests")
            else emit(identified(item, "close", waiter.request_id, "busy", "Too many pending stop requests"), true) end
            return
        end
        item.waiters[#item.waiters + 1] = waiter
        if force then item.attempts = 0 end
        if not force and item.negotiate_close and (item.state.phase == "ready" or item.state.phase == "close_requested"
            or item.state.phase == "close_confirming" or item.state.phase == "close_unresponsive") then
            if item.state.phase == "ready" then
                item.close_request_id = uuid.v7()
                transition(item, "request_close")
            end
            emit(identified(item, "closing", ""))
        else transition(item, force and "force_stop" or "stop") end
    end
    assert(process.send(owner, "bee.application.catalog", {version = 1, items = catalog.items(bindings)}))
    assert(process.send(owner, "bee.app.ready", {version = 1}))
    local function abort_shutdown()
        local plan = shutdown_plan
        shutdown_plan, shutdown_dialog, quit_sent = nil, nil, false
        if plan then
            for id, item in pairs(instances) do
                if plan.pending[id] or plan.decisions[id] then transition(item, "cancel_close") end
            end
            emit(contract.reply(plan.request_id, "quit", "cancelled", "Quit cancelled"))
        end
        publish_dialogs()
    end
    local function prepare_shutdown()
        if cleanup_request ~= "" then return end
        if shutdown_plan then publish_dialogs(); return end
        local ids: {string} = {}
        for id, item in pairs(instances) do
            if item.negotiate_close and (item.state.phase == "ready" or item.state.phase == "close_requested"
                or item.state.phase == "close_confirming" or item.state.phase == "close_unresponsive") then ids[#ids + 1] = id end
        end
        shutdown_plan = shutdown.start(uuid.v7(), ids)
        local function ask(item: Instance)
            if item.state.phase ~= "ready" then transition(item, "cancel_close") end
            item.close_request_id = uuid.v7()
            transition(item, "request_close")
        end
        for _, id in ipairs(ids) do local item = instances[id]; if item then ask(item) end end
        refresh_shutdown()
    end
    local function accept_readiness(item: Instance, negotiate: boolean)
        if item.state.phase == "starting" then item.negotiate_close = negotiate end
        transition(item, "ready")
    end
    local function tick_instance(item: Instance)
        transition(item, "tick")
        if item.opened and lifecycle.accepts_updates(item.state) and item.title_dirty then
            emit(identified(item, "title", ""))
            item.title_dirty = false
        end
    end
    local running = true
    while running do
        local selected = channel.select({requests:case_receive(), app_ready:case_receive(), titles:case_receive(), queries:case_receive(), answers:case_receive(), close_replies:case_receive(), shutdown_requests:case_receive(), appearance_requests:case_receive(),
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
            for _, item in pairs(instances) do tick_instance(item) end
            refresh_shutdown()
        elseif selected.channel == shutdown_requests and selected.value:from() == owner then
            local data: unknown = selected.value:payload():data()
            if type(data) == "table" and data.version == 1 and data.op == "prepare" then prepare_shutdown() end
        elseif selected.channel == close_replies then
            local message = selected.value
            local item = find_pid(tostring(message:from()))
            local data: unknown = message:payload():data()
            if item and item.state.phase == "close_requested" and type(data) == "table" and data.version == 1
                and data.id == item.view_id and data.instance_id == item.instance_id and data.launch_token == item.launch_token
                and data.request_id == item.close_request_id then
                if data.action == "accept" then
                    if shutdown_plan and shutdown_plan.pending[item.view_id] then
                        transition(item, "confirm_close")
                        shutdown.record(shutdown_plan, item.view_id, item.announced_title or item.descriptor.title, "", false)
                        refresh_shutdown()
                    else transition(item, "accept_close") end
                elseif data.action == "cancel" then
                    if shutdown_plan and shutdown_plan.pending[item.view_id] then abort_shutdown()
                    else transition(item, "cancel_close") end
                elseif data.action == "confirm" then
                    local spec = interaction.spec({version = 1, request_id = data.request_id, id = data.id,
                        instance_id = data.instance_id, kind = "confirm", title = data.title, message = data.message,
                        accept = data.accept, initial = ""})
                    if spec then
                        transition(item, "confirm_close")
                        if shutdown_plan and shutdown_plan.pending[item.view_id] then
                            shutdown.record(shutdown_plan, item.view_id, item.announced_title or item.descriptor.title,
                                spec.message ~= "" and spec.message or spec.title, false)
                            refresh_shutdown()
                        else close_prompt(item, spec.title, spec.message, spec.accept) end
                    end
                end
            end
        elseif selected.channel == queries then
            local message = selected.value
            local item = find_pid(tostring(message:from()))
            local data: unknown = message:payload():data()
            if item and type(data) == "table"
                and data.launch_token == item.launch_token then
                local spec = interaction.spec(data)
                if spec and spec.id == item.view_id and spec.instance_id == item.instance_id then
                    local client_request_id = spec.request_id
                    spec.request_id = uuid.v7()
                    if (item.state.phase == "starting" or item.state.phase == "ready") and not shutdown_plan
                        and interactions.add(dialogs, spec, client_request_id, item.execution_pid, false) then publish_dialogs()
                    else
                        process.send(item.execution_pid, "bee.application.query.result", {version = 1,
                            request_id = client_request_id, id = item.view_id, instance_id = item.instance_id,
                            action = "cancel", value = "", error = "busy"})
                    end
                end
            end
        elseif selected.channel == answers and selected.value:from() == owner and cleanup_request == "" then
            local response = interaction.response(selected.value:payload():data())
            if response and shutdown_dialog and response.id == shutdown_dialog.id and response.instance_id == shutdown_dialog.instance_id
                and response.request_id == shutdown_dialog.request_id and response.value == "" then
                if response.action == "cancel" then abort_shutdown()
                elseif not quit_sent then quit_sent = true; emit(contract.reply(response.request_id, "quit")) end
            elseif response then
                local pending_dialog = interactions.resolve(dialogs, response)
                if pending_dialog then
                    local item = instances[response.id]
                    if pending_dialog.closing and item then
                        if response.action == "cancel" then transition(item, "cancel_close")
                        elseif item.state.phase == "close_unresponsive" then transition(item, "force_stop")
                        else transition(item, "accept_close") end
                    else
                        process.send(pending_dialog.execution_pid, "bee.application.query.result", {version = 1,
                            request_id = pending_dialog.client_request_id, id = response.id, instance_id = response.instance_id,
                            action = response.action, value = response.value, error = ""})
                    end
                    publish_dialogs()
                end
            end
        elseif selected.channel == titles then
            local message = selected.value
            local item = find_pid(tostring(message:from()))
            local data: unknown = message:payload():data()
            if item and lifecycle.accepts_updates(item.state)
                and type(data) == "table" and data.version == 1 and data.instance_id == item.instance_id
                and data.id == item.view_id and data.launch_token == item.launch_token then
                local title = contract.text(data.title, 80)
                if title then
                    if title == "" then title = item.descriptor.title end
                    if title ~= (item.announced_title or item.descriptor.title) then
                        item.announced_title = title; item.title_dirty = true
                    end
                end
            end
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
                and data.view_id == item.view_id and data.launch_token == item.launch_token
                and (data.negotiate_close == nil or type(data.negotiate_close) == "boolean") then
                accept_readiness(item, data.negotiate_close == true)
            end
        elseif selected.channel == appearance_states then
            local msg = selected.value
            local data: unknown = msg:payload():data()
            if msg:from() == owner and type(data) == "table" and data.version == 1 then
                local prefs = appearance.decode(data)
                if prefs and type(data.revision) == "number" and data.revision >= appearance_revision then
                    preferences, appearance_revision = prefs, math.floor(data.revision)
                    local theme = appearance.theme(preferences.theme)
                    for _, item in pairs(instances) do
                        local _, err = item.view:set_page(appearance.page(theme, item.descriptor.role == "terminal"))
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
            if req and req.workspace_id ~= workspace_id then
                local reply = contract.reply(req.request_id, req.op, "workspace_mismatch", "Request targets another workspace")
                reply.id = req.id
                emit(reply)
            elseif req then
                local fingerprint = req.op .. "\0" .. req.id .. "\0" .. req.definition_id .. "\0" .. req.recipient .. "\0" .. req.restore_instance_id .. "\0" .. req.restore_view_id .. "\0" .. req.resume_schema .. "\0" .. tostring(#req.resume_state) .. ":" .. req.resume_state .. contract.argument_fingerprint(req.arguments)
                fingerprint = fingerprint .. "\0" .. req.instance_id
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
                    if req.op == "shutdown" then
                        if cleanup_request == "" then
                            cleanup_request, cleanup_deadline = req.request_id, now() + 3.5
                            shutdown_dialog = nil
                            publish_dialogs()
                            for _, item in pairs(instances) do
                                if item.state.phase == "close_unresponsive" then transition(item, "force_stop")
                                elseif item.state.phase == "close_requested" or item.state.phase == "close_confirming" then transition(item, "accept_close")
                                else transition(item, "stop") end
                            end
                        end
                    elseif req.op == "bind" then
                        if req.id == "" then recipient = req.recipient end
                        local reply = contract.reply(req.request_id, "bind")
                        local function rebind(item: Instance)
                            local result = attachment.replace(item.view, item.attachment, item.opened and req.recipient or "")
                            item.attachment = result.attachment
                            if result.error ~= "" then reply.error_code, reply.error = result.error_code, result.error end
                            if result.error_code == "revoke_failed" or (req.recipient ~= "" and item.opened) then
                                local response = identified(item, "attached", req.request_id, result.error_code, result.error)
                                if result.error ~= "" then response.mount = "" end
                                emit(response)
                            end
                        end
                        if req.id == "" then
                            for _, item in pairs(instances) do rebind(item) end
                        else
                            local item = instances[req.id]
                            reply.id, reply.instance_id = req.id, req.instance_id
                            if not item or item.instance_id ~= req.instance_id then
                                reply.error_code, reply.error = "not_found", "Application view is no longer open"
                            elseif not item.opened then
                                reply.error_code, reply.error = "not_ready", "Application view is not ready"
                            else rebind(item) end
                        end
                        emit(reply, true)
                    elseif req.op == "close" then
                        local item = instances[req.id]
                        if item then stop(item, {request_id = req.request_id, recipient = owner, control = false}, false)
                        else emit(contract.reply(req.request_id, "close", "not_found", "View is no longer open"), true) end
                    elseif req.op == "open" and shutdown_plan then
                        emit(contract.reply(req.request_id, "open", "busy", "Quit confirmation pending"), true)
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
                        elseif count >= 16 then emit(contract.reply(req.request_id, "open", "instance_limit", "Desktop instance limit reached"), true)
                        else
                            local view_id = req.restore_view_id ~= "" and req.restore_view_id or uuid.v7()
                            local instance_id = req.restore_instance_id ~= "" and req.restore_instance_id or uuid.v7()
                            local token = uuid.v7()
                            local theme = appearance.theme(preferences.theme)
                            local view, err = tty.viewport({width = 60, height = 16, page = appearance.page(theme, descriptor.role == "terminal")})
                            if not view then emit(contract.reply(req.request_id, "open", "viewport_failed", tostring(err)), true)
                            else
                                local grant, grant_err = view:grant()
                                if not grant then view:close(); emit(contract.reply(req.request_id, "open", "grant_failed", tostring(grant_err)), true)
                                else
                                    local version = assert(registry.current_version())
                                    local pid, spawn_err = process.with_options({terminal = grant}):with_scope(scope_cache[req.definition_id])
                                        :spawn_monitored(req.definition_id, "bee:workers", {version = 1, broker_pid = tostring(process.pid()), workspace_pid = owner, workspace_id = workspace_id,
                                            instance_id = instance_id, view_id = view_id, definition_id = req.definition_id,
                                            definition_revision = descriptor.definition_revision, registry_revision = version:string(), launch_token = token, resume_schema = descriptor.resume_schema, resume_state = req.resume_state, arguments = req.arguments})
                                    if not pid then view:close(); emit(contract.reply(req.request_id, "open", "spawn_failed", tostring(spawn_err)), true)
                                    else
                                        instances[view_id] = {view_id = view_id, instance_id = instance_id, execution_pid = tostring(pid), view = view,
                                            descriptor = descriptor, binding = binding, launch_token = token,
                                            state = lifecycle.start(now()), open_request = req.request_id, opened = false, resume_state = req.resume_state, waiters = {}, attempts = 0}
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        if cleanup_request ~= "" and not cleanup_complete then
            local live, writes = false, false
            for _ in pairs(instances) do live = true; break end
            for _ in pairs(checkpoint_waiters) do writes = true; break end
            if not live and not writes then
                cleanup_complete = true
                emit(contract.reply(cleanup_request, "shutdown"), true)
            elseif now() >= cleanup_deadline then
                cleanup_complete = true
                emit(contract.reply(cleanup_request, "shutdown", "cleanup_incomplete",
                    "Workspace cleanup timed out; some process exits or writes remain unacknowledged"), true)
            end
        end
    end
    ticker:stop()
    -- Owner loss is the emergency path; normal shutdown has already cooperated.
    for _, item in pairs(instances) do process.terminate(item.execution_pid); item.view:close() end
    process.unlisten(shutdown_requests)
    process.unlisten(close_replies)
    process.unlisten(queries); process.unlisten(answers)
    process.unlisten(titles)
    process.unlisten(requests); process.unlisten(app_ready); process.unlisten(appearance_requests)
    process.unlisten(appearance_states); process.unlisten(controls)
    process.unlisten(checkpoints); process.unlisten(persisted)
end
return {main = main}
