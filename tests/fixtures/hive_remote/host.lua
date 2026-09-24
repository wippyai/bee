-- MIT. Supervisor for remote Bee host acceptance test; runs on Node A.
local process = require("process")
local security = require("security")
local time = require("time")
local io = require("io")
local system = require("system")
local contract = require("contract")

local function main()
    local self = tostring(process.pid())
    local addr = assert(system.node.addr())
    local ready = assert(process.listen("bee.host.ready", {message = true}))
    local results = assert(process.listen("bee.host.client_result", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local phases = assert(process.listen("bee.hive_remote.active_done", {message = true}))

    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee:host_policy", "bee:host_spawn_policy", "bee:workspace_storage_policy"}) do
        local policy, err = security.policy(name)
        if not policy then error(tostring(err)) end
        policies[#policies + 1] = policy
    end

    local host = tostring(assert(process.with_options({}):with_scope(security.new_scope(policies))
        :with_context({["bee.host_owner"] = self}):spawn_monitored("bee.host:main", "bee:workers", self, {root_ref = "bee:workspace_root", subpath = ""})))

    local started = assert(ready:receive())
    assert(tostring(started:from()) == host, "Ready sender mismatch")
    local boot: unknown = started:payload():data()
    if type(boot) ~= "table" then error("Invalid host boot") end
    local workspace_id = contract.workspace_id(boot.workspace_id)
    if not workspace_id then error("Invalid workspace ID") end

    assert(io.print("BEE_HIVE_REMOTE host_ready " .. addr .. " " .. self .. " " .. host .. " " .. workspace_id))

    -- The host reports every admission change to its owner, including releases
    -- it starts on its own. Correlate on the request this supervisor issued.
    local function client_result(req_id: string, op: string): unknown
        while true do
            local res = assert(results:receive())
            assert(tostring(res:from()) == host, "Client result sender mismatch")
            local data: unknown = res:payload():data()
            if type(data) ~= "table" or data.version ~= 1 or data.workspace_id ~= workspace_id then
                error("Invalid client result payload")
            end
            if data.request_id == req_id and data.op == op then return data end
        end
    end

    -- A release the host already started for a departed client completes with
    -- no request id. Either completion for this recipient satisfies the owner.
    local function detach_result(req_id: string, target: string)
        while true do
            local res = assert(results:receive())
            assert(tostring(res:from()) == host, "Client result sender mismatch")
            local data: unknown = res:payload():data()
            if type(data) ~= "table" or data.version ~= 1 or data.workspace_id ~= workspace_id then
                error("Invalid client result payload")
            end
            if data.op == "detach" and data.recipient == target then
                if data.error_code == "" then return end
                if data.request_id == req_id and data.error_code ~= "busy" then
                    error("Host detach failed: " .. tostring(data.error))
                end
            end
        end
    end

    while true do
        local line: string = tostring(assert(io.readline()))
        local cmd, client_pid, requested_display_id = string.match(line, "^(%S+)%s*(%S*)%s*(%S*)$")
        if cmd == "desktop" then
            if not client_pid or client_pid == "" then error("Missing controller PID in desktop") end
            local authorized_controller = client_pid
            assert(io.print("BEE_HIVE_REMOTE desktop_ready " .. authorized_controller))
            while true do
                local phase = assert(phases:receive())
                assert(tostring(phase:from()) == authorized_controller, "Phase message sender mismatch: expected authorized controller " .. authorized_controller .. ", got " .. tostring(phase:from()))
                local phase_data: unknown = phase:payload():data()
                if type(phase_data) ~= "table" or phase_data.version ~= 1 then
                    error("Invalid phase message version or payload")
                end
                if phase_data.op == "admit_client" then
                    local req_id = phase_data.request_id
                    local target_client = phase_data.client
                    local display_id = contract.workspace_id(phase_data.display_id)
                    if type(req_id) ~= "string" or req_id == "" or type(target_client) ~= "string" or target_client == "" or not display_id then
                        error("Invalid admit_client fields")
                    end
                    assert(process.send(host, "bee.host.client", {
                        version = 1,
                        request_id = req_id,
                        op = "admit",
                        workspace_id = workspace_id,
                        recipient = target_client,
                        display_id = display_id,
                        permissions = {open = true, close = true, control = true, appearance = false},
                    }))
                    local res_data: unknown = client_result(req_id, "admit")
                    if type(res_data) ~= "table" or res_data.error_code ~= "" then
                        error("Host admission failed: " .. tostring(type(res_data) == "table" and res_data.error or "unknown"))
                    end
                    assert(process.send(authorized_controller, "bee.hive_remote.renderer_ack", {
                        version = 1,
                        request_id = req_id,
                        op = "admit_ack",
                        client = target_client,
                    }))
                    assert(io.print("BEE_HIVE_REMOTE admitted " .. target_client))
                elseif phase_data.op == "select_renderer" then
                    local req_id = phase_data.request_id
                    local target_client = phase_data.client
                    local renderer = phase_data.renderer
                    if type(req_id) ~= "string" or req_id == "" or type(target_client) ~= "string" or target_client == ""
                        or type(renderer) ~= "string" or renderer == "" then
                        error("Invalid select_renderer fields")
                    end
                    assert(process.send(host, "bee.host.client", {
                        version = 1,
                        request_id = req_id,
                        op = "render",
                        workspace_id = workspace_id,
                        recipient = target_client,
                        renderer = renderer,
                    }))
                    local res_data: unknown = client_result(req_id, "render")
                    if type(res_data) ~= "table" or res_data.error_code ~= "" then
                        error("Host render failed: " .. tostring(type(res_data) == "table" and res_data.error or "unknown"))
                    end
                    assert(process.send(authorized_controller, "bee.hive_remote.renderer_ack", {
                        version = 1,
                        request_id = req_id,
                        op = "render_ack",
                        renderer = renderer,
                    }))
                elseif phase_data.op == "detach_client" then
                    local req_id = phase_data.request_id
                    local target_client = phase_data.client
                    if type(req_id) ~= "string" or req_id == "" or type(target_client) ~= "string" or target_client == "" then
                        error("Invalid detach_client fields")
                    end
                    assert(process.send(host, "bee.host.client", {
                        version = 1,
                        request_id = req_id,
                        op = "detach",
                        workspace_id = workspace_id,
                        recipient = target_client,
                    }))
                    detach_result(req_id, target_client)
                    assert(process.send(authorized_controller, "bee.hive_remote.renderer_ack", {
                        version = 1,
                        request_id = req_id,
                        op = "detach_ack",
                        client = target_client,
                    }))
                    assert(io.print("BEE_HIVE_REMOTE detached " .. target_client))
                elseif phase_data.op == "done" then
                    break
                else
                    error("Unknown phase operation in desktop mode: " .. tostring(phase_data.op))
                end
            end
        elseif cmd == "admit" then
            if not client_pid or client_pid == "" then error("Missing client PID in admit") end
            local display_id = contract.workspace_id(requested_display_id)
            if not display_id then error("Missing durable display ID in admit") end
            assert(process.send(host, "bee.host.client", {
                version = 1,
                request_id = "admit-" .. client_pid,
                op = "admit",
                workspace_id = workspace_id,
                recipient = client_pid,
                display_id = display_id,
                permissions = {open = true, close = false, control = true},
            }))
            local res = assert(results:receive())
            assert(tostring(res:from()) == host, "Admission result sender mismatch")
            local data: unknown = res:payload():data()
            if type(data) ~= "table" or data.version ~= 1 or data.workspace_id ~= workspace_id
                or data.request_id ~= "admit-" .. client_pid or data.op ~= "admit" or data.error_code ~= "" then
                error("Host admission failed: " .. tostring(type(data) == "table" and data.error or "unknown"))
            end
            assert(io.print("BEE_HIVE_REMOTE admitted " .. client_pid))
            -- Wait through the actor inbox, without occupying the runtime's
            -- terminal reader while another actor starts a virtual terminal.
            while true do
                local phase = assert(phases:receive())
                assert(tostring(phase:from()) == client_pid, "Phase message sender mismatch: expected " .. client_pid .. ", got " .. tostring(phase:from()))
                local phase_data: unknown = phase:payload():data()
                if type(phase_data) ~= "table" or phase_data.version ~= 1 then
                    error("Invalid phase message version or payload")
                end
                if phase_data.op == "select_renderer" then
                    local req_id = phase_data.request_id
                    local renderer = phase_data.renderer
                    if type(req_id) ~= "string" or req_id == "" or type(renderer) ~= "string" or renderer == "" then
                        error("Invalid renderer selection request fields")
                    end
                    assert(process.send(host, "bee.host.client", {
                        version = 1,
                        request_id = req_id,
                        op = "render",
                        workspace_id = workspace_id,
                        recipient = client_pid,
                        renderer = renderer,
                    }))
                    local res = assert(results:receive())
                    assert(tostring(res:from()) == host, "Render result sender mismatch")
                    local res_data: unknown = res:payload():data()
                    if type(res_data) ~= "table" or res_data.version ~= 1 or res_data.workspace_id ~= workspace_id
                        or res_data.request_id ~= req_id or res_data.op ~= "render" or res_data.error_code ~= "" then
                        error("Host render failed: " .. tostring(type(res_data) == "table" and res_data.error or "unknown"))
                    end
                    assert(process.send(client_pid, "bee.hive_remote.renderer_ack", {
                        version = 1,
                        request_id = req_id,
                        renderer = renderer,
                    }))
                else
                    break
                end
            end
        elseif cmd == "detach" then
            if not client_pid or client_pid == "" then error("Missing client PID in detach") end
            assert(process.send(host, "bee.host.client", {
                version = 1,
                request_id = "detach-" .. client_pid,
                op = "detach",
                workspace_id = workspace_id,
                recipient = client_pid,
            }))
            local res = assert(results:receive())
            assert(tostring(res:from()) == host, "Detach result sender mismatch")
            local data: unknown = res:payload():data()
            if type(data) ~= "table" or data.version ~= 1 or data.workspace_id ~= workspace_id
                or data.request_id ~= "detach-" .. client_pid or data.op ~= "detach" or data.error_code ~= "" then
                error("Host detach failed: " .. tostring(type(data) == "table" and data.error or "unknown"))
            end
            assert(io.print("BEE_HIVE_REMOTE detached " .. client_pid))
        elseif cmd == "shutdown" then
            assert(process.send(host, "bee.app.request", {
                version = 1,
                request_id = "shutdown",
                op = "shutdown",
                workspace_id = workspace_id,
            }))
            local res = assert(replies:receive())
            assert(tostring(res:from()) == host, "Shutdown reply sender mismatch")
            local data: unknown = res:payload():data()
            if type(data) ~= "table" or data.version ~= 1 or data.workspace_id ~= workspace_id
                or data.request_id ~= "shutdown" or data.op ~= "shutdown" or data.error_code ~= "" then
                error("Host shutdown reply invalid or workspace mismatch")
            end
            assert(io.print("BEE_HIVE_REMOTE supervisor_done"))
            break
        else
            error("Unknown supervisor command: " .. tostring(cmd))
        end
    end

    process.unlisten(ready)
    process.unlisten(results)
    process.unlisten(replies)
    process.unlisten(phases)
end

return {main = main}
