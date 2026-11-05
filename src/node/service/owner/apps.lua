-- MIT. The node owner's app instances: starting, restoring and reopening
-- them under an attested application membership, opening and closing them,
-- the dialogs and close negotiation they ask the displays for, the bee.app
-- messages they send their broker, and live updates that restart them in
-- place on a changed definition.
local process = require("process")
local registry = require("registry")
local tty = require("tty")
local uuid = require("uuid")
local logger = require("logger")
local funcs = require("funcs")
local protocol = require("protocol")
local workspaces = require("workspaces")
local appearance = require("appearance")
local client = require("client")
local application = require("application")
local broker = require("broker")
local confirmation = require("confirmation")
local bounds = require("bounds")
local app_identity = require("app_identity")
local canonical = require("canonical")
local seam = require("seam")
local part_instance = require("part_instance")
local part_handover = require("part_handover")
local node_state = require("node_state")
local M = {}
type Dialog = part_handover.Dialog
type AppAlias = part_handover.AppAlias
type Instance = part_handover.Instance
type State = node_state.State
local words = part_handover.words
local saved_dialog = part_handover.saved_dialog
local restored = part_handover.restored
local describe = part_handover.describe
local dialog_of = part_handover.dialog_of

local function register_alias(alias: AppAlias): (AppAlias?, string?)
    local raw, err = funcs.call("bee.threads.binding:register_app_alias", alias)
    local reply = bounds.object(raw)
    if err or not reply or reply.ok ~= true then return nil, "application membership attestation failed: " .. tostring(err or raw) end
    return alias, nil
end

local function attest(app: string, workspace: string, instance: string, saved_alias: unknown?): (AppAlias?, string?)
    if saved_alias ~= nil then
        local saved = bounds.object(saved_alias)
        if not saved or type(saved.stable) ~= "string" or saved.workspace_id ~= workspace
            or saved.definition_id ~= app or saved.instance ~= instance then return nil, "saved application membership is invalid" end
        return register_alias({stable = saved.stable, instance = instance, workspace_id = workspace, definition_id = app})
    end
    local _, admission, admission_error = application.admission(app, workspace)
    if admission_error then return nil, admission_error end
    local stable = app_identity.stable(workspace, app, admission and admission.overlay_owner)
    if not stable then return nil, "application membership identity is unavailable" end
    return register_alias({stable = stable.id, instance = instance, workspace_id = workspace, definition_id = app})
end

function M.retire(alias: AppAlias)
    local recorded, problem = workspaces.retire(alias)
    if not recorded then logger:error("Application retirement intent not stored", {instance = alias.instance, error = problem}) end
end

local function start(state: State, id: string, app: string, desktop: string, args: {[string]: unknown}, workspace: string?, retained: Instance?): (Instance?, string?)
    local instance, err = part_instance.start(id, app, desktop, args, workspace, retained, state.current, attest, M.retire)
    if instance then
        state.instances[id] = instance
        state.by_pid[instance.pid] = id
    end
    return instance, err
end

-- restore reattaches the instances and watchers an upgraded predecessor
-- handed over; monitors belong to the process and survive the upgrade.
function M.restore(state: State, value: unknown): boolean
    if type(value) ~= "table" then return false end
    if type(value.instances) == "table" then
        for _, item in ipairs(value.instances) do
            if type(item) == "table" and type(item.id) == "string" and type(item.handle) == "string"
                and type(item.pid) == "string" and type(item.app) == "string" and type(item.title) == "string"
                and type(item.desktop) == "string" then
                local dialog, dialog_ok = saved_dialog(item.dialog)
                local view, err = nil, nil
                if dialog_ok then view, err = tty.attach(item.handle) else err = "dialog record is malformed" end
                if view then
                    local workspace = type(item.workspace) == "string" and item.workspace or ""
                    local alias, alias_error = attest(item.app, workspace, "bee.application:" .. workspace .. ":" .. item.id, item.alias)
                    if not alias then error(alias_error or "restored application membership is unavailable") end
                    state.instances[item.id] = restored(item, view, alias, dialog)
                    state.by_pid[item.pid] = item.id
                else
                    logger:warn("App instance lost across upgrade", {id = item.id, error = tostring(err)})
                end
            end
        end
    end
    if type(value.alerts) == "table" then
        for _, item in ipairs(value.alerts) do
            local alert = client.alert(item)
            if alert and (state.instances[alert.id] or (alert.app and alert.desktop and alert.workspace)) then state.alerts[alert.id] = alert end
        end
    end
    if type(value.revision) == "number" then state.revision = math.floor(value.revision) end
    if type(value.update_problems) == "table" then
        for id, item in pairs(value.update_problems) do
            if type(id) == "string" and type(item) == "table" and type(item.app) == "string" and type(item.reason) == "string" then
                state.update_problems[id] = {app = item.app, reason = item.reason,
                    definition = type(item.definition) == "string" and item.definition or nil}
            end
        end
    end
    if type(value.watchers) == "table" then
        for _, item in ipairs(value.watchers) do
            if type(item) == "table" and type(item.pid) == "string" and type(item.desktop) == "string" then
                state.watchers[item.pid] = item.desktop
            end
        end
    end
    return true
