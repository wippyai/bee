-- MIT. The Agent window's selection phase, before any native child exists.
-- It owns the same broker terminal throughout selection and execution.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local uuid = require("uuid")
local funcs = require("funcs")
local bounds = require("bounds")
local client = require("client")
local appearance = require("appearance")
local input_event = require("input_event")
local selection = require("selection")
local admission = require("admission")
local view = require("view")
local forms = require("forms")
local profile_view = require("profile_view")
local M = {}
type Channel = channel.Channel
type Activation = {serial: integer, admitted: admission.Admitted?, refused: admission.Reply?, error: string?, title: string?}
local function fault(reply: admission.Reply?): string
    local value = reply and reply.error
    if not value then return "Agent launch was not admitted" end
    return value.code .. ": " .. value.message
end

-- A CLI definition route uses the same setup and admission operations as an
-- explicit picker choice. The command resolver supplies only a definition
-- reference; this actor obtains and fences the current measured plan.
function M.direct(workspace_id: string, definition_ref: string, origin_view: {view_id: string, instance_id: string}?): (admission.Admitted?, string?)
    local plan, refused = admission.resolve(definition_ref, "window", workspace_id)
    if not plan then return nil, fault(refused) end
    local setup, setup_error = funcs.call("bee.harness.launch:setup", {
        workspace_id = workspace_id, definition_ref = definition_ref,
        expected_plan_digest = plan.plan_digest})
    local prepared = bounds.object(setup)
    if setup_error or not prepared or prepared.ok ~= true then
        return nil, setup_error and tostring(setup_error) or
            (prepared and type(prepared.error) == "string" and prepared.error or "Agent resource setup failed")
    end
    local request_id, request_error = uuid.v7()
    if not request_id then return nil, "Agent request identity: " .. tostring(request_error) end
    local admitted, admission_error = admission.admit_request({request_id = request_id,
        definition_ref = definition_ref, expected_plan_digest = plan.plan_digest,
        workspace_id = workspace_id, brief = "", mode = "window", origin_view = origin_view})
    if not admitted then return nil, fault(admission_error) end
    return admitted, nil
end

