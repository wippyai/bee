-- MIT. Actual actor clients, supervised admission and retained native PTYs.
local process = require("process")
local security = require("security")
local tty = require("tty")
local time = require("time")
local decode = require("decode")
local contract = require("contract")
local inventory = require("inventory")
local client_protocol = require("client_protocol")
local channel = require("channel")
type View = {id: string, instance_id: string, native_pid: string}
local M = {}
local function command(view: tty.Viewport, text: string)
    assert(view:send({type = "paste", text = text}))
    assert(view:send({type = "key", key = "enter", key_type = "enter", action = "press"}))
end
local function wait_for(view: tty.Viewport, pattern: string): string
    for _ = 1, 300 do
        local frame = assert(view:snapshot())
        local found = table.concat(frame.rows):match(pattern)
        if found then return found end
        time.sleep("10ms")
    end
    error("Missing native output: " .. pattern)
end
function M.client(owner: string, host: string, workspace_id: string, label: string, fail_commit: boolean?, definition_id: string?, preflight: boolean?)
    local admissions = assert(process.listen("bee.host.admitted", {message = true}))
    local replies = assert(process.listen("bee.host.reply", {message = true}))
    local commands = assert(process.listen("bee.client.command", {message = true}))
    local presentations = assert(process.listen("bee.host.presentation", {message = true}))
    local catalogs = assert(process.listen("bee.host.catalog", {message = true}))
    local updates = assert(process.listen("bee.host.views", {message = true}))
    local question_results = assert(process.listen("bee.host.question_result", {message = true}))
    local transfers = assert(process.listen("bee.host.transfer_result", {message = true}))
    local display_id = label == "A" and string.rep("a", 32) or string.rep("b", 32)
    local renderer_generation = ""
    local function status(phase: string, view: View?)
        assert(process.send(owner, "bee.client.status", {phase = phase, client_id = display_id, view = view}))
    end
    local function admission(): string
        local message = assert(admissions:receive())
        assert(message:from() == host)
        local data: unknown = message:payload():data()
        if type(data) ~= "table" or data.workspace_id ~= workspace_id or data.display_id ~= display_id
            or type(data.connection_id) ~= "string" or type(data.renderer_generation) ~= "string" then error("Invalid admission") end
        renderer_generation = data.renderer_generation
        return data.connection_id
    end
    local function reply(id: string, op: string): decode.Reply
        while true do
            local message = assert(replies:receive())
            assert(message:from() == host)
            local envelope = client_protocol.result(message:payload():data())
            if not envelope then error("Invalid client reply") end
            local value = envelope.reply
            if value.op == "open" and value.error_code == "" then
                local found = false
                for _, item in ipairs(envelope.views.items) do
                    if item.view_id == value.id and item.instance_id == value.instance_id then found = true end
                end
                assert(found, "Open result must carry its committed host inventory")
            end
            assert(decode.belongs(value, workspace_id))
            if value.request_id == id and value.op == op then return value end
        end
        error("Reply channel closed")
    end
    status("ready")
    local connection_id = admission()
    local last_revision = -1
    local function catalog()
        while true do
            local message = assert(catalogs:receive())
            assert(message:from() == host)
            local value = inventory.catalog(message:payload():data())
            if not value then error("Invalid host catalog") end
            if value.connection_id == connection_id then
                assert(value.workspace_id == workspace_id)
                local terminal = false
                for _, item in ipairs(value.items) do if item.definition_id == "bee.console:app" then terminal = true end end
                assert(terminal, "Host omitted its Terminal descriptor")
                return
            end
        end
    end
    local function views(sender: string, data: unknown): inventory.Views?
        assert(sender == host)
        local value = inventory.views(data)
        if not value then error("Invalid host views") end
        if value.connection_id ~= connection_id then return nil end
        assert(value.workspace_id == workspace_id and value.revision >= last_revision)
        last_revision = value.revision
        if type(data) ~= "table" or type(data.items) ~= "table" then error("Invalid raw views") end
        for _, item in pairs(data.items) do
            assert(type(item) == "table" and item.mount == nil and item.resume_state == nil and item.execution_pid == nil and item.permissions == nil, "Inventory disclosed authority or checkpoint data")
        end
        return value
    end
    local function wait_views(count: integer, title: string?)
        while true do
            local message = assert(updates:receive())
            local value = views(tostring(message:from()), message:payload():data())
            if value and #value.items == count then
                if not title then return end
                for _, item in ipairs(value.items) do if item.title == title then return end end
            end
        end
    end
    catalog()
    wait_views(definition_id ~= nil and 0 or (label == "A" and 0 or 1))
    if preflight then
        status("preflight")
        local message = assert(commands:receive())
        assert(message:from() == owner)
        local target: unknown = message:payload():data()
        if type(target) ~= "table" or type(target.id) ~= "string" or type(target.instance_id) ~= "string" then error("Invalid prepared bind target") end
        assert(process.send(host, "bee.app.request", {version = 1, request_id = "prepared-startup-bind", op = "bind", workspace_id = workspace_id,
            connection_id = connection_id, renderer_generation = renderer_generation, id = target.id, instance_id = target.instance_id}))
        assert(reply("prepared-startup-bind", "bind").error_code == "permission_denied", "Recovered manual transfer granted its source early")
        status("prepared-bind")
        local exit = assert(commands:receive())
        assert(exit:from() == owner and exit:payload():data() == "exit")
        for _, subscription in ipairs({admissions, replies, commands, presentations, catalogs, updates, question_results, transfers}) do process.unlisten(subscription) end
        return
    end
    local function presentation(renderer: string, code: string)
        local message = assert(presentations:receive())
        assert(message:from() == host)
        local data: unknown = message:payload():data()
        if type(data) ~= "table" or data.connection_id ~= connection_id or data.workspace_id ~= workspace_id
            or data.renderer ~= renderer or data.error_code ~= code or type(data.generation) ~= "string" then error("Invalid renderer state") end
        assert(renderer_generation ~= data.generation, "Renderer generation was reused")
        renderer_generation = data.generation
    end
    assert(process.send(host, "bee.app.request", {version = 1, request_id = "open", op = "open", workspace_id = workspace_id,
        connection_id = connection_id, definition_id = definition_id or "bee.console:app"}))
    local opened = reply("open", "open")
    assert(opened.error_code == "" and opened.mount == "" and opened.resume_state == "")
    assert(process.send(host, "bee.app.request", {version = 1, request_id = "bind", op = "bind", workspace_id = workspace_id,
        connection_id = connection_id, renderer_generation = renderer_generation, id = opened.id, instance_id = opened.instance_id}))
    local bound = reply("bind", "attached")
    assert(bound.error_code == "" and reply("bind", "bind").error_code == "")
    local view, view_error = tty.attach(bound.mount)
    if not view then error(tostring(view_error)) end
    local native_pid = "manual"
    if definition_id == nil then
        command(view, "bee_client=" .. label .. "; printf 'BEE_CLIENT_%s_%s\\n' \"$bee_client\" \"$$\"")
        native_pid = wait_for(view, "BEE_CLIENT_" .. label .. "_(%d+)")
    end
    wait_views(definition_id ~= nil and 1 or (label == "A" and 1 or 2))
    status("opened", {id = opened.id, instance_id = opened.instance_id, native_pid = native_pid})
    local observed: tty.Viewport? = nil
    local check_sequence = 0
    local observe_sequence = 0
    while true do
        local message = assert(commands:receive())
        assert(message:from() == owner)
        local op: unknown = message:payload():data()
        if type(op) == "table" and op.op == "render" and type(op.renderer) == "string" then
            local retired_generation = renderer_generation
            presentation(op.renderer, "")
            assert(process.send(host, "bee.app.request", {version = 1, request_id = "stale-render", op = "bind", workspace_id = workspace_id,
                connection_id = connection_id, renderer_generation = retired_generation, id = opened.id, instance_id = opened.instance_id}))
            assert(reply("stale-render", "bind").error_code == "stale_renderer")
            assert(process.send(host, "bee.app.request", {version = 1, request_id = "bind", op = "bind", workspace_id = workspace_id,
                connection_id = connection_id, renderer_generation = renderer_generation, id = opened.id, instance_id = opened.instance_id}))
            local attached = reply("bind", "attached")
            assert(attached.error_code == "" and reply("bind", "bind").error_code == "")
            local foreign, foreign_error = tty.attach(attached.mount)
            assert(not foreign and foreign_error, "Stable client consumed the renderer's mount")
            assert(process.send(op.renderer, "bee.renderer.mount", {mount = attached.mount, native_pid = native_pid, label = label}))
            status("delegated")
        elseif op == "render-failed" or op == "unrendered" then
            presentation(op == "render-failed" and tostring(process.pid()) or "", op == "render-failed" and "revoke_failed" or "")
            assert(process.send(host, "bee.app.request", {version = 1, request_id = "blocked-bind", op = "bind", workspace_id = workspace_id,
                connection_id = connection_id, renderer_generation = renderer_generation, id = opened.id, instance_id = opened.instance_id}))
            assert(reply("blocked-bind", "bind").error_code == (op == "render-failed" and "busy" or "unavailable"))
            status(op)
        elseif op == "render-cancelled" then
            presentation("", "cancelled")
            status("render-cancelled")
        elseif op == "inventory-two" or op == "inventory-three" then
            wait_views(op == "inventory-two" and 2 or 3, op == "inventory-three" and "Inventory probe" or nil)
            status(op)
        elseif op == "inventory-detached" then
            local deadline = time.after("100ms")
            while true do
                local selected = channel.select({updates:case_receive(), deadline:case_receive()})
                if selected.channel == deadline then break end
                assert(selected.ok)
                local message = selected.value
                local value = views(tostring(message:from()), message:payload():data())
                assert(not value or #value.items <= 2, "Detached client received a newly opened application")
            end
            status("inventory-detached")
        elseif type(op) == "table" and op.op == "observe" then
            if type(op.id) ~= "string" or type(op.instance_id) ~= "string" or type(op.native_pid) ~= "string" then error("Invalid observer target") end
            observe_sequence = observe_sequence + 1
            local observe_request = "observe-" .. tostring(observe_sequence)
            assert(process.send(host, "bee.app.request", {version = 1, request_id = observe_request, op = "bind", workspace_id = workspace_id,
                connection_id = connection_id, renderer_generation = renderer_generation, id = op.id, instance_id = op.instance_id, observer = false}))
            local attached = reply(observe_request, "attached")
            if op.expect_error == true then
                assert(attached.error_code == "revoke_failed" and attached.mount == "", "Failed revoke disclosed a grant")
                assert(reply(observe_request, "bind").error_code == "revoke_failed")
                if not observed then error("Lost previous observer") end
                assert(observed:snapshot(), "Failed revoke unexpectedly retired old observer")
                status("observe-failed")
            else
                assert(attached.error_code == "" and attached.observer == true, "Host did not clamp observer rights")
                assert(reply(observe_request, "bind").error_code == "")
                local mounted, mount_error = tty.attach(attached.mount)
                if not mounted then error(tostring(mount_error)) end
                if observed then
                    local stale, stale_error = observed:snapshot()
                    assert(not stale and stale_error, "Replaced observer mount remained readable")
                end
                observed = mounted
                wait_for(mounted, "BEE_CHECK_B_" .. op.native_pid)
                local sent, send_error = mounted:send({type = "key", key = "x", key_type = "runes", action = "press"})
                local resized, resize_error = mounted:resize(20, 10)
                assert(not sent and send_error and not resized and resize_error, "Observer gained control")
                status("observed")
            end
        elseif op == "observer-live" then
            if not observed then error("Missing observer attachment") end
            assert(observed:snapshot(), "Failed detach lost the owned grant")
            status("observer-live")
        elseif op == "observer-stale" then
            if not observed then error("Missing observer attachment") end
            local frame, frame_error = observed:snapshot()
            local sent, send_error = observed:send({type = "key", key = "x", key_type = "runes", action = "press"})
            local resized, resize_error = observed:resize(20, 10)
            assert(not frame and frame_error and not sent and send_error and not resized and resize_error, "Detached observer retained authority")
            status("observer-stale")
        elseif op == "check" then
            check_sequence = check_sequence + 1
            command(view, "printf 'BEE_CHECK_%s_%s_%s\\n' \"$bee_client\" \"$$\" " .. tostring(check_sequence))
            wait_for(view, "BEE_CHECK_" .. label .. "_" .. native_pid .. "_" .. tostring(check_sequence))
            status("checked")
        elseif type(op) == "table" and op.op == "accept-transfer" and type(op.id) == "string"
            and type(op.instance_id) == "string" and type(op.native_pid) == "string" and type(op.label) == "string" then
            -- This is the destination's ordinary, assignment-fenced bind.  It
            -- must attach the existing Terminal rather than launch a second
            -- application incarnation.
            assert(process.send(host, "bee.app.request", {version = 1, request_id = "accept-transfer", op = "bind", workspace_id = workspace_id,
                connection_id = connection_id, renderer_generation = renderer_generation, id = op.id, instance_id = op.instance_id}))
            local attached = reply("accept-transfer", "attached")
            assert(attached.error_code == "" and reply("accept-transfer", "bind").error_code == "")
            local transferred, transfer_error = tty.attach(attached.mount)
            if not transferred then error(tostring(transfer_error)) end
            command(transferred, "printf 'BEE_TRANSFER_%s_%s\\n' \"$bee_client\" \"$$\"")
            wait_for(transferred, "BEE_TRANSFER_" .. op.label .. "_" .. op.native_pid)
            status("accepted-transfer")
        elseif type(op) == "table" and op.op == "transfer-check" and type(op.target_display_id) == "string"
            and type(op.expected_revision) == "number" and type(op.request_id) == "string" and type(op.error_code) == "string" then
            assert(process.send(host, "bee.host.transfer", {version = 1, workspace_id = workspace_id,
                connection_id = connection_id, renderer_generation = renderer_generation, request_id = op.request_id,
                view_id = opened.id, instance_id = opened.instance_id, target_display_id = op.target_display_id,
                expected_revision = op.expected_revision}))
            local outcome = assert(transfers:receive())
            assert(outcome:from() == host)
            local value: unknown = outcome:payload():data()
            assert(type(value) == "table" and value.request_id == op.request_id and value.error_code == op.error_code,
                "Transfer rejection did not preserve the source assignment")
            status("transfer-checked")
        elseif type(op) == "table" and op.op == "transfer" and type(op.target_display_id) == "string" then
            assert(process.send(host, "bee.host.transfer", {version = 1, workspace_id = workspace_id,
                connection_id = connection_id, renderer_generation = renderer_generation, request_id = "fixture-transfer",
                view_id = opened.id, instance_id = opened.instance_id, target_display_id = op.target_display_id, expected_revision = 1}))
            local outcome = assert(transfers:receive())
            assert(outcome:from() == host)
            local value: unknown = outcome:payload():data()
            if fail_commit then
                assert(type(value) == "table" and value.request_id == "fixture-transfer" and value.error_code == "persistence_failed"
                    and value.assignment_revision == 0, "Commit failure did not leave the transfer prepared")
            else assert(type(value) == "table" and value.request_id == "fixture-transfer" and value.error_code == ""
                and value.assignment_revision == 2, "Transfer did not commit durable destination") end
            local stale, stale_error = view:snapshot()
            assert(not stale and stale_error, "Source retained its revoked controller")
            status(fail_commit and "transfer-commit-failed" or "transferred")
        elseif type(op) == "table" and op.op == "transfer-replay" and type(op.target_display_id) == "string" then
            -- A settled receipt is replayable even after its destination has
            -- detached.  It must not enqueue a second broker revocation.
            assert(process.send(host, "bee.host.transfer", {version = 1, workspace_id = workspace_id,
                connection_id = connection_id, renderer_generation = renderer_generation, request_id = "fixture-transfer",
                view_id = opened.id, instance_id = opened.instance_id, target_display_id = op.target_display_id, expected_revision = 1}))
            local outcome = assert(transfers:receive())
            assert(outcome:from() == host)
            local value: unknown = outcome:payload():data()
            assert(type(value) == "table" and value.request_id == "fixture-transfer" and value.error_code == ""
                and value.assignment_revision == 2, "Committed transfer receipt did not replay")
            status("transfer-replayed")
        elseif type(op) == "table" and op.op == "transfer-exact" and type(op.id) == "string"
            and type(op.instance_id) == "string" and type(op.target_display_id) == "string"
            and type(op.request_id) == "string" and type(op.expected_revision) == "number" then
            assert(process.send(host, "bee.host.transfer", {version = 1, workspace_id = workspace_id,
                connection_id = connection_id, renderer_generation = renderer_generation, request_id = op.request_id,
                view_id = op.id, instance_id = op.instance_id, target_display_id = op.target_display_id,
                expected_revision = op.expected_revision}))
            local outcome = assert(transfers:receive())
            assert(outcome:from() == host)
            local value: unknown = outcome:payload():data()
            assert(type(value) == "table" and value.request_id == op.request_id and value.error_code == ""
                and value.assignment_revision == op.expected_revision + 1, "Second transfer did not commit")
            status("transfer-exact")
        elseif op == "stale-bind" then
            assert(process.send(host, "bee.app.request", {version = 1, request_id = "stale-transfer-bind", op = "bind", workspace_id = workspace_id,
                connection_id = connection_id, renderer_generation = renderer_generation, id = opened.id, instance_id = opened.instance_id}))
            assert(reply("stale-transfer-bind", "bind").error_code == "permission_denied", "Stale source regained transfer control")
            status("stale-bind")
        elseif type(op) == "table" and op.op == "prepared-bind" and type(op.id) == "string" and type(op.instance_id) == "string" then
            assert(process.send(host, "bee.app.request", {version = 1, request_id = "prepared-transfer-bind", op = "bind", workspace_id = workspace_id,
                connection_id = connection_id, renderer_generation = renderer_generation, id = op.id, instance_id = op.instance_id}))
            assert(reply("prepared-transfer-bind", "bind").error_code == "permission_denied", "Prepared transfer granted its target early")
            status("prepared-bind")
        elseif op == "stale" then
            local frame, err = view:snapshot()
            assert(not frame and err, "Detached client retained its frame")
            local sent, input_error = view:send({type = "key", key = "x", key_type = "runes", action = "press"})
            assert(not sent and input_error, "Detached client retained input")
            status("stale")
        elseif op == "recontrol" then
            local fresh = admission()
            assert(fresh ~= connection_id)
            connection_id = fresh
            last_revision = -1
            catalog(); wait_views(2)
            status("recontrolled")
        elseif op == "readmit" then
            local fresh = admission()
            assert(fresh ~= connection_id)
            for _, token in ipairs({connection_id, fresh}) do
                assert(process.send(host, "bee.app.request", {version = 1, request_id = "forbidden", op = "open", workspace_id = workspace_id,
                    connection_id = token, definition_id = "bee.console:app"}))
                assert(reply("forbidden", "open").error_code == "permission_denied")
            end
            connection_id = fresh
            last_revision = -1
            catalog(); wait_views(2)
            assert(process.send(host, "bee.host.answer", {version = 1, workspace_id = workspace_id,
                connection_id = fresh, selection_revision = 1, request_id = "forbidden-answer",
                id = opened.id, instance_id = opened.instance_id, action = "accept", value = ""}))
            local denied = assert(question_results:receive())
            assert(denied:from() == host)
            local receipt: unknown = denied:payload():data()
            assert(type(receipt) == "table" and receipt.request_id == "forbidden-answer"
                and receipt.connection_id == fresh and receipt.workspace_id == workspace_id
                and receipt.error_code == "permission_denied", "Readmitted observer gained dialog control")
            status("denied")
        elseif op == "exit" then break
        else error("Invalid client test command") end
    end
    -- Deliberately rely on execution cleanup; the host must retire this admission.
    for _, subscription in ipairs({admissions, replies, commands, presentations, catalogs, updates, question_results, transfers}) do process.unlisten(subscription) end
end
function M.renderer(owner: string, client: string)
    local mounts = assert(process.listen("bee.renderer.mount", {message = true}))
    local commands = assert(process.listen("bee.renderer.command", {message = true}))
    local function status(phase: string) assert(process.send(owner, "bee.renderer.status", phase)) end
    status("ready")
    local mounted = assert(mounts:receive())
    assert(mounted:from() == client)
    local data: unknown = mounted:payload():data()
    if type(data) ~= "table" or type(data.mount) ~= "string" or type(data.native_pid) ~= "string" or type(data.label) ~= "string" then error("Invalid renderer mount") end
    local view, err = tty.attach(data.mount)
    if not view then error(tostring(err)) end
    command(view, "printf 'BEE_RENDERER_%s_%s\\n' \"$bee_client\" \"$$\"")
    wait_for(view, "BEE_RENDERER_" .. data.label .. "_" .. data.native_pid)
    status("mounted")
    while true do
        local message = assert(commands:receive())
        assert(message:from() == owner)
        local op: unknown = message:payload():data()
        if op == "exit" then break end
        assert(op == "stale")
        local frame, frame_error = view:snapshot()
        local sent, send_error = view:send({type = "key", key = "x", key_type = "runes", action = "press"})
        local resized, resize_error = view:resize(20, 10)
        assert(not frame and frame_error and not sent and send_error and not resized and resize_error, "Retired renderer retained authority")
        status("stale")
    end
    process.unlisten(mounts); process.unlisten(commands)
end
function M.main(fail_commit: boolean?)
    local owner = tostring(process.pid())
    local ready = assert(process.listen("bee.host.ready", {message = true}))
    local results = assert(process.listen("bee.host.client_result", {message = true}))
    local statuses = assert(process.listen("bee.client.status", {message = true}))
    local renderers = assert(process.listen("bee.renderer.status", {message = true}))
    local gates = assert(process.listen("bee.test.unbind_pending", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee.security.desktop:host_policy", "bee.security.desktop:host_spawn_policy", "bee.security.storage:workspace_storage_policy"}) do
        local policy, err = security.policy(name)
        if not policy then error(tostring(err)) end
        policies[#policies + 1] = policy
    end
    local host = tostring(assert(process.with_options({}):with_scope(security.new_scope(policies))
        :with_context({["bee.host_owner"] = owner, ["bee.test.fail_renderer_once"] = true,
            ["bee.test.fail_transfer_commit"] = fail_commit == true}):spawn_monitored("bee.host:main", "bee:workers", owner, {root_ref = "bee:workspace_root", subpath = ""})))
    local started = assert(ready:receive())
    assert(started:from() == host)
    local boot: unknown = started:payload():data()
    if type(boot) ~= "table" then error("Invalid host boot") end
    local workspace_id = contract.workspace_id(boot.workspace_id)
    if not workspace_id then error("Invalid workspace ID") end
    local policy, policy_error = security.policy("bee.attachment_probe:client_policy")
    if not policy then error(tostring(policy_error)) end
    local scope = security.new_scope({policy})
    local display_ids: {[string]: string} = {}
    local function status(pid: string, phase: string): View?
        local message = assert(statuses:receive())
        assert(message:from() == pid)
        local data: unknown = message:payload():data()
        if type(data) ~= "table" or data.phase ~= phase then error("Unexpected client phase") end
        local value = data.view
        if phase == "ready" then
            local display_id = contract.workspace_id(data.client_id)
            if not display_id then error("Invalid client display identity") end
            display_ids[pid] = display_id
        end
        if value == nil then return nil end
        if type(value) ~= "table" or type(value.id) ~= "string" or type(value.instance_id) ~= "string" or type(value.native_pid) ~= "string" then error("Invalid view state") end
        return {id = value.id, instance_id = value.instance_id, native_pid = value.native_pid}
    end
    local function result(id: string, recipient: string, expected: string)
        local message = assert(results:receive())
        assert(message:from() == host)
        local data: unknown = message:payload():data()
        assert(type(data) == "table" and data.request_id == id and data.recipient == recipient and data.error_code == expected)
    end
    local function admit(id: string, pid: string, allowed: boolean, expected: string, selected_display_id: string?)
        assert(process.send(host, "bee.host.client", {version = 1, request_id = id, op = "admit", workspace_id = workspace_id,
            recipient = pid, display_id = selected_display_id or display_ids[pid], permissions = {open = allowed, close = false, control = allowed}}))
        result(id, pid, expected)
    end
    local function reply(id: string, op: string): decode.Reply
        while true do
            local message = assert(replies:receive())
            assert(message:from() == host)
            local value = decode.reply(message:payload():data())
            if value then assert(decode.belongs(value, workspace_id)) end
            if value and value.request_id == id and value.op == op then return value end
        end
        error("Missing supervisor reply")
    end
    local function detach(id: string, pid: string)
        assert(process.send(host, "bee.host.client", {version = 1, request_id = id, op = "detach", workspace_id = workspace_id, recipient = pid}))
        result(id, pid, "")
    end
    local first = tostring(assert(process.with_options({}):with_scope(scope):spawn_monitored("bee.attachment_probe:client", "bee:workers", owner, host, workspace_id, "A", fail_commit)))
    status(first, "ready")
    admit("first", first, true, "")
    local first_view = status(first, "opened")
    if not first_view then error("Missing first view") end
    local second = tostring(assert(process.with_options({}):with_scope(scope):spawn_monitored("bee.attachment_probe:client", "bee:workers", owner, host, workspace_id, "B", fail_commit)))
    status(second, "ready")
    admit("same-recipient-display-conflict", first, true, "identity_conflict", display_ids[second])
    admit("duplicate-display-conflict", second, true, "identity_conflict", display_ids[first])
    admit("second", second, true, "")
    local second_view = status(second, "opened")
    if not second_view then error("Missing second view") end
    assert(first_view.id ~= second_view.id and first_view.native_pid ~= second_view.native_pid, "Client request IDs collided")
    assert(process.send(first, "bee.client.command", "inventory-two")); status(first, "inventory-two")
    local function renderer_status(pid: string, phase: string)
        local message = assert(renderers:receive())
        assert(message:from() == pid and message:payload():data() == phase, "Unexpected renderer status")
    end
    local function renderer(): string
        local pid = tostring(assert(process.with_options({}):with_scope(scope):spawn_monitored("bee.attachment_probe:renderer", "bee:workers", owner, first)))
        renderer_status(pid, "ready")
        return pid
    end
    local function select_renderer(id: string, client: string, target: string, expected: string)
        assert(process.send(host, "bee.host.client", {version = 1, request_id = id, op = "render", workspace_id = workspace_id, recipient = client, renderer = target}))
        result(id, client, expected)
    end
    local function delegate(target: string)
        assert(process.send(first, "bee.client.command", {op = "render", renderer = target}))
        status(first, "delegated"); renderer_status(target, "mounted")
    end
    local function stale_renderer(target: string)
        assert(process.send(target, "bee.renderer.command", "stale")); renderer_status(target, "stale")
    end
    local original_renderer = renderer()
    select_renderer("injected-failure", first, original_renderer, "revoke_failed")
    assert(process.send(first, "bee.client.command", "render-failed")); status(first, "render-failed")
    assert(process.send(first, "bee.client.command", "check")); status(first, "checked")
    select_renderer("first-renderer", first, original_renderer, ""); delegate(original_renderer)
    assert(process.send(first, "bee.client.command", "stale")); status(first, "stale")
    select_renderer("foreign-renderer", second, original_renderer, "permission_denied")
    local replacement = renderer()
    select_renderer("replacement", first, replacement, ""); delegate(replacement)
    stale_renderer(original_renderer)
    assert(process.send(second, "bee.client.command", "check")); status(second, "checked")
    assert(process.send(replacement, "bee.renderer.command", "exit"))
    result("", first, "")
    assert(process.send(first, "bee.client.command", "unrendered")); status(first, "unrendered")
    local final_renderer = renderer()
    select_renderer("final-renderer", first, final_renderer, ""); delegate(final_renderer)
    admit("cannot-replace", first, false, "busy")
    assert(process.send(host, "bee.host.client", {version = 1, request_id = "queued-render", op = "render", workspace_id = workspace_id, recipient = first, renderer = original_renderer}))
    local gated = assert(gates:receive())
    assert(process.send(host, "bee.host.client", {version = 1, request_id = "detach-first", op = "detach", workspace_id = workspace_id, recipient = first}))
    select_renderer("while-detaching", first, original_renderer, "busy")
    assert(process.send(gated:from(), "bee.test.release_unbind", {}))
    result("queued-render", first, "cancelled")
    result("detach-first", first, "")
    assert(process.send(first, "bee.client.command", "render-cancelled")); status(first, "render-cancelled")
    stale_renderer(final_renderer)
    assert(process.send(original_renderer, "bee.renderer.command", "exit"))
    assert(process.send(final_renderer, "bee.renderer.command", "exit"))
    assert(process.send(first, "bee.client.command", "stale")); status(first, "stale")
    assert(process.send(second, "bee.client.command", "check")); status(second, "checked")
    assert(process.send(host, "bee.app.request", {version = 1, request_id = "inventory-open", op = "open", workspace_id = workspace_id,
        definition_id = "bee.attachment_probe:app", arguments = {"inventory"}}))
    local third = reply("inventory-open", "open")
    assert(third.error_code == "")
    assert(process.send(second, "bee.client.command", "inventory-three")); status(second, "inventory-three")
    assert(process.send(first, "bee.client.command", "inventory-detached")); status(first, "inventory-detached")
    assert(process.send(host, "bee.app.request", {version = 1, request_id = "inventory-close", op = "close", workspace_id = workspace_id, id = third.id}))
    assert(reply("inventory-close", "close").error_code == "")
    assert(process.send(second, "bee.client.command", "inventory-two")); status(second, "inventory-two")
    admit("readmit-first", first, false, "")
    select_renderer("ungranted-renderer", first, second, "permission_denied")
    assert(process.send(first, "bee.client.command", "readmit")); status(first, "denied")
    assert(process.send(second, "bee.client.command", "check")); status(second, "checked")
    assert(process.send(first, "bee.client.command", {op = "observe", id = second_view.id,
        instance_id = second_view.instance_id, native_pid = second_view.native_pid})); status(first, "observed")
    assert(process.send(second, "bee.client.command", "check")); status(second, "checked")
    assert(process.send(first, "bee.client.command", {op = "observe", id = second_view.id, expect_error = true,
        instance_id = second_view.instance_id, native_pid = second_view.native_pid})); status(first, "observe-failed")
    assert(process.send(second, "bee.client.command", "check")); status(second, "checked")
    assert(process.send(first, "bee.client.command", {op = "observe", id = second_view.id,
        instance_id = second_view.instance_id, native_pid = second_view.native_pid})); status(first, "observed")
    assert(process.send(second, "bee.client.command", "check")); status(second, "checked")
    assert(process.send(host, "bee.host.client", {version = 1, request_id = "observer-detach-failure", op = "detach",
        workspace_id = workspace_id, recipient = first}))
    result("observer-detach-failure", first, "revoke_failed")
    assert(process.send(first, "bee.client.command", "observer-live")); status(first, "observer-live")
    assert(process.send(second, "bee.client.command", "check")); status(second, "checked")
    detach("detach-again", first)
    assert(process.send(first, "bee.client.command", "observer-stale")); status(first, "observer-stale")
    assert(process.send(second, "bee.client.command", "check")); status(second, "checked")
    admit("observer-first", first, false, "")
    assert(process.send(first, "bee.client.command", "readmit")); status(first, "denied")
    assert(process.send(second, "bee.client.command", {op = "transfer-check", request_id = "observer-target",
        target_display_id = display_ids[first], expected_revision = 1, error_code = "unavailable"}))
    status(second, "transfer-checked")
    detach("detach-observer-first", first)
    admit("recontrol-first", first, true, "")
    assert(process.send(first, "bee.client.command", "recontrol")); status(first, "recontrolled")
    assert(process.send(second, "bee.client.command", {op = "transfer-check", request_id = "self-target",
        target_display_id = display_ids[second], expected_revision = 1, error_code = "invalid_target"}))
    status(second, "transfer-checked")
    assert(process.send(second, "bee.client.command", {op = "transfer-check", request_id = "stale-revision",
        target_display_id = display_ids[first], expected_revision = 2, error_code = "stale_assignment"}))
    status(second, "transfer-checked")
    assert(process.send(second, "bee.client.command", {op = "transfer-check", request_id = "missing-target",
        target_display_id = string.rep("c", 32), expected_revision = 1, error_code = "unavailable"}))
    status(second, "transfer-checked")
    assert(process.send(second, "bee.client.command", {op = "transfer", target_display_id = display_ids[first]}))
    status(second, fail_commit and "transfer-commit-failed" or "transferred")
    assert(process.send(second, "bee.client.command", "stale-bind")); status(second, "stale-bind")
    if fail_commit then
        assert(process.send(first, "bee.client.command", {op = "prepared-bind", id = second_view.id, instance_id = second_view.instance_id})); status(first, "prepared-bind")
        process.terminate(host)
        return
    end
    assert(process.send(first, "bee.client.command", {op = "accept-transfer", id = second_view.id,
        instance_id = second_view.instance_id, native_pid = second_view.native_pid, label = "B"}))
    status(first, "accepted-transfer")
    assert(process.send(first, "bee.client.command", {op = "transfer-exact", request_id = "fixture-transfer-again",
        id = second_view.id, instance_id = second_view.instance_id, target_display_id = display_ids[second], expected_revision = 2}))
    status(first, "transfer-exact")
    assert(process.send(second, "bee.client.command", {op = "accept-transfer", id = second_view.id,
        instance_id = second_view.instance_id, native_pid = second_view.native_pid, label = "B"}))
    status(second, "accepted-transfer")
    assert(process.send(second, "bee.client.command", {op = "transfer-replay", target_display_id = display_ids[first]}))
    status(second, "transfer-replayed")
    assert(process.send(second, "bee.client.command", {op = "transfer-check", request_id = "fixture-transfer",
        target_display_id = string.rep("c", 32), expected_revision = 1, error_code = "conflict"}))
    status(second, "transfer-checked")
    assert(process.send(second, "bee.client.command", "exit"))
    result("", second, "")
    assert(process.send(first, "bee.client.command", "exit"))
    for index, state in ipairs({first_view, second_view}) do
        local id = "inspect-" .. tostring(index)
        assert(process.send(host, "bee.app.request", {version = 1, request_id = id, op = "bind", workspace_id = workspace_id,
            id = state.id, instance_id = state.instance_id, recipient = owner}))
        local mounted = reply(id, "attached")
        assert(mounted.error_code == "" and reply(id, "bind").error_code == "")
        local view, err = tty.attach(mounted.mount)
        if not view then error(tostring(err)) end
        command(view, "printf 'BEE_RETAINED_%s_%s\\n' \"$bee_client\" \"$$\"")
        wait_for(view, "BEE_RETAINED_" .. (index == 1 and "A" or "B") .. "_" .. state.native_pid)
        view:close()
    end
    assert(process.send(host, "bee.app.request", {version = 1, request_id = "stop", op = "shutdown", workspace_id = workspace_id}))
    assert(reply("stop", "shutdown").error_code == "")
    for _, subscription in ipairs({ready, results, statuses, replies, renderers, gates}) do process.unlisten(subscription) end
end
return M
