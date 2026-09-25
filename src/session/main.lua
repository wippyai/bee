local process = require("process")
local channel = require("channel")
local ctx = require("ctx")
local contract = require("contract")
local commands = require("commands")
local state = require("state")
local appearance = require("appearance")
local decode = require("decode")
local funcs = require("funcs")
local time = require("time")
local uuid = require("uuid")
local status_bindings = require("status_bindings")
local statuses = require("statuses")
local status_driver = require("status_driver")
local status_reader = require("status_reader")
local handoff = require("handoff")

-- Only the attachment owner can mutate this private desktop session.
-- No application launch, terminal lease, or opaque handle enters its state.
local function main(owner: string, width: integer, height: integer, preferences: unknown, initial: unknown, resume: unknown)
    local command_channel = assert(process.listen("bee.desktop.command", {message = true}))
    local binding_channel = assert(process.listen("bee.desktop.bindings", {message = true}))
    local lifecycle = assert(process.events())
    local bootstrap: unknown = ctx.get("bee.workspace_owner")
    if bootstrap ~= owner or owner == "" then error("Untrusted session bootstrap") end
    local workspace_id = contract.workspace_id(ctx.get("bee.workspace_id"))
    if not workspace_id then error("Invalid workspace identity bootstrap") end
    local restored = resume ~= nil and handoff.decode(resume, workspace_id) or nil
    if resume ~= nil and not restored then error("Incompatible session process handoff") end
    assert(process.set_options({upgradable = true}))
    -- Supervision follows the PID through the runtime swap. Re-registering the
    -- same monitor is rejected by the scheduler.
    if not restored then assert(process.monitor(owner)) end
    local desktop = state.new(width, height, appearance.decode(preferences))
    if initial ~= nil then
        local initial_desktop = decode.desktop(initial)
        if not initial_desktop then error("Invalid session layout bootstrap") end
        for _, window in ipairs(initial_desktop.scene.windows) do
            if window.workspace_id ~= workspace_id then error("Foreign session layout bootstrap") end
        end
        desktop = {scene = initial_desktop.scene, tabs = initial_desktop.tabs,
            preferences = initial_desktop.preferences}
        desktop = state.reduce(desktop, {version = 1, op = "screen", width = width, height = height})
    end
    if restored then
        desktop = {scene = restored.desktop.scene, tabs = restored.desktop.tabs,
            preferences = restored.desktop.preferences}
    end

    local started = time.now()
    local function now(): integer return math.floor(time.now():sub(started):milliseconds()) end
    local readers = statuses.new(function(intent: status_reader.Intent): (funcs.Future?, string?)
        local future, err = funcs.async(intent.target, intent.request)
        if err then return nil, tostring(err) end
        return future, nil
    end)
    local deadline: time.Timer? = nil
    local status_revision = restored and restored.status_revision or 0
    if restored and restored.bindings then
        if not statuses.apply(readers, restored.bindings, desktop.scene, workspace_id, now()) then
            error("Incompatible session status bindings")
        end
    end
    local function send_scene()
        local envelope = state.envelope(desktop)
        if status_revision >= 9007199254740990 then error("Status revision exhausted") end
        status_revision = status_revision + 1
        assert(process.send(owner, "bee.desktop.scene", {scene = envelope.scene, tabs = envelope.tabs,
            preferences = envelope.preferences, status_revision = status_revision, statuses = statuses.values(readers)}))
    end

    local function send_ack(request_id: string, error_code: string, error: string)
        local envelope = state.envelope(desktop)
        -- Keep scene as the historical bare model.Scene while returning the
        -- complete projection so a preference result cannot race its scene.
        process.send(owner, "bee.desktop.ack", {
            version = 1, request_id = request_id,
            scene = envelope.scene,
            tabs = envelope.tabs,
            preferences = envelope.preferences,
            status_revision = status_revision, statuses = statuses.values(readers),
            error_code = error_code,
            error = error,
        })
    end

    local function run()
    send_scene()
    if restored then
        assert(process.send(owner, "bee.desktop.upgraded", {version = 1, workspace_id = workspace_id,
            pid = tostring(process.pid()), schema = 1}))
    end
    local upgrade_requested = false
    local queued = restored and restored.queued or {}
    while true do
        local cases = {command_channel:case_receive(), lifecycle:case_receive(), binding_channel:case_receive()}
        local next_due: integer? = nil
        local changed = false
        for _, current in pairs(readers.readers) do
            local availability = current.reader.availability
            local pending = status_driver.advance(current, uuid.v7(), now())
            if current.reader.availability ~= availability then changed = true end
            if pending then cases[#cases + 1] = pending.response:case_receive() end
            local due = pending and pending.deadline or current.due
            if not next_due or due < next_due then next_due = due end
        end
        if changed then send_scene() end
        if next_due then
            deadline = assert(time.timer(tostring(math.max(1, next_due - now())) .. "ms"))
            cases[#cases + 1] = deadline:channel():case_receive()
        end
        local pending = #queued > 0 and table.remove(queued, 1) or nil
        local selected
        if pending then
            selected = {ok = true, channel = pending.kind == "command" and command_channel or binding_channel}
        elseif upgrade_requested then
            -- Process already accepted work before the code swap. The runtime
            -- clears subscription channels on upgrade, so empty them first.
            selected = channel.select({command_channel:case_receive(), binding_channel:case_receive(),
                lifecycle:case_receive(), default = true})
            if selected.default then
                local binding_snapshot: unknown = nil
                if readers.bindings.revision > 0 then
                    binding_snapshot = {version = 1, workspace_id = workspace_id,
                        revision = readers.bindings.revision, items = readers.bindings.items}
                end
                local saved = handoff.pack(workspace_id, state.envelope(desktop), status_revision,
                    binding_snapshot, {})
                if not handoff.decode(saved, workspace_id) then error("Cannot checkpoint session for code upgrade") end
                statuses.close(readers)
                if deadline then deadline:stop(); deadline = nil end
                process.upgrade("", owner, width, height, preferences, initial, saved)
            end
        else selected = channel.select(cases) end
        if deadline then deadline:stop(); deadline = nil end
        for _, current in pairs(readers.readers) do
            local pending = current.pending
            if pending and selected.channel == pending.response then
                status_driver.complete(current, pending, now())
                send_scene()
                break
            end
        end
        if not selected.ok then break end
        if selected.channel == lifecycle then
            if selected.value.kind == process.event.CANCEL then break end
            if selected.value.kind == process.event.EXIT and tostring(selected.value.from) == owner then break end
            if selected.value.kind == process.event.OUTDATED then upgrade_requested = true end
        elseif selected.channel == binding_channel then
            local msg = selected.value
            if pending or msg:from() == owner then
                local snapshot = status_bindings.decode(pending and pending.payload or msg:payload():data())
                if snapshot and statuses.apply(readers, snapshot, desktop.scene, workspace_id, now()) then send_scene() end
            end
        elseif selected.channel == command_channel then
            local msg = selected.value
            if pending or msg:from() == owner then
                local raw: unknown = pending and pending.payload or msg:payload():data()
                local command = commands.decode(raw)
                if command and (command.op ~= "add" or command.workspace_id == workspace_id) then
                    if command.op == "shutdown" then
                        if command.request_id then send_ack(command.request_id, "", "") end
                        break
                    end

                    local stale = command.op == "appearance"
                        and command.expected_revision ~= nil
                        and command.expected_revision ~= desktop.scene.revision
                    if stale then
                        if command.request_id then send_ack(command.request_id, "stale_revision", "Desktop revision changed") end
                    else
                        local before = desktop
                        desktop = state.reduce(desktop, command)
                        statuses.layout(readers, desktop.scene, workspace_id, now())
                        if desktop ~= before or command.op == "snapshot" or command.op == "place" then send_scene() end
                        -- No-op commands still acknowledge the caller's input intent.
                        if command.request_id then send_ack(command.request_id, "", "") end
                    end
                else
                    -- Preserve correlation for malformed requests when the
                    -- caller supplied a bounded request ID. No state change
                    -- can occur because decoding failed at the boundary.
                    if type(raw) == "table" and type(raw.request_id) == "string"
                        and #raw.request_id <= 80 then
                        send_ack(raw.request_id, "invalid_command", "Command rejected")
                    end
                end
            end
        end
    end
    end
    local ok, err = pcall(run)
    if deadline then deadline:stop() end
    statuses.close(readers)
    process.unlisten(binding_channel)
    process.unlisten(command_channel)
    if not ok then error(err) end
end
return {main = main}
