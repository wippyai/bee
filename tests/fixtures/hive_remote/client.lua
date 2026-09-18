-- MIT. Remote client actor for Bee host admission acceptance test; runs on Node B.
local process = require("process")
local security = require("security")
local tty = require("tty")
local time = require("time")
local io = require("io")
local system = require("system")
local decode = require("decode")
local contract = require("contract")
local inventory = require("inventory")
local client_protocol = require("client_protocol")
local channel = require("channel")
local model = require("model")
local appearance = require("appearance")

local function command(view: tty.Viewport, text: string)
    assert(view:send({type = "paste", text = text}))
    assert(view:send({type = "key", key = "enter", key_type = "enter", action = "press"}))
end

local function wait_for(view: tty.Viewport, pattern: string): string
    for _ = 1, 300 do
        local frame = assert(view:snapshot())
        local found = table.concat(frame.rows, "\n"):match(pattern)
        if found then return found end
        time.sleep("20ms")
    end
    local frame = assert(view:snapshot())
    error("Missing native output matching pattern: " .. pattern .. "\n" .. table.concat(frame.rows, "\n"))
end

local function wait_attached(view: tty.Viewport, renderer: string, retained: string)
    for _ = 1, 300 do
        local frame = assert(view:snapshot())
        local text = table.concat(frame.rows, "\n")
        if text:find(renderer:sub(-12), 1, true) and text:find(retained, 1, true) then return end
        time.sleep("20ms")
    end
    error("New presenter did not display retained shell content: " .. renderer)
end