end

-- reopen starts the instances the node kept when it last ran.
function M.reopen(state: State)
    local kept, err = workspaces.instances()
    if not kept then logger:warn("Kept apps unreadable", {error = err}); return end
    for _, item in ipairs(kept) do
        local _, problem = start(state, item.id, item.app, item.desktop_id, item.args, item.workspace_id)
        if problem then
            logger:warn("Kept app not reopened", {id = item.id, app = item.app, error = problem})
            workspaces.forget(item.id)
        end
    end
end

-- navigate gives a running app the arguments it is opened with again.
local function navigate(instance: Instance, given: {string})
    process.send(instance.pid, broker.NAVIGATE, {version = 1, instance_id = instance.id, view_id = instance.id,
        execution_generation = 1, launch_token = instance.token, arguments = given})
end

-- open starts app on desktop; attention marks an app opened to ask for the
-- person, which displays bring forward without taking the keyboard;
-- request names the agent open request that starts it.
function M.open(state: State, app: unknown, desktop: unknown, app_args: unknown, attention: boolean?, request: string?): protocol.Reply
    if type(app) ~= "string" then return protocol.fail("open needs an app id") end
    if type(desktop) ~= "string" then return protocol.fail("open needs a desktop") end
    local opened_args: {[string]: unknown} = {}
    if app_args ~= nil then
        if type(app_args) ~= "table" then return protocol.fail("open args must be a table") end
        opened_args = app_args
    end
    -- A singleton app already running on the desktop is the one opened;
    -- the arguments it is opened with reach it as navigation.
    local definition = application.definition(app)
    if definition and definition.singleton then
        for _, running in pairs(state.instances) do
            if running.app == app and running.desktop == desktop then
                local given = words(opened_args)
                if #given > 0 then navigate(running, given) end
                local value = describe(running)
                value.existing = true
                return protocol.ok(value)
            end
        end
    end
    local instance, problem = start(state, tostring(uuid.v7()), app, desktop, opened_args)
    if not instance then return protocol.fail(problem or "open failed") end
    instance.request = request
    local kept, keep_error = workspaces.keep({id = instance.id, desktop_id = instance.desktop, workspace_id = instance.workspace,
        app = instance.app, args = opened_args})
    if not kept then logger:warn("App instance not kept", {id = instance.id, error = keep_error}) end
    node_state.broadcast(state, {kind = "opened", instance = describe(instance), attention = attention == true or nil})
    return protocol.ok(describe(instance))
end

function M.attach(state: State, caller: string, id: unknown): protocol.Reply
    if type(id) ~= "string" then return protocol.fail("attach needs an instance id") end
    local instance = state.instances[id]
    if not instance then return protocol.fail("no running instance " .. id) end
    local ref, mount_error = instance.view:mount(caller, {observe = true, input = true, resize = true})
    if not ref then return protocol.fail("mount: " .. tostring(mount_error)) end
    local value: {[string]: unknown} = {ref = ref, title = instance.title}
    return protocol.ok(value)
end

function M.stop(state: State, instance: Instance): protocol.Reply
    seam.hold("bee.node.service.stop", instance)
    local cancelled, cancel_error = process.cancel(instance.pid)
    if not cancelled and not errors.is(cancel_error, errors.NOT_FOUND) then
        return protocol.fail("stop " .. instance.title .. ": " .. tostring(cancel_error))
    end
    return protocol.ok({id = instance.id})
end