function M.run(launch: client.Launch, input: tty.EventChannel, lifecycle: Channel<process.Event>,
    closes: Channel<process.Message>): (admission.Admitted?, string?, boolean?, Channel<Activation>?)
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    local output = assert(tty.surface())
    local running = true
    local load_serial = 0
    local loads = channel.new(1)
    local activation_serial = 0
    local activations = channel.new(1) :: Channel<Activation>
    local activating = false
    -- The surface may close while admission is already executing. Closing the
    -- surface wins immediately and hands its one completion channel to the
    -- runtime, which revokes authority obtained before the cancellation.
    local function finish(admitted: admission.Admitted?, err: string?): (admission.Admitted?, string?, boolean?, Channel<Activation>?)
        local pending = activating
        running = false
        load_serial = load_serial + 1
        process.unlisten(states)
        local closed, close_error = output:close()
        local failure = not closed and ("Close profile screen: " .. tostring(close_error)) or err
        if pending then return nil, failure, true, activations end
        activation_serial = activation_serial + 1
        return admitted, failure, nil, nil
    end
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local listed: selection.Choices = {items = {}, unavailable = 0}
    local selected: integer = 0
    local status = "Loading profiles…"
    local loading = false
    local reload_pending = false
    local request_id: string? = nil
    local request_definition, request_plan = "", ""
    local editing: profile_view.State? = nil
    local edit_frame: profile_view.Frame = {rows = {}, hits = {}}
    local announced = false
    local dirty = true
    local frame: view.Frame = {rows = {}, first = 1, capacity = 0, hits = {}}
    local function load()
        if loading then reload_pending = true; return end
        load_serial = load_serial + 1
        local serial = load_serial
        loading = true
        listed = {items = {}, unavailable = 0}
        selected = 0
        status = "Loading profiles…"
        dirty = true
        coroutine.spawn(function()
            local choices, load_error = selection.snapshot(launch.workspace_id)
            if running and serial == load_serial then
                loads:send({serial = serial, choices = choices, error = load_error})
            end
        end)
    end
    process.send(launch.broker_pid, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"})
    while true do
        if dirty then
            local rows: {string}
            if editing then
                edit_frame = profile_view.draw(width, height, preferences, editing)
                rows = edit_frame.rows
            else
                frame = view.draw(width, height, preferences, listed, selected, status, activating)
                rows = frame.rows
            end
            assert(output:present(rows, {cursor = {x = 1, y = 1, visible = false}}))
            if not announced then client.ready(launch, {negotiate_close = true}); announced = true end
            dirty = false
        end
        if load_serial == 0 then load() end
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), closes:case_receive(),
            states:case_receive(), loads:case_receive(), activations:case_receive()})
        if not event.ok then return finish(nil, nil) end
        local activate, refresh = false, false
        local edit, duplicate = false, false
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then return finish(nil, nil) end
        elseif event.channel == closes then
            local close = client.close_request(launch, tostring(event.value:from()), event.value:payload():data())
            if close then client.close_reply(launch, close.request_id, {action = "accept"}); return finish(nil, nil) end
        elseif event.channel == states then
            if event.value:from() == launch.broker_pid then
                local payload: unknown = event.value:payload():data()
                local decoded = appearance.decode(payload)
                if decoded and type(payload) == "table" and payload.version == 1 then preferences = decoded; dirty = true end
            end
        elseif event.channel == loads then
            local result = event.value :: {serial: integer, choices: selection.Choices?, error: string?}
            if result.serial == load_serial then
                loading = false
                listed = {items = {}, unavailable = 0}
                if result.choices then listed = result.choices end
                selected = #listed.items > 0 and 1 or 0
                status = result.error or ""
                dirty = true
                if reload_pending then reload_pending = false; load() end
            end
        elseif event.channel == activations then
            local result = event.value :: Activation
            if result.serial == activation_serial then
                activating = false
                if result.admitted then
                    if result.title then client.title(launch, result.title) end
                    return finish(result.admitted, nil)
                end
                if result.error then
                    status = result.error
                else
                    local denied = result.refused and result.refused.error
                    if denied and denied.code == "CONFLICT" then
                        status = "Profile changed. Refresh and select it again."
                        listed = {items = {}, unavailable = 0}; selected = 0
                    else
                        status = denied and (denied.code .. ": " .. denied.message) or "Agent launch was not admitted"
                    end
                end
                dirty = true
            end
        else
            local data = input_event.decode(event.value)
            if data then
                if data.type == "close" then return finish(nil, nil)
                elseif data.type == "start" or data.type == "resize" then
                    width, height = data.width, data.height; dirty = true
                elseif editing then
                    local action = profile_view.input(editing, data, edit_frame)
                    if action == "cancel" then editing = nil
                    elseif action == "save" or action == "remove" then
                        local ok: boolean = false
                        local err: string? = nil
                        if action == "save" then ok, err = forms.save(editing.form)
                        else ok, err = forms.remove(editing.form) end
                        if ok then editing = nil; refresh = true
                        else editing.status = err or "Profile operation failed" end
                    end
                    dirty = true
                elseif data.type == "key" and data.action == "press" then
                    if data.key_type == "escape" or data.key_type == "esc" then return finish(nil, nil)
                    elseif data.key_type == "up" and selected > 0 and not activating then selected = math.floor(math.max(1, selected - 1)); dirty = true
                    elseif data.key_type == "down" and selected > 0 and not activating then selected = math.floor(math.min(#listed.items, selected + 1)); dirty = true
                    elseif data.key_type == "enter" and not activating then activate = true
                    elseif data.key == "r" and not data.ctrl and not data.alt and not activating then refresh = true
                    elseif data.key == "e" and not data.ctrl and not data.alt and not activating then edit = true
                    elseif data.key == "n" and not data.ctrl and not data.alt and not activating then edit = true; duplicate = true end
                elseif data.type == "mouse" then
                    if data.action == "wheel" then
                        if selected > 0 and not activating then
                            local delta = (data.button == "wheel_up" or data.button == "up") and -1 or 1
                            selected = math.floor(math.max(1, math.min(#listed.items, selected + delta))); dirty = true
                        end
                    elseif data.action == "press" and data.button == "left" then
                        for _, hit in ipairs(frame.hits) do
                            if data.y == hit.y and data.x >= hit.x and data.x < hit.x + hit.width then
                                if hit.action == "close" then return finish(nil, nil) end
                                if hit.action == "open" then activate = true end
                                if hit.action == "refresh" then refresh = true end
                                if hit.action == "edit" then edit = true end
                                if hit.action == "new" then edit = true; duplicate = true end
                            end
                        end
                        if not activating and data.y >= 3 and data.y < 3 + frame.capacity then
                            local index = frame.first + data.y - 3
                            if listed.items[index] then selected = index; dirty = true end
                        end
                    end
                end
            end
        end
        if edit then
            local choice = listed.items[selected]
            if choice then
                local opened, open_error = forms.load(launch.workspace_id, choice, duplicate)
                if opened then editing = profile_view.new(opened)
                else status = open_error or "Profile could not be opened" end
                dirty = true
            end
        end
        if activate and not loading and not activating and frame.capacity > 0 then
            local choice = listed.items[selected]
            if choice and not choice.unavailable then
                if not request_id or request_definition ~= choice.definition_ref or request_plan ~= choice.plan_digest then
                    request_id = assert(uuid.v7())
                    request_definition, request_plan = choice.definition_ref, choice.plan_digest
                end
                activation_serial = activation_serial + 1
                local serial = activation_serial
                local id = request_id :: string
                local selected_choice = choice
                activating = true
                status = "Starting Agent…"
                dirty = true
                coroutine.spawn(function()
                    local setup, setup_error = funcs.call("bee.harness.launch:setup", {
                        workspace_id = launch.workspace_id, definition_ref = selected_choice.definition_ref,
                        saved_profile_id = selected_choice.saved_profile_id, saved_profile_revision = selected_choice.saved_profile_revision,
                        expected_plan_digest = selected_choice.plan_digest})
                    local prepared = bounds.object(setup)
                    if setup_error or not prepared or prepared.ok ~= true then
                        activations:send({serial = serial, error = setup_error and tostring(setup_error) or
                            (prepared and type(prepared.error) == "string" and prepared.error or "Agent resource setup failed")})
                        return
                    end
                    if not running or serial ~= activation_serial then activations:send({serial = serial}); return end
                    local admitted, refused = admission.admit_request({request_id = id, definition_ref = selected_choice.definition_ref,
                        saved_profile_id = selected_choice.saved_profile_id, saved_profile_revision = selected_choice.saved_profile_revision,
                        expected_plan_digest = selected_choice.plan_digest, workspace_id = launch.workspace_id, brief = "", mode = "window",
                        origin_view = {view_id = launch.view_id, instance_id = launch.instance_id}})
                    activations:send({serial = serial, admitted = admitted, refused = refused, title = selected_choice.title})
                end)
            end
        end
        if refresh then
            load()
        end
    end
end
return M