local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for _, name in ipairs(names) do
        local policy, err = security.policy(name)
        if not policy then error(tostring(err)) end
        policies[#policies + 1] = policy
    end
    local sc, sc_err = security.new_scope(policies)
    if not sc then error(tostring(sc_err)) end
    return sc
end

local function run_desktop(self: string, host_pid: string, workspace_id: string, supervisor_pid: string, proof_token: string, proof_file: string)
    local render_acks = assert(process.listen("bee.hive_remote.renderer_ack", {message = true}))
    local client_readies = assert(process.listen("bee.client.ready", {message = true}))
    local client_renderers = assert(process.listen("bee.client.renderer", {message = true}))
    local events: Channel<process.Event> = assert(process.events())

    -- Desktop hops race the monitored clients and a bound, so a stalled hop
    -- names itself and the controller reports it.
    local function hop(source: Channel<process.Message>, name: string)
        local deadline = time.after("30s")
        while true do
            local selected = channel.select({source:case_receive(), events:case_receive(), deadline:case_receive()})
            if not selected.ok then error("Desktop hop closed: " .. name) end
            if selected.channel == source then return selected.value end
            if selected.channel == deadline then error("Desktop hop did not complete: " .. name) end
            local event = selected.value
            if event.kind == process.event.CANCEL then error("Desktop hop cancelled: " .. name) end
            if event.kind == process.event.EXIT then
                error("Desktop hop lost " .. tostring(event.from) .. " (" .. tostring(event.error) .. "): " .. name)
            end
        end
        error("Desktop hop ended: " .. name)
    end

    -- Wait for cluster membership convergence (at least 2 members)
    for _ = 1, 200 do
        local members = system.cluster.members()
        if members and #members >= 2 then break end
        time.sleep("50ms")
    end

    -- Pre-admission remote request from this unadmitted controller actor
    assert(process.send(host_pid, "bee.app.request", {
        version = 1,
        request_id = "pre-admission-desktop",
        op = "open",
        workspace_id = workspace_id,
        connection_id = "unadmitted-pre-admit-desktop",
        definition_id = "bee.console:app",
    }))

    assert(io.print("BEE_HIVE_REMOTE client_ready " .. self))

    local client_scope = scope({"bee:desktop_policy", "bee:client_spawn_policy", "bee:client_storage_policy"})

    -- Step 1: Open actual Terminal from desktop path with initial app bootstrap
    local screen, disp_err = tty.viewport({width = 100, height = 32})
    if not screen then error("tty.viewport failed: " .. tostring(disp_err)) end
    local grant = assert(screen:grant())

    local client1_pid = tostring(assert(process.with_options({terminal = grant})
        :with_context({["bee.client_owner"] = self})
        :with_scope(client_scope)
        :spawn_monitored("bee.client:main", "bee:workers", self, host_pid, workspace_id, "bee:client_db",
            "bee.console:app", {version = 1, quit_mode = "detach", fullscreen = true})))

    local c1_ready_msg = hop(client_readies, "client 1 ready")
    assert(tostring(c1_ready_msg:from()) == client1_pid, "Client 1 ready sender mismatch")
    local c1_ready_data: unknown = c1_ready_msg:payload():data()
    local c1_display_id = type(c1_ready_data) == "table" and contract.workspace_id(c1_ready_data.client_id) or nil
    if type(c1_ready_data) ~= "table" or c1_ready_data.version ~= 1 or c1_ready_data.workspace_id ~= workspace_id or not c1_display_id then
        error("Invalid client 1 ready payload")
    end

    assert(process.send(supervisor_pid, "bee.hive_remote.active_done", {
        version = 1,
        request_id = "admit-c1",
        op = "admit_client",
        client = client1_pid,
        display_id = c1_display_id,
    }))
    local ack1 = hop(render_acks, "client 1 admission ack")
    assert(tostring(ack1:from()) == supervisor_pid, "Ack 1 sender mismatch")
    local ack1_data: unknown = ack1:payload():data()
    if type(ack1_data) ~= "table" or ack1_data.version ~= 1 or ack1_data.op ~= "admit_ack"
        or ack1_data.client ~= client1_pid then
        error("Invalid admit ack 1")
    end

    local rend1_msg = hop(client_renderers, "client 1 renderer")
    assert(tostring(rend1_msg:from()) == client1_pid, "Renderer 1 sender mismatch")
    local rend1_data: unknown = rend1_msg:payload():data()
    if type(rend1_data) ~= "table" or rend1_data.version ~= 1 or rend1_data.workspace_id ~= workspace_id
        or type(rend1_data.renderer) ~= "string" or rend1_data.renderer == "" then
        error("Invalid renderer 1 payload")
    end
    local renderer1_pid = rend1_data.renderer

    assert(process.send(supervisor_pid, "bee.hive_remote.active_done", {
        version = 1,
        request_id = "render-c1",
        op = "select_renderer",
        client = client1_pid,
        renderer = renderer1_pid,
    }))
    local ack_rend1 = hop(render_acks, "client 1 renderer ack")
    assert(tostring(ack_rend1:from()) == supervisor_pid, "Render ack 1 sender mismatch")
    local ack_rend1_data: unknown = ack_rend1:payload():data()
    if type(ack_rend1_data) ~= "table" or ack_rend1_data.version ~= 1 or ack_rend1_data.op ~= "render_ack"
        or ack_rend1_data.renderer ~= renderer1_pid then
        error("Invalid render ack 1")
    end

    -- Wait for actual bash prompt on local display
    local bash_seen = false
    for _ = 1, 300 do
        local frame = assert(screen:snapshot())
        local all_rows = table.concat(frame.rows, "\n")
        if all_rows:match("bash") or all_rows:match("[$#]") then
            bash_seen = true
            break
        end
        time.sleep("20ms")
    end
    assert(bash_seen, "Actual Bash prompt not rendered on display within 6s")

    -- Step 2: Enter command, prove destination-only nonce file and bash PID
    command(screen, "printf 'BEE_REMOTE_TOKEN=%s\\n' \"$(cat " .. proof_file .. ")\"")
    local found_token = wait_for(screen, "BEE_REMOTE_TOKEN=([%w_]+)")
    assert(found_token == proof_token, "Destination proof token mismatch: expected " .. proof_token .. ", got " .. tostring(found_token))

    command(screen, "printf 'BEE_REMOTE_PID_%s\\n' \"$$\"")
    local shell_pid = wait_for(screen, "BEE_REMOTE_PID_(%d+)")
    assert(shell_pid ~= "", "Destination bash PID not detected")

    local session_var_val = "DESKTOP_VAR_" .. proof_token
    command(screen, "BEE_DESKTOP_VAR='" .. session_var_val .. "'")
    command(screen, "printf 'BEE_DESKTOP_VAR_SET=%s\\n' \"$BEE_DESKTOP_VAR\"")
    assert(wait_for(screen, "BEE_DESKTOP_VAR_SET=([%w_]+)") == session_var_val, "Failed to set test session variable")

    -- Step 3: Resize local display and observe remote stty geometry
    assert(screen:resize(110, 36))
    -- Display resize and remote PTY resize are asynchronous. Send once and
    -- observe convergence at the destination, without retrying input delivery.
    command(screen, "for ((i=0;i<100;i++)); do [[ $(stty size) == '35 110' ]] && break; sleep .02; done; printf 'BEE_STTY_SIZE_%s\\n' \"$(stty size)\"")
    local stty_dims = wait_for(screen, "BEE_STTY_SIZE_(%d+%s+%d+)")
    assert(stty_dims:match("35%s+110"), "stty size does not match resized geometry 35 110: got " .. stty_dims)

    -- Step 4: F12 rejoin same Bash/variable
    assert(screen:send({type = "key", key = "f12", key_type = "f12", action = "press"}))
    local repl_msg = hop(client_renderers, "F12 replacement renderer")
    assert(tostring(repl_msg:from()) == client1_pid, "F12 renderer sender mismatch")
    local repl_data: unknown = repl_msg:payload():data()
    if type(repl_data) ~= "table" or repl_data.version ~= 1 or repl_data.workspace_id ~= workspace_id
        or type(repl_data.renderer) ~= "string" or repl_data.renderer == "" then
        error("Invalid F12 replacement renderer payload")
    end
    local repl_renderer_pid = repl_data.renderer

    assert(process.send(supervisor_pid, "bee.hive_remote.active_done", {
        version = 1,
        request_id = "rejoin-c1",
        op = "select_renderer",
        client = client1_pid,
        renderer = repl_renderer_pid,
    }))
    local ack_rejoin = hop(render_acks, "F12 renderer ack")
    assert(tostring(ack_rejoin:from()) == supervisor_pid, "Rejoin ack sender mismatch")
    local ack_rejoin_data: unknown = ack_rejoin:payload():data()
    if type(ack_rejoin_data) ~= "table" or ack_rejoin_data.version ~= 1 or ack_rejoin_data.op ~= "render_ack"
        or ack_rejoin_data.renderer ~= repl_renderer_pid then
        error("Invalid rejoin ack payload")
    end

    -- Both must appear in one frame: old content alone could be the retired display.
    wait_attached(screen, repl_renderer_pid, "BEE_STTY_SIZE_35 110")

    command(screen, "printf 'BEE_F12_PID_%s\\n' \"$$\"")
    assert(wait_for(screen, "BEE_F12_PID_(%d+)") == shell_pid, "F12 rejoin replaced destination shell PID")

    command(screen, "printf 'BEE_F12_VAR_%s\\n' \"$BEE_DESKTOP_VAR\"")
    assert(wait_for(screen, "BEE_F12_VAR_([%w_]+)") == session_var_val, "F12 rejoin lost destination shell variable")

    -- Step 5: Detach desktop client without stopping destination host/Terminal
    assert(screen:send({type = "key", key = "q", key_type = "runes", ctrl = true, action = "press"}))
    local c1_exited = false
    for _ = 1, 300 do
        local ev_sel = channel.select({events:case_receive(), time.after("20ms"):case_receive()})
        if ev_sel.ok and ev_sel.channel == events then
            local ev = ev_sel.value
            if ev.kind == process.event.EXIT and tostring(ev.from) == client1_pid then
                assert(ev.error == nil, "Client 1 exited with error: " .. tostring(ev.error))
                c1_exited = true
                break
            end
        end
    end
    assert(c1_exited, "Client 1 did not exit within 6s after Ctrl+Q detach")
    screen:close()

    -- A departed client keeps its display fenced on the host until the owner
    -- releases the admission. The controller observes its own client, so it
    -- drives that release before the display is attached again.
    assert(process.send(supervisor_pid, "bee.hive_remote.active_done", {
        version = 1,
        request_id = "detach-c1",
        op = "detach_client",
        client = client1_pid,
    }))
    local detach_ack = hop(render_acks, "client 1 detach ack")
    assert(tostring(detach_ack:from()) == supervisor_pid, "Detach ack sender mismatch")
    local detach_data: unknown = detach_ack:payload():data()
    if type(detach_data) ~= "table" or detach_data.version ~= 1 or detach_data.op ~= "detach_ack"
        or detach_data.client ~= client1_pid then
        error("Invalid client 1 detach ack")
    end

    -- Step 6: Fresh client with same local client store reattaches retained inventory and same shell
    local screen2, disp_err2 = tty.viewport({width = 100, height = 32})
    if not screen2 then error("tty.viewport failed for fresh client: " .. tostring(disp_err2)) end
    local grant2 = assert(screen2:grant())

    local client2_pid = tostring(assert(process.with_options({terminal = grant2})
        :with_context({["bee.client_owner"] = self})
        :with_scope(client_scope)
        :spawn_monitored("bee.client:main", "bee:workers", self, host_pid, workspace_id, "bee:client_db",
            nil, {version = 1, quit_mode = "detach", fullscreen = true})))

    local c2_ready_msg = hop(client_readies, "client 2 ready")
    assert(tostring(c2_ready_msg:from()) == client2_pid, "Client 2 ready sender mismatch")
    local c2_ready_data: unknown = c2_ready_msg:payload():data()
    local c2_display_id = type(c2_ready_data) == "table" and contract.workspace_id(c2_ready_data.client_id) or nil
    if type(c2_ready_data) ~= "table" or c2_ready_data.version ~= 1 or c2_ready_data.workspace_id ~= workspace_id or not c2_display_id then
        error("Invalid client 2 ready payload")
    end

    assert(process.send(supervisor_pid, "bee.hive_remote.active_done", {
        version = 1,
        request_id = "admit-c2",
        op = "admit_client",
        client = client2_pid,
        display_id = c2_display_id,
    }))
    local ack2 = hop(render_acks, "client 2 admission ack")
    assert(tostring(ack2:from()) == supervisor_pid, "Ack 2 sender mismatch")
    local ack2_data: unknown = ack2:payload():data()
    if type(ack2_data) ~= "table" or ack2_data.version ~= 1 or ack2_data.op ~= "admit_ack"
        or ack2_data.client ~= client2_pid then
        error("Invalid admit ack 2")
    end

    local rend2_msg = hop(client_renderers, "client 2 renderer")
    assert(tostring(rend2_msg:from()) == client2_pid, "Renderer 2 sender mismatch")
    local rend2_data: unknown = rend2_msg:payload():data()
    if type(rend2_data) ~= "table" or rend2_data.version ~= 1 or rend2_data.workspace_id ~= workspace_id
        or type(rend2_data.renderer) ~= "string" or rend2_data.renderer == "" then
        error("Invalid renderer 2 payload")
    end
    local renderer2_pid = rend2_data.renderer

    assert(process.send(supervisor_pid, "bee.hive_remote.active_done", {
        version = 1,
        request_id = "render-c2",
        op = "select_renderer",
        client = client2_pid,
        renderer = renderer2_pid,
    }))
    local ack_rend2 = hop(render_acks, "client 2 renderer ack")
    assert(tostring(ack_rend2:from()) == supervisor_pid, "Render ack 2 sender mismatch")
    local ack_rend2_data: unknown = ack_rend2:payload():data()
    if type(ack_rend2_data) ~= "table" or ack_rend2_data.version ~= 1 or ack_rend2_data.op ~= "render_ack"
        or ack_rend2_data.renderer ~= renderer2_pid then
        error("Invalid render ack 2")
    end

    wait_attached(screen2, renderer2_pid, "BEE_F12_VAR_" .. session_var_val)

    -- Verify same bash PID, shell variable, and proof token on reattached shell
    command(screen2, "printf 'BEE_REATTACH_PID_%s\\n' \"$$\"")
    assert(wait_for(screen2, "BEE_REATTACH_PID_(%d+)") == shell_pid, "Reattached client shell PID mismatch")

    command(screen2, "printf 'BEE_REATTACH_VAR_%s\\n' \"$BEE_DESKTOP_VAR\"")
    assert(wait_for(screen2, "BEE_REATTACH_VAR_([%w_]+)") == session_var_val, "Reattached client shell variable lost")

    command(screen2, "printf 'BEE_REATTACH_TOKEN=%s\\n' \"$(cat " .. proof_file .. ")\"")
    assert(wait_for(screen2, "BEE_REATTACH_TOKEN=([%w_]+)") == proof_token, "Destination proof token mismatch")

    -- Clean exit of fresh client
    assert(screen2:send({type = "key", key = "q", key_type = "runes", ctrl = true, action = "press"}))
    local c2_exited = false
    for _ = 1, 300 do
        local ev_sel = channel.select({events:case_receive(), time.after("20ms"):case_receive()})
        if ev_sel.ok and ev_sel.channel == events then
            local ev = ev_sel.value
            if ev.kind == process.event.EXIT and tostring(ev.from) == client2_pid then
                assert(ev.error == nil, "Client 2 exited with error: " .. tostring(ev.error))
                c2_exited = true
                break
            end
        end
    end
    assert(c2_exited, "Client 2 did not exit within 6s after Ctrl+Q detach")
    screen2:close()

    assert(process.send(supervisor_pid, "bee.hive_remote.active_done", {version = 1, op = "done"}))
    assert(io.print("BEE_HIVE_REMOTE client_passed"))

    process.unlisten(render_acks)
    process.unlisten(client_readies)
    process.unlisten(client_renderers)
end

local function main(host_pid: string, workspace_id: string, supervisor_pid: string, proof_token: string, proof_file: string, stall_probe: string?, presenter_stall: string?, desktop_probe: string?)
    local self = tostring(process.pid())
    assert(host_pid ~= "", "Missing host PID")
    assert(workspace_id ~= "", "Missing workspace ID")
    assert(supervisor_pid ~= "", "Missing supervisor PID")
    assert(proof_token ~= "", "Missing destination proof token")
    assert(proof_file ~= "", "Missing destination proof filename")

    if desktop_probe == "true" then
        return run_desktop(self, host_pid, workspace_id, supervisor_pid, proof_token, proof_file)
    end

    local admissions = assert(process.listen("bee.host.admitted", {message = true}))
    local replies = assert(process.listen("bee.host.reply", {message = true}))
    local catalogs = assert(process.listen("bee.host.catalog", {message = true}))
    local updates = assert(process.listen("bee.host.views", {message = true}))
    local controls = assert(process.listen("bee.workspace.control", {message = true}))
    local presentations = assert(process.listen("bee.host.presentation", {message = true}))
    local render_acks = assert(process.listen("bee.hive_remote.renderer_ack", {message = true}))
    local events: Channel<process.Event> = assert(process.events())

    -- Wait for cluster membership convergence (at least 2 members)
    for _ = 1, 200 do
        local members = system.cluster.members()
        if members and #members >= 2 then break end
        time.sleep("50ms")
    end

    -- Pre-admission remote request from this unadmitted client actor:
    -- Under Bee policy, unadmitted actors receive no reply and cause no side effects.
    assert(process.send(host_pid, "bee.app.request", {
        version = 1,
        request_id = "pre-admission-unadmitted",
        op = "open",
        workspace_id = workspace_id,
        connection_id = "unadmitted-pre-admit",
        definition_id = "bee.console:app",
    }))

    assert(io.print("BEE_HIVE_REMOTE client_ready " .. self))

    -- 1. Receive admission notification from host
    local adm_msg = assert(admissions:receive())
    -- Preserved authenticated remote sender check:
    assert(tostring(adm_msg:from()) == host_pid, "Admission sender mismatch: expected " .. host_pid .. ", got " .. tostring(adm_msg:from()))
    local adm_data: unknown = adm_msg:payload():data()
    if type(adm_data) ~= "table" or adm_data.version ~= 1 or adm_data.workspace_id ~= workspace_id
        or type(adm_data.connection_id) ~= "string" or adm_data.connection_id == ""
        or type(adm_data.renderer_generation) ~= "string" or adm_data.renderer_generation == "" then
        error("Invalid admission payload")
    end
    local connection_id = adm_data.connection_id
    local renderer_generation = adm_data.renderer_generation

    -- 2. Receive catalog snapshot from host
    local cat_msg = assert(catalogs:receive())
    assert(tostring(cat_msg:from()) == host_pid, "Catalog sender mismatch")
    local cat = inventory.catalog(cat_msg:payload():data())
    if not cat then error("Invalid host catalog") end
    assert(cat.workspace_id == workspace_id, "Catalog workspace mismatch")
    assert(cat.connection_id == connection_id, "Catalog connection mismatch")
    local has_terminal = false
    for _, item in ipairs(cat.items) do
        if item.definition_id == "bee.console:app" then has_terminal = true end
    end
    assert(has_terminal, "Host catalog missing bee.console:app")

    -- 3. Receive initial views snapshot from host; verify pre-admission request had no side effect
    local view_msg = assert(updates:receive())
    assert(tostring(view_msg:from()) == host_pid, "Views sender mismatch")
    local v = inventory.views(view_msg:payload():data())
    if not v then error("Invalid host views") end
    assert(v.workspace_id == workspace_id, "Views workspace mismatch")
    assert(v.connection_id == connection_id, "Views connection mismatch")
    assert(#v.items == 0, "Pre-admission request caused side effect: initial view items present")

    local function wait_reply(req_id: string, expected_op: string): decode.Reply
        while true do
            local rmsg = assert(replies:receive())
            assert(tostring(rmsg:from()) == host_pid, "Reply sender mismatch: expected " .. host_pid .. ", got " .. tostring(rmsg:from()))
            local env = client_protocol.result(rmsg:payload():data())
            if not env then error("Invalid client reply envelope") end
            local r = env.reply
            if r.request_id == req_id and r.op == expected_op then
                assert(r.workspace_id == workspace_id, "Reply workspace mismatch: expected " .. workspace_id .. ", got " .. tostring(r.workspace_id))
                assert(env.views.connection_id == connection_id, "Reply connection mismatch")
                return r
            end
        end
        error("Reply channel closed")
    end

    local opened: decode.Reply? = nil
    local attached: decode.Reply? = nil
    local view: tty.Viewport? = nil

    if presenter_stall == "true" then
        local display, disp_err = tty.viewport({width = 100, height = 35})
        if not display then error("tty.viewport failed: " .. tostring(disp_err)) end
        local grant = assert(display:grant())

        local pres_policy, pol_err = security.policy("bee:presenter_policy")
        if not pres_policy then error("Missing bee:presenter_policy: " .. tostring(pol_err)) end
        local pres_scope, scope_err = security.new_scope({pres_policy})
        if not pres_scope then error("security.new_scope failed: " .. tostring(scope_err)) end

        local presenter_pid = tostring(assert(process.with_options({terminal = grant})
            :with_context({["bee.workspace_owner"] = self, ["bee.workspace_id"] = workspace_id})
            :with_scope(pres_scope)
            :spawn_monitored("bee.terminal:main", "bee:workers", self, "bee.console:app", nil)))

        local ready_timer = time.after("3s")
        local ready_sel = channel.select({controls:case_receive(), ready_timer:case_receive()})
        assert(ready_sel.ok and ready_sel.channel == controls, "Presenter ready timed out")
        local ready_msg = ready_sel.value
        assert(tostring(ready_msg:from()) == presenter_pid, "Presenter ready sender mismatch")
        local ready_data: unknown = ready_msg:payload():data()
        if type(ready_data) ~= "table" or ready_data.version ~= 1 or ready_data.op ~= "ready" then
            error("Invalid presenter ready payload")
        end

        assert(process.send(supervisor_pid, "bee.hive_remote.active_done", {
            version = 1,
            request_id = "select-render-presenter",
            op = "select_renderer",
            renderer = presenter_pid,
        }))

        local ack_msg = assert(render_acks:receive())
        assert(tostring(ack_msg:from()) == supervisor_pid, "Renderer ack sender mismatch")
        local ack_data: unknown = ack_msg:payload():data()
        if type(ack_data) ~= "table" or ack_data.version ~= 1 or ack_data.request_id ~= "select-render-presenter" then
            error("Invalid renderer ack")
        end

        local pres_msg = assert(presentations:receive())
        assert(tostring(pres_msg:from()) == host_pid, "Presentation sender mismatch")
        local pres_data: unknown = pres_msg:payload():data()
        if type(pres_data) ~= "table" or pres_data.version ~= 1 or pres_data.workspace_id ~= workspace_id
            or pres_data.connection_id ~= connection_id or pres_data.renderer ~= presenter_pid
            or type(pres_data.generation) ~= "string" or pres_data.generation == "" then
            error("Invalid presentation payload after presenter selection")
        end
        renderer_generation = pres_data.generation

        assert(process.send(host_pid, "bee.app.request", {
            version = 1,
            request_id = "open-1",
            op = "open",
            workspace_id = workspace_id,
            connection_id = connection_id,
            definition_id = "bee.console:app",
        }))
        opened = wait_reply("open-1", "open")
        if opened.error_code ~= "" then error("Failed to open terminal: " .. opened.error) end
        assert(opened.id ~= "" and opened.instance_id ~= "", "Missing view or instance ID")

        assert(process.send(host_pid, "bee.app.request", {
            version = 1,
            request_id = "bind-1",
            op = "bind",
            workspace_id = workspace_id,
            connection_id = connection_id,
            renderer_generation = renderer_generation,
            id = opened.id,
            instance_id = opened.instance_id,
        }))
        local attached_pres = wait_reply("bind-1", "attached")
        if attached_pres.error_code ~= "" then error("Failed to attach terminal for presenter: " .. attached_pres.error) end
        assert(attached_pres.mount ~= "", "Empty mount returned by host")
        local bound_pres = wait_reply("bind-1", "bind")
        if bound_pres.error_code ~= "" then error("Bind reply reported error: " .. bound_pres.error) end

        assert(process.send(presenter_pid, "bee.app.reply", attached_pres))

        local scn: model.Scene = model.new(100, 35)
        scn = model.add(scn, opened.id, opened.instance_id, "Terminal", nil, workspace_id)
        scn = model.toggle_fullscreen(scn, opened.id)
        assert(process.send(presenter_pid, "bee.desktop.scene", {
            version = 1,
            scene = scn,
            tabs = {opened.id},
            preferences = appearance.defaults(),
            catalog = {},
        }))

        local bash_seen = false
        for _ = 1, 300 do
            local frame = assert(display:snapshot())
            local all_rows = table.concat(frame.rows, "\n")
            if all_rows:match("bash") or all_rows:match("[$#]") then
                bash_seen = true
                break
            end
            time.sleep("20ms")
        end
        assert(bash_seen, "Actual Bash prompt not rendered on display within 6s")

        command(display, "BEE_PRESENTER_VAR='" .. proof_token .. "'; printf 'BEE_PRESENTER_PID_%s\\n' \"$$\"")
        local presenter_shell_pid = wait_for(display, "BEE_PRESENTER_PID_(%d+)")

        assert(io.print("BEE_HIVE_REMOTE presenter_mounted"))
        local phase_in: string = tostring(assert(io.readline()))
        if phase_in ~= "paused" then error("Unexpected client test command: " .. phase_in) end

        local ok_paste, err_paste = display:send({type = "paste", text = "echo paused_input\n"})
        if not ok_paste then error("Display paste failed: " .. tostring(err_paste)) end

        local ok_key, err_key = display:send({type = "key", key = "x", key_type = "runes", action = "press"})
        if not ok_key then error("Display key failed: " .. tostring(err_key)) end

        local ok_res, err_res = display:resize(98, 33)
        if not ok_res then error("Display resize failed: " .. tostring(err_res)) end

        scn = model.resize_screen(scn, 98, 33)
        scn.revision = scn.revision + 1
        assert(process.send(presenter_pid, "bee.desktop.scene", {
            version = 1,
            scene = scn,
            tabs = {opened.id},
            preferences = appearance.defaults(),
            catalog = {},
        }))

        local ok_f1, err_f1 = display:send({type = "key", key = "f1", key_type = "f1", action = "press"})
        if not ok_f1 then error("Display F1 failed: " .. tostring(err_f1)) end

        local menu_seen = false
        for _ = 1, 50 do
            local frame = assert(display:snapshot())
            local all_rows = table.concat(frame.rows, "\n")
            if all_rows:match("BEE ▴") or all_rows:match("Exit") or all_rows:match("Open application") then
                menu_seen = true
                break
            end
            time.sleep("20ms")
        end
        assert(menu_seen, "Start menu did not appear within 1s while host was stopped")

        assert(display:send({type = "key", key = "escape", key_type = "escape", action = "press"}))
        for _ = 1, 300 do
            assert(display:send({type = "key", key = "x", key_type = "runes", action = "press"}))
        end
        wait_for(display, "(queue full)")

        local ok_f12, err_f12 = display:send({type = "key", key = "f12", key_type = "f12", action = "press"})
        if not ok_f12 then error("Display F12 failed: " .. tostring(err_f12)) end
        local rejoin_timer = time.after("1s")
        local rejoin_sel = channel.select({controls:case_receive(), rejoin_timer:case_receive()})
        assert(rejoin_sel.ok and rejoin_sel.channel ~= rejoin_timer, "F12 rejoin request not received within 1s while host was stopped")
        local rmsg = rejoin_sel.value
        assert(tostring(rmsg:from()) == presenter_pid, "Rejoin sender mismatch")
        local rdata: unknown = rmsg:payload():data()
        if type(rdata) ~= "table" or rdata.version ~= 1 or rdata.op ~= "rejoin" then
            error("Invalid rejoin payload")
        end

        assert(process.send(presenter_pid, "bee.workspace.retire", {version = 1}))
        local exit_timer = time.after("1s")
        local exited = false
        while not exited do
            local exit_sel = channel.select({events:case_receive(), exit_timer:case_receive()})
            assert(exit_sel.ok and exit_sel.channel ~= exit_timer, "Presenter did not exit within 1s after retire while host was stopped")
            if exit_sel.channel == events then
                local ev = exit_sel.value
                if ev.kind == process.event.EXIT and tostring(ev.from) == presenter_pid then
                    assert(ev.error == nil, "Presenter crashed during retirement: " .. tostring(ev.error))
                    exited = true
                end
            end
        end

        display:close()

        assert(io.print("BEE_HIVE_REMOTE presenter_responsive"))
        local resumed_in: string = tostring(assert(io.readline()))
        if resumed_in ~= "resumed" then error("Unexpected client test command: " .. resumed_in) end

        assert(process.send(supervisor_pid, "bee.hive_remote.active_done", {
            version = 1,
            request_id = "select-render-self",
            op = "select_renderer",
            renderer = self,
        }))
        local ack_self_msg = assert(render_acks:receive())
        assert(tostring(ack_self_msg:from()) == supervisor_pid, "Renderer ack self sender mismatch")
        local ack_self_data: unknown = ack_self_msg:payload():data()
        if type(ack_self_data) ~= "table" or ack_self_data.version ~= 1 or ack_self_data.request_id ~= "select-render-self" then
            error("Invalid renderer ack self")
        end

        local pres_self_msg = assert(presentations:receive())
        assert(tostring(pres_self_msg:from()) == host_pid, "Presentation self sender mismatch")
        local pres_self_data: unknown = pres_self_msg:payload():data()
        if type(pres_self_data) ~= "table" or pres_self_data.version ~= 1 or pres_self_data.workspace_id ~= workspace_id
            or pres_self_data.connection_id ~= connection_id or pres_self_data.renderer ~= self
            or type(pres_self_data.generation) ~= "string" or pres_self_data.generation == "" then
            error("Invalid presentation payload after self selection")
        end
        renderer_generation = pres_self_data.generation

        assert(process.send(host_pid, "bee.app.request", {
            version = 1,
            request_id = "bind-self",
            op = "bind",
            workspace_id = workspace_id,
            connection_id = connection_id,
            renderer_generation = renderer_generation,
            id = opened.id,
            instance_id = opened.instance_id,
        }))
        attached = wait_reply("bind-self", "attached")
        if attached.error_code ~= "" then error("Failed to attach terminal to self: " .. attached.error) end
        assert(attached.mount ~= "", "Empty mount returned by host")
        local bound_self = wait_reply("bind-self", "bind")
        if bound_self.error_code ~= "" then error("Bind reply reported error: " .. bound_self.error) end

        local v, v_err = tty.attach(attached.mount)
        if not v then error("tty.attach failed: " .. tostring(v_err)) end
        view = v

        assert(view:send({type = "key", key = "c", key_type = "c", ctrl = true, action = "press"}))
        time.sleep("50ms")
        assert(view:send({type = "key", key = "enter", key_type = "enter", action = "press"}))
        time.sleep("50ms")
        command(view, "printf 'BEE_AFTER_PRESENTER_PID_%s\\n' \"$$\"")
        assert(wait_for(view, "BEE_AFTER_PRESENTER_PID_(%d+)") == presenter_shell_pid,
            "Presenter retirement replaced the destination shell")
        command(view, "printf 'BEE_AFTER_PRESENTER_VAR_%s\\n' \"$BEE_PRESENTER_VAR\"")
        assert(wait_for(view, "BEE_AFTER_PRESENTER_VAR_([%w_]+)") == proof_token,
            "Presenter retirement lost destination shell state")
    else
        -- 4. Open terminal (bee.console:app)
        assert(process.send(host_pid, "bee.app.request", {
            version = 1,
            request_id = "open-1",
            op = "open",
            workspace_id = workspace_id,
            connection_id = connection_id,
            definition_id = "bee.console:app",
        }))
        opened = wait_reply("open-1", "open")
        if opened.error_code ~= "" then error("Failed to open terminal: " .. opened.error) end
        assert(opened.id ~= "" and opened.instance_id ~= "", "Missing view or instance ID")

        -- 5. Bind terminal view to get recipient-bound viewport mount
        assert(process.send(host_pid, "bee.app.request", {
            version = 1,
            request_id = "bind-1",
            op = "bind",
            workspace_id = workspace_id,
            connection_id = connection_id,
            renderer_generation = renderer_generation,
            id = opened.id,
            instance_id = opened.instance_id,
        }))
        attached = wait_reply("bind-1", "attached")
        if attached.error_code ~= "" then error("Failed to attach terminal: " .. attached.error) end
        assert(attached.mount ~= "", "Empty mount returned by host")
        local bound = wait_reply("bind-1", "bind")
        if bound.error_code ~= "" then error("Bind reply reported error: " .. bound.error) end

        -- 6. Attach remote native viewport
        local v, attach_err = tty.attach(attached.mount)
        if not v then error("tty.attach failed: " .. tostring(attach_err)) end
        view = v

        if stall_probe == "true" then
            assert(io.print("BEE_HIVE_REMOTE mounted"))
            assert(io.readline() == "paused")
            local completion = channel.new(1)
            local finished = false
            coroutine.spawn(function()
                local ok, err = view:resize(99, 34)
                finished = true
                completion:send({ok = ok, error = tostring(err)})
            end)
            time.sleep("100ms")
            assert(not finished, "Resize unexpectedly completed while host was stopped")
            assert(io.print("BEE_HIVE_REMOTE responsive"))
            local result: unknown = completion:receive()
            if type(result) ~= "table" or type(result.ok) ~= "boolean" or type(result.error) ~= "string" then
                error("Invalid resize completion")
            end
            assert(result.ok, result.error)
        end
    end

    if not view then error("Missing active viewport") end
    -- 7. Send shell command to read relative file and verify destination proof token
    command(view, "printf 'BEE_REMOTE_TOKEN=%s\\n' \"$(cat " .. proof_file .. ")\"")
    local found_token = wait_for(view, "BEE_REMOTE_TOKEN=([%w_]+)")
    assert(found_token == proof_token, "Host destination proof token mismatch: expected " .. proof_token .. ", got " .. tostring(found_token))

    -- Verify destination bash PID
    command(view, "printf 'BEE_REMOTE_OUT_%s_%s\\n' 'REMOTE_OK' \"$$\"")
    local remote_shell_pid = wait_for(view, "BEE_REMOTE_OUT_REMOTE_OK_(%d+)")
    assert(remote_shell_pid ~= "", "Destination bash PID not detected")

    -- Set test shell variable to verify state persistence across detach/re-admission in the same actor
    local session_var_val = "PERSIST_" .. proof_token
    command(view, "BEE_TEST_VAR='" .. session_var_val .. "'")
    command(view, "printf 'BEE_VAR_SET=%s\\n' \"$BEE_TEST_VAR\"")
    assert(wait_for(view, "BEE_VAR_SET=([%w_]+)") == session_var_val, "Failed to set test session variable")

    -- 8. Resize and verify stty dimensions
    assert(view:resize(100, 35))
    command(view, "stty size")
    local dims = wait_for(view, "35%s+100")
    assert(dims ~= "", "stty size does not match resized dimensions 35 100")

    -- 9. Check unadmitted control (e.g. invalid connection ID, stale renderer generation)
    assert(process.send(host_pid, "bee.app.request", {
        version = 1,
        request_id = "unadmitted-fake-conn",
        op = "open",
        workspace_id = workspace_id,
        connection_id = "fabricated-connection-id",
        definition_id = "bee.console:app",
    }))
    local unadmitted_reply = wait_reply("unadmitted-fake-conn", "open")
    assert(unadmitted_reply.error_code == "permission_denied", "Unadmitted connection was not denied")

    assert(process.send(host_pid, "bee.app.request", {
        version = 1,
        request_id = "stale-render-gen",
        op = "bind",
        workspace_id = workspace_id,
        connection_id = connection_id,
        renderer_generation = "stale-gen-token",
        id = opened.id,
        instance_id = opened.instance_id,
    }))
    local stale_reply = wait_reply("stale-render-gen", "bind")
    assert(stale_reply.error_code == "stale_renderer", "Stale renderer generation was not denied")

    local foreign_workspace = workspace_id == string.rep("0", 32) and string.rep("1", 32) or string.rep("0", 32)
    assert(process.send(host_pid, "bee.app.request", {
        version = 1, request_id = "foreign-workspace", op = "open",
        workspace_id = foreign_workspace, connection_id = connection_id,
        definition_id = "bee.console:app",
    }))
    assert(wait_reply("foreign-workspace", "open").error_code == "workspace_mismatch",
        "Foreign workspace request was not rejected")

    -- Signal active testing complete
    assert(process.send(supervisor_pid, "bee.hive_remote.active_done", {version = 1}))
    assert(io.print("BEE_HIVE_REMOTE client_active_done"))

    -- Wait for harness to signal that detach has completed
    local line: string = tostring(assert(io.readline()))
    if line ~= "verify_stale" then error("Unexpected client test command: " .. tostring(line)) end

    -- 10. Verify stale/revoked control after detach
    -- Owner revocation and the recipient's close notification travel on
    -- different channels. Wait boundedly for cached-view invalidation.
    local invalidated = false
    for _ = 1, 250 do
        local frame, frame_err = view:snapshot()
        if not frame and frame_err then invalidated = true; break end
        time.sleep("20ms")
    end
    assert(invalidated, "Detached client did not receive cached-view invalidation")

    local sent, send_err = view:send({type = "paste", text = "echo denied\n"})
    assert(not sent and send_err, "Detached client retained input authority")

    local resized, resize_err = view:resize(80, 24)
    assert(not resized and resize_err, "Detached client retained resize authority")

    assert(process.send(host_pid, "bee.app.request", {
        version = 1,
        request_id = "after-detach-req",
        op = "open",
        workspace_id = workspace_id,
        connection_id = connection_id,
        definition_id = "bee.console:app",
    }))
    -- Unadmitted actors receive no host inventory or reply. Re-admit this
    -- execution and verify that the old-connection request created no app.
    assert(io.print("BEE_HIVE_REMOTE client_stale_done"))
    local fresh_message = assert(admissions:receive())
    assert(tostring(fresh_message:from()) == host_pid, "Fresh admission sender mismatch")
    local fresh: unknown = fresh_message:payload():data()
    if type(fresh) ~= "table" or fresh.version ~= 1 or fresh.workspace_id ~= workspace_id
        or type(fresh.connection_id) ~= "string" or fresh.connection_id == "" or fresh.connection_id == connection_id
        or type(fresh.renderer_generation) ~= "string" or fresh.renderer_generation == ""
        or fresh.renderer_generation == renderer_generation then
        error("Invalid fresh admission identities: connection_id or renderer_generation not renewed")
    end
    connection_id = fresh.connection_id
    renderer_generation = fresh.renderer_generation
    local fresh_catalog_message = assert(catalogs:receive())
    assert(tostring(fresh_catalog_message:from()) == host_pid, "Fresh catalog sender mismatch")
    local fresh_catalog = inventory.catalog(fresh_catalog_message:payload():data())
    assert(fresh_catalog and fresh_catalog.workspace_id == workspace_id and fresh_catalog.connection_id == connection_id, "Fresh catalog mismatch")
    local fresh_views: inventory.Views? = nil
    while not fresh_views do
        local message = assert(updates:receive())
        assert(tostring(message:from()) == host_pid, "Fresh views sender mismatch")
        local value = inventory.views(message:payload():data())
        if value and value.connection_id == connection_id then fresh_views = value end
    end
    assert(fresh_views.workspace_id == workspace_id and #fresh_views.items == 1, "Detached request changed application inventory")
    assert(fresh_views.items[1].instance_id == opened.instance_id, "Re-admission replaced the running application")
    assert(process.send(host_pid, "bee.app.request", {version = 1, request_id = "rebind", op = "bind",
        workspace_id = workspace_id, connection_id = connection_id, renderer_generation = renderer_generation,
        id = opened.id, instance_id = opened.instance_id}))
    local rebound = wait_reply("rebind", "attached")
    assert(rebound.error_code == "" and rebound.mount ~= attached.mount, "Rebind attached mount invalid")
    assert(wait_reply("rebind", "bind").error_code == "", "Rebind bind reply failed")
    local rejoined, rejoin_error = tty.attach(rebound.mount)
    if not rejoined then error(tostring(rejoin_error)) end

    -- Verify same Bash PID
    command(rejoined, "printf 'BEE_REJOIN_PID_%s\\n' \"$$\"")
    assert(wait_for(rejoined, "BEE_REJOIN_PID_(%d+)") == remote_shell_pid, "Re-admission replaced the remote shell")

    -- Verify preserved test shell variable across detach and re-admission
    command(rejoined, "printf 'BEE_REJOIN_VAR=%s\\n' \"$BEE_TEST_VAR\"")
    assert(wait_for(rejoined, "BEE_REJOIN_VAR=([%w_]+)") == session_var_val, "Test shell variable not preserved across detach/re-admission")

    -- Verify destination proof token is still readable
    command(rejoined, "printf 'BEE_REJOIN_TOKEN=%s\\n' \"$(cat " .. proof_file .. ")\"")
    assert(wait_for(rejoined, "BEE_REJOIN_TOKEN=([%w_]+)") == proof_token, "Destination proof token mismatch on rejoined shell")

    rejoined:close()
    assert(process.send(supervisor_pid, "bee.hive_remote.active_done", {version = 1}))

    assert(io.print("BEE_HIVE_REMOTE client_passed"))

    if view then view:close() end
    process.unlisten(admissions)
    process.unlisten(replies)
    process.unlisten(catalogs)
    process.unlisten(updates)
    process.unlisten(controls)
    process.unlisten(presentations)
    process.unlisten(render_acks)
end

return {main = main}