-- drop_dialog forgets an instance's dialog and tells the displays.
local function drop_dialog(state: State, instance: Instance)
    if not instance.dialog then return end
    local pending = instance.dialog.confirmation
    if pending then
        local review = confirmation.new({workspace_id = instance.workspace, origin = {app_id = instance.app, instance_id = instance.id}})
        review.pending = pending
        local canceled, err = confirmation.cancel(review)
        if not canceled then error(err) end
    end
    instance.dialog = nil
    node_state.broadcast(state, {kind = "dialog_closed", id = instance.id})
end

-- show_dialog puts a dialog an app asked for to the displays.
local function show_dialog(state: State, instance: Instance, dialog: Dialog): (boolean, string?)
    if dialog.kind == "confirm" then
        local review = confirmation.new({workspace_id = instance.workspace, origin = {app_id = instance.app, instance_id = instance.id}})
        local opened, err = confirmation.open(review, dialog.closing and "app.close" or "app.query",
            {instance_id = instance.id, execution_id = instance.execution_id, definition_id = instance.app, revision = instance.revision,
                request_id = dialog.client_request_id, title = dialog.title, message = dialog.message, target = dialog.target}, "dialog", dialog.title, dialog.message)
        if not opened then return false, err end
        dialog.confirmation = review.pending
    end
    instance.dialog = dialog
    node_state.broadcast(state, {kind = "dialog", dialog = dialog_of(instance)})
    return true, nil
end

-- close stops an app; an app that negotiates its close is asked first and
-- answers with accept, cancel or a confirmation for the person. force
-- stops it without asking.
function M.close(state: State, id: unknown, force: unknown, expected_execution: unknown): protocol.Reply
    if type(id) ~= "string" then return protocol.fail("close needs an instance id") end
    local instance = state.instances[id]
    if not instance then return protocol.ok({id = id}) end
    if expected_execution ~= nil and expected_execution ~= instance.execution_id then return protocol.fail("application execution changed") end
    if force == true or not instance.negotiate then return M.stop(state, instance) end
    if not instance.closing then
        local request_id = tostring(uuid.v7())
        instance.closing = request_id
        drop_dialog(state, instance)
        local sent, err = process.send(instance.pid, broker.CLOSE, {version = 1, request_id = request_id, id = id, instance_id = id})
        if not sent then
            instance.closing = nil
            if errors.is(err, errors.NOT_FOUND) then return protocol.ok({id = id}) end
            return protocol.fail("ask " .. instance.title .. " to close: " .. tostring(err))
        end
    end
    return protocol.ok({id = id, closing = true})
end

-- cancel_close tells an app its close was cancelled.
local function cancel_close(state: State, instance: Instance)
    local request_id = instance.closing
    instance.closing = nil
    if request_id then
        process.send(instance.pid, broker.CLOSE_RESULT, {version = 1, request_id = request_id, id = instance.id,
            instance_id = instance.id, action = "cancel"})
    end
    if instance.relaunch then
        instance.relaunch = nil
        node_state.update_problem(state, instance, instance.title .. " declined its live update")
    end
end

