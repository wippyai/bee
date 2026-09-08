local process = require("process")
local channel = require("channel")
local ctx = require("ctx")
local contract = require("contract")
local commands = require("commands")
local state = require("state")
local appearance = require("appearance")

-- Only the attachment owner can mutate this private desktop session.
-- No application launch, terminal lease, or opaque handle enters its state.
local function main(owner: string, width: integer, height: integer, preferences: unknown)
    local command_channel = assert(process.listen("bee.desktop.command", {message = true}))
    local lifecycle = assert(process.events())
    local bootstrap: unknown = ctx.get("bee.workspace_owner")
    if bootstrap ~= owner or owner == "" then error("Untrusted session bootstrap") end
    local workspace_id = contract.workspace_id(ctx.get("bee.workspace_id"))
    if not workspace_id then error("Invalid workspace identity bootstrap") end
    assert(process.monitor(owner))
    local desktop = state.new(width, height, appearance.decode(preferences))

    local function send_scene()
        assert(process.send(owner, "bee.desktop.scene", state.envelope(desktop)))
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
            error_code = error_code,
            error = error,
        })
    end

    send_scene()
    while true do
        local selected = channel.select({command_channel:case_receive(), lifecycle:case_receive()})
        if not selected.ok then break end
        if selected.channel == lifecycle then
            if selected.value.kind == process.event.CANCEL then break end
            if selected.value.kind == process.event.EXIT and tostring(selected.value.from) == owner then break end
        else
            local msg = selected.value
            if msg:from() == owner then
                local raw: unknown = msg:payload():data()
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
    process.unlisten(command_channel)
end
return {main = main}
