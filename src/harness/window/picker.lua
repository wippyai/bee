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
local M = {}
type Channel = channel.Channel
function M.run(launch: client.Launch, input: tty.EventChannel, lifecycle: Channel<process.Event>,
    closes: Channel<process.Message>): (admission.Admitted?, string?)
    local states = assert(process.listen("bee.appearance.state", {message = true}))
    local output = assert(tty.surface())
    local function finish(admitted: admission.Admitted?, err: string?): (admission.Admitted?, string?)
        process.unlisten(states)
        local closed, close_error = output:close()
        if not closed then return nil, "Close profile screen: " .. tostring(close_error) end
        return admitted, err
    end
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()
    local choices, load_error = selection.snapshot(launch.workspace_id)
    local listed: selection.Choices = {items = {}, unavailable = 0}
    if choices then listed = choices end
    local selected: integer = #listed.items > 0 and 1 or 0
    local status = load_error or ""
    local request_id: string? = nil
    local request_definition, request_plan = "", ""
    local announced = false
    local dirty = true
    local frame: view.Frame = {rows = {}, first = 1, capacity = 0, hits = {}}
    process.send(launch.broker_pid, "bee.appearance.request", {version = 1, request_id = uuid.v7(), op = "state"})
    while true do
        if dirty then
            frame = view.draw(width, height, preferences, listed, selected, status)
            assert(output:present(frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
            if not announced then client.ready(launch, {negotiate_close = true}); announced = true end
            dirty = false
        end
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), closes:case_receive(), states:case_receive()})
        if not event.ok then return finish(nil, nil) end
        local activate, refresh = false, false
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
        else
            local data = input_event.decode(event.value)
            if data then
                if data.type == "close" then return finish(nil, nil)
                elseif data.type == "start" or data.type == "resize" then
                    width, height = data.width, data.height; dirty = true
                elseif data.type == "key" and data.action == "press" then
                    if data.key_type == "escape" or data.key_type == "esc" then return finish(nil, nil)
                    elseif data.key_type == "up" then selected = math.floor(math.max(1, selected - 1)); dirty = true
                    elseif data.key_type == "down" then selected = math.floor(math.min(#listed.items, selected + 1)); dirty = true
                    elseif data.key_type == "enter" then activate = true
                    elseif data.key == "r" and not data.ctrl and not data.alt then refresh = true end
                elseif data.type == "mouse" then
                    if data.action == "wheel" then
                        local delta = (data.button == "wheel_up" or data.button == "up") and -1 or 1
                        selected = math.floor(math.max(1, math.min(#listed.items, selected + delta))); dirty = true
                    elseif data.action == "press" and data.button == "left" then
                        for _, hit in ipairs(frame.hits) do
                            if data.y == hit.y and data.x >= hit.x and data.x < hit.x + hit.width then
                                if hit.action == "close" then return finish(nil, nil) end
                                if hit.action == "open" then activate = true end
                                if hit.action == "refresh" then refresh = true end
                            end
                        end
                        if data.y >= 3 and data.y < 3 + frame.capacity then
                            local index = frame.first + data.y - 3
                            if listed.items[index] then selected = index; dirty = true end
                        end
                    end
                end
            end
        end
        if activate and frame.capacity > 0 then
            local choice = listed.items[selected]
            if choice and not choice.unavailable then
                if not request_id or request_definition ~= choice.definition_ref or request_plan ~= choice.plan_digest then
                    request_id = assert(uuid.v7())
                    request_definition, request_plan = choice.definition_ref, choice.plan_digest
                end
                local setup, setup_error = funcs.call("bee.harness.launch:setup", {
                    workspace_id = launch.workspace_id, definition_ref = choice.definition_ref,
                    saved_profile_id = choice.saved_profile_id, saved_profile_revision = choice.saved_profile_revision,
                    expected_plan_digest = choice.plan_digest})
                local prepared = bounds.object(setup)
                if setup_error or not prepared or prepared.ok ~= true then
                    status = setup_error and tostring(setup_error) or
                        (prepared and type(prepared.error) == "string" and prepared.error or "Agent resource setup failed")
                    dirty = true
                else
                    local admitted, refused = admission.admit_request({request_id = request_id, definition_ref = choice.definition_ref,
                        saved_profile_id = choice.saved_profile_id, saved_profile_revision = choice.saved_profile_revision,
                        expected_plan_digest = choice.plan_digest, workspace_id = launch.workspace_id, brief = "", mode = "window"})
                    if admitted then
                        client.title(launch, choice.title)
                        return finish(admitted, nil)
                    end
                    local fault = refused and refused.error
                    if fault and fault.code == "CONFLICT" then
                        status = "Profile changed. Refresh and select it again."
                        listed = {items = {}, unavailable = 0}; selected = 0; dirty = true
                    else
                        status = fault and (fault.code .. ": " .. fault.message) or "Agent launch was not admitted"
                        dirty = true
                    end
                end
            end
        end
        if refresh then
            local next_choices, next_error = selection.snapshot(launch.workspace_id)
            listed = {items = {}, unavailable = 0}
            if next_choices then listed = next_choices end
            selected = #listed.items > 0 and 1 or 0
            status = next_error or ""; dirty = true
        end
    end
end
return M