-- app_message applies a bee.app message from an app's own process; one
-- that does not carry the instance's launch token is refused.
function M.app_message(state: State, topic: string, from: string, data: unknown)
    local id = state.by_pid[from]
    local instance = id and state.instances[id] or nil
    if not instance or not broker.authentic(data, instance.id, instance.token) then
        logger:warn("Broker message refused", {topic = topic, from = from})
        return
    end
    if topic == broker.READY then
        instance.negotiate = broker.ready(data) == true
    elseif topic == broker.REVIEW then
        local body = bounds.object(data)
        local review = body and client.review(body.review)
        if review or (body and body.review == false) then
            instance.review = review
            node_state.broadcast(state, {kind = "review", id = instance.id, review = review or false})
        end
    elseif topic == broker.TITLE then
        local title = broker.title(data)
        if title and title ~= instance.title then
            instance.title = title
            node_state.broadcast(state, {kind = "title", id = instance.id, title = title})
        end
    elseif topic == broker.CLOSE_REPLY then
        local reply = broker.close_reply(data)
        if not reply or reply.request_id ~= instance.closing then return end
        if reply.action == "accept" then
            instance.closing = nil
            M.stop(state, instance)
        elseif reply.action == "cancel" then
            cancel_close(state, instance)
        else
            local shown, err = show_dialog(state, instance, {request_id = tostring(uuid.v7()), client_request_id = reply.request_id, kind = "confirm",
                title = reply.title, message = reply.message, accept = reply.accept, initial = "", closing = true})
            if not shown then
                logger:warn("Close confirmation failed", {id = instance.id, error = err})
                cancel_close(state, instance)
            end
        end
    elseif topic == broker.QUERY then
        local spec = broker.query(data)
        if not spec or spec.id ~= instance.id then return end
        if instance.dialog or instance.closing then
            process.send(instance.pid, broker.QUERY_RESULT, {version = 1, request_id = spec.request_id, id = instance.id,
                instance_id = instance.id, action = "cancel", value = "", error = "busy"})
            return
        end
        local shown, err = show_dialog(state, instance, {request_id = tostring(uuid.v7()), client_request_id = spec.request_id, kind = spec.kind,
            title = spec.title, message = spec.message, accept = spec.accept, initial = spec.initial, closing = false, target = spec.target})
        if not shown then
            logger:warn("Application confirmation failed", {id = instance.id, error = err})
            process.send(instance.pid, broker.QUERY_RESULT, {version = 1, request_id = spec.request_id, id = instance.id,
                instance_id = instance.id, action = "cancel", value = "", error = "unavailable"})
        end
    elseif topic == broker.CHECKPOINT then
        local checkpoint = broker.checkpoint(data)
        if not checkpoint then return end
        local result: {[string]: unknown} = {version = 1, request_id = checkpoint.request_id, error_code = "", error = ""}
        if instance.resume_schema == "" or checkpoint.resume_schema ~= instance.resume_schema then
            result.error_code, result.error = "invalid_checkpoint", "Checkpoint does not match the application contract"
        else
            local args: {[string]: unknown} = {}
            for key, value in pairs(instance.args) do args[key] = value end
            args.resume_state = checkpoint.resume_state
            local kept, keep_error = workspaces.remember(instance.id, args)
            if kept then instance.args = args
            else result.error_code, result.error = "storage", tostring(keep_error) end
        end
        process.send(instance.pid, broker.CHECKPOINT_RESULT, result)
    elseif topic == broker.REQUEST then
        local request = broker.open(data)
        if not request then return end
        local reply = M.open(state, request.definition_id, instance.desktop, {arguments = request.arguments})
        if not reply.ok then logger:warn("App navigation failed", {from = instance.id, to = request.definition_id, error = tostring(reply.error)}) end
    end
end

-- answer applies a display's answer to the dialog an app waits on.
function M.answer(state: State, args: {[string]: unknown}): protocol.Reply
    local id = args.id
    if type(id) ~= "string" then return protocol.fail("answer needs an instance id") end
    local instance = state.instances[id]
    if not instance then return protocol.fail("no running instance " .. id) end
    local dialog = instance.dialog
    if not dialog or args.request_id ~= dialog.request_id then return protocol.fail("no such dialog for " .. id) end
    local action = args.action
    if action ~= "accept" and action ~= "cancel" then return protocol.fail("answer must accept or cancel") end
    local value = args.value
    if value == nil then value = "" end
    if type(value) ~= "string" or #value > 256 or value:find("%c") or (action == "cancel" and value ~= "") then
        return protocol.fail("answer value is invalid")
    end
    if dialog.confirmation then
        local review = confirmation.new({workspace_id = instance.workspace, origin = {app_id = instance.app, instance_id = instance.id}})
        review.pending = dialog.confirmation
        local confirmed: boolean
        local err: string?
        if action == "accept" then
            local gesture = args.gesture
            if gesture ~= "enter" and gesture ~= "space" and gesture ~= "click" and gesture ~= "shortcut" then return protocol.fail("answer needs its confirmed gesture") end
            confirmed, err = confirmation.accept(review, {instance_id = instance.id, execution_id = instance.execution_id, definition_id = instance.app, revision = instance.revision,
                request_id = dialog.client_request_id, title = dialog.title, message = dialog.message, target = dialog.target}, gesture)
        else confirmed, err = confirmation.cancel(review) end
        if not confirmed then return protocol.fail(err or "confirmation failed") end
        dialog.confirmation = nil
    end
    drop_dialog(state, instance)
    if dialog.closing then
        if action == "accept" then
            instance.closing = nil
            return M.stop(state, instance)
        end
        cancel_close(state, instance)
        return protocol.ok({id = id})
    end
    process.send(instance.pid, broker.QUERY_RESULT, {version = 1, request_id = dialog.client_request_id, id = id,
        instance_id = id, action = action, value = value, error = ""})
    return protocol.ok({id = id})
