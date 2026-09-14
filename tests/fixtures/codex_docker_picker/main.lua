-- SPDX-License-Identifier: MIT
-- Drives the production Agent picker into the optional Codex Docker profile.
-- The Go acceptance inspects the running container, then releases this owner
-- to close the application through its ordinary broker lifecycle.
local process = require("process")
local channel = require("channel")
local time = require("time")
local security = require("security")
local tty = require("tty")
local registry = require("registry")
local fs = require("fs")
local appearance = require("appearance")

local WORKSPACE = string.rep("d", 32)

local function object(value: unknown): {[string]: unknown}
    if type(value) ~= "table" then error("missing object") end
    return value :: {[string]: unknown}
end

local function write(name: string, value: string)
    local root = assert(fs.get("bee.codex_docker_picker_fixture:evidence"))
    local file = assert(root:open("/" .. name, "w"))
    assert(file:write(value))
    file:close()
end

local function exists(name: string): boolean
    local root = assert(fs.get("bee.codex_docker_picker_fixture:evidence"))
    local file = root:open("/" .. name, "r")
    if not file then return false end
    file:close()
    return true
end

local function send(view: tty.Viewport, event: tty.TTYEvent, label: string)
    local ok, err = view:send(event)
    if not ok then error(label .. ": " .. tostring(err)) end
end

local function hide_other_profiles()
    local found = assert(registry.find({["meta.type"] = "bee.launch_definition"}))
    for _, raw in ipairs(found) do
        local entry = object(raw)
        if entry.id ~= "bee.driver.codex.docker:launch" then
            local changed: {[string]: unknown} = {}
            for key, value in pairs(entry) do changed[key] = value end
            local data: {[string]: unknown} = {}
            for key, value in pairs(entry.data :: {[string]: unknown}) do data[key] = value end
            data.presentation = {start_menu = false, fullscreen = false, reuse = "never"}
            changed.data = data
            local changes = registry.snapshot():changes()
            changes:update(changed)
            assert(changes:apply())
        end
    end
end

local function run()
    hide_other_profiles()
    local owner = tostring(process.pid())
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local checkpoints = assert(process.listen("bee.application.checkpoint", {message = true}))
    local events = assert(process.events())
    local broker_policy = assert(security.policy("bee:broker_policy"))
    local boundary = assert(security.policy("bee:core_spawn_boundary"))
    local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = WORKSPACE})
        :with_scope(security.new_scope({broker_policy, boundary}))
        :spawn_monitored("bee.applications:broker", "bee:workers", owner, appearance.defaults())))
    local ready_deadline = time.after("5s")
    while true do
        local selected = channel.select({catalogs:case_receive(), events:case_receive(), ready_deadline:case_receive()})
        assert(selected.ok and selected.channel ~= ready_deadline, "broker catalog timed out")
        if selected.channel == catalogs then break end
        if selected.value.kind == process.event.EXIT and tostring(selected.value.from) == broker then error("broker exited") end
    end
    local function receive_reply(): {[string]: unknown}
        local selected = channel.select({replies:case_receive(), time.after("8s"):case_receive()})
        assert(selected.ok and selected.channel == replies, "broker reply timed out")
        return object(selected.value:payload():data())
    end
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "open", op = "open", workspace_id = WORKSPACE,
        definition_id = "bee.harness.window:app", arguments = {}}))
    local opened: {[string]: unknown}? = nil
    while not opened do
        local data = receive_reply()
        if data.request_id == "open" and data.op == "open" then opened = data end
    end
    assert(opened.error_code == "", tostring(opened.error))
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "bind", op = "bind", workspace_id = WORKSPACE,
        id = opened.id, instance_id = opened.instance_id, recipient = owner}))
    local mount = ""
    while mount == "" do
        local data = receive_reply()
        if data.request_id == "bind" and data.op == "attached" then assert(data.error_code == ""); mount = tostring(data.mount) end
    end
    local view = assert(tty.attach(mount))
    send(view, {type = "resize", width = 91, height = 27}, "resize picker")
    for _ = 1, 200 do
        local frame = view:snapshot()
        if frame and table.concat(frame.rows):find("Codex · Docker", 1, true) then break end
        time.sleep("25ms")
    end
    local picker = assert(view:snapshot())
    assert(table.concat(picker.rows):find("Codex · Docker", 1, true), "Docker profile missing from Agent picker")
    send(view, {type = "key", key = "", key_type = "enter", action = "press", ctrl = false, alt = false, shift = false}, "open Docker profile")
    local trust = false
    for _ = 1, 300 do
        local frame = view:snapshot()
        local text = frame and table.concat(frame.rows) or ""
        if text:find("Do you trust the contents", 1, true) then trust = true; break end
        time.sleep("25ms")
    end
    assert(trust, "Codex did not reach its project trust gate")
    send(view, {type = "key", key = "", key_type = "enter", action = "press", ctrl = false, alt = false, shift = false}, "accept project trust")
    for _ = 1, 300 do
        local frame = view:snapshot()
        local text = frame and table.concat(frame.rows) or ""
        if not text:find("Do you trust the contents", 1, true) then break end
        time.sleep("25ms")
    end
    -- Input is deliberately left unsubmitted, so this acceptance never starts
    -- a provider turn. Seeing it in the TUI proves the mounted PTY input path.
    local marker = "bee-docker-input-7b4f"
    send(view, {type = "paste", text = marker}, "send unsubmitted Codex input")
    local saw = false
    for _ = 1, 300 do
        local frame = view:snapshot()
        if frame and #frame.rows == 27 and table.concat(frame.rows):find(marker, 1, true) then saw = true; break end
        time.sleep("25ms")
    end
    if not saw then
        local final = view:snapshot()
        error("Codex TUI did not echo unsubmitted PTY input: " .. (final and table.concat(final.rows, " | ") or "view closed"))
    end
    write("ready", "ready")
    for _ = 1, 600 do
        if exists("continue") then break end
        time.sleep("50ms")
    end
    assert(exists("continue"), "external Docker inspection did not finish")
    -- Acknowledge any identity-only checkpoint before ordinary close.
    local pending = channel.select({checkpoints:case_receive(), time.after("2s"):case_receive()})
    if pending.ok and pending.channel == checkpoints then
        local checkpoint = object(pending.value:payload():data())
        assert(process.send(broker, "bee.application.persisted", {version = 1, request_id = checkpoint.request_id, error_code = "", error = ""}))
    end
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "close", op = "close", workspace_id = WORKSPACE, id = opened.id}))
    local closed = false
    while not closed do
        local data = receive_reply()
        if data.request_id == "close" and data.op == "close" then assert(data.error_code == "", tostring(data.error)); closed = true end
    end
    view:close()
    process.terminate(broker)
    process.unlisten(catalogs); process.unlisten(replies); process.unlisten(checkpoints)
end

return {run = run}