end

-- move puts a running app on another desktop; displays showing either
-- desktop follow it.
function M.move(state: State, id: unknown, desktop: unknown): protocol.Reply
    if type(id) ~= "string" then return protocol.fail("move needs an instance id") end
    local instance = state.instances[id]
    if not instance then return protocol.fail("no running instance " .. id) end
    if type(desktop) ~= "string" or not workspaces.desktop(desktop) then return protocol.fail("no such desktop") end
    local moved, err = workspaces.move_instance(id, desktop)
    if not moved then return protocol.fail(err or "app not moved") end
    instance.desktop = desktop
    node_state.broadcast(state, {kind = "moved", instance = describe(instance)})
    return protocol.ok(describe(instance))
end

function M.update_instances(state: State)
    local cleared = false
    for id, item in pairs(state.update_problems) do
        if not state.instances[id] then
            local entry = registry.get(item.app)
            local digest = entry and canonical.digest(entry) or nil
            if digest ~= item.definition then state.update_problems[id] = nil; cleared = true end
        end
    end
    if cleared then node_state.broadcast(state, {kind = "catalog", apps = state.installed_apps, problem = node_state.problem(state)}) end
    for _, instance in pairs(state.instances) do
        local entry, entry_error = registry.get(instance.app)
        local digest, digest_error = canonical.digest(entry)
        if not entry or not digest then
            node_state.update_problem(state, instance, instance.title .. " could not update: " .. tostring(entry_error or digest_error))
        elseif digest == instance.definition and instance.update_target ~= digest and not instance.relaunch and state.update_problems[instance.id] then
            instance.update_target = nil
            node_state.update_problem(state, instance, nil)
        elseif digest ~= instance.definition and digest ~= instance.update_target and not instance.relaunch then
            instance.update_target = digest
            instance.relaunch = true
            node_state.update_problem(state, instance, instance.title .. " is waiting to finish its live update")
            local stopped = M.close(state, instance.id, false, nil)
            if not stopped.ok then
                instance.relaunch = nil
                node_state.update_problem(state, instance, instance.title .. " could not update: " .. tostring(stopped.error))
            end
        end
    end
end

-- exited forgets a display or an app whose process ended; problem is the
-- error an app failed with.
function M.exited(state: State, pid: string, problem: string?)
    if state.watchers[pid] then
        state.watchers[pid] = nil
        node_state.announce_workspaces(state)
    end
    local id = state.by_pid[pid]
    if not id then return end
    state.by_pid[pid] = nil
    local instance = state.instances[id]
    if instance and instance.relaunch then
        drop_dialog(state, instance)
        local restarted, restart_error = start(state, id, instance.app, instance.desktop, instance.args, instance.workspace, instance)
        if restarted then
            restarted.view:set_page(appearance.page(state.current.theme, restarted.terminal))
            node_state.update_problem(state, restarted, nil)
            node_state.broadcast(state, {kind = "moved", instance = describe(restarted)})
            if restarted.title ~= instance.title then node_state.broadcast(state, {kind = "title", id = id, title = restarted.title}) end
            return
        end
        node_state.update_problem(state, instance, instance.title .. " could not update: " .. tostring(restart_error))
    end
    local forgotten, forget_error = workspaces.forget(id, instance and instance.alias or nil)
    if not forgotten then logger:error("App close not stored", {id = id, error = forget_error}) end
    if instance then drop_dialog(state, instance) end
    state.instances[id] = nil
    if instance then
        if problem and not instance.relaunch then logger:warn("App failed", {id = id, app = instance.app, error = problem}) end
        if problem and instance.update_target and not instance.relaunch then
            node_state.update_problem(state, instance, instance.title .. " failed after its live update: " .. problem)
        elseif not problem and not instance.relaunch and state.update_problems[id] then
            node_state.update_problem(state, instance, nil)
        end
        instance.view:close()
        node_state.broadcast(state, {kind = "closed", id = id})
    end
end

return M
