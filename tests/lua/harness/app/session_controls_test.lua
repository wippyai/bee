-- SPDX-License-Identifier: MIT
-- Removing a session from Agents asks first, naming what goes and what stays,
-- and a removed session's windows close so the node never reopens them.
local test = require("test")
local tty = require("tty")
local system = require("system")
local time = require("time")
local channel = require("channel")
local client = require("client")
local registry = require("registry")
local process = require("process")
local funcs = require("funcs")
local bounds = require("bounds")
local owner = require("owner")

local function call(operation: string, request: {[string]: unknown}): {[string]: unknown}
    return assert(client.call(assert(system.node.id()), operation, request))
end
local function await(viewport: tty.Viewport, needle: string, absent: string?): string
    local updates = assert(viewport:updates())
    local deadline = time.after("10s")
    while true do
        local snapshot = viewport:snapshot()
        local shown = snapshot and tty.text.plain(table.concat(snapshot.rows, "\n")) or ""
        local flat = shown:gsub("%s+", " ")
        if flat:find(needle, 1, true) and (not absent or not flat:find(absent, 1, true)) then return flat end
        local selected = channel.select({updates:case_receive(), deadline:case_receive()})
        assert(selected.channel ~= deadline, "Agents screen did not show " .. needle .. "\n" .. shown)
    end
end
local function key(viewport: tty.Viewport, kind: string, value: string?)
    assert(viewport:send({type = "key", action = "press", key_type = kind, key = value or ""}))
end
-- event waits for the kind of event about the instance id; events about
-- other instances, such as an earlier case's closing window, pass by.
local function event(events: channel.Channel<process.Message>, kind: string, id: string): {[string]: unknown}
    local deadline = time.after("10s")
    while true do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        assert(selected.channel ~= deadline, "no " .. kind .. " event for " .. id)
        local data = bounds.object(selected.value:payload():data())
        if data and data.kind == kind and data.id == id then return data end
    end
end
-- swap makes the node's sessions owner binding the default for body, listing
-- and removing through the removable owner.
local function swap(body: () -> ())
    local originals: {registry.Entry} = {}
    local changes = assert(registry.snapshot()):changes()
    for _, ref in ipairs({"bee.tests.threads.sessions:fake_owner", "bee.threads.sessions.binding:owner_binding"}) do
        originals[#originals + 1] = assert(registry.get(ref))
        local entry = assert(registry.get(ref))
        local data = assert(bounds.object(entry.data))
        local node_owner = ref:find("bee.threads", 1, true) == 1
        for _, contract in ipairs(assert(bounds.array(data.contracts, 2))) do
            local selected = assert(bounds.object(contract))
            selected.default = node_owner
            local methods = assert(bounds.object(selected.methods))
            if node_owner then
                methods.list = "bee.tests.harness.app:removable_list"
                methods.remove = "bee.tests.harness.app:removable_remove"
            end
        end
        changes:update(entry)
    end
    assert(changes:apply())
    local ok, failure = pcall(body)
    local restore = assert(registry.snapshot()):changes()
    for _, entry in ipairs(originals) do restore:update(entry) end
    assert(restore:apply())
    if not ok then error(tostring(failure)) end
end
local function define_tests()
    test.describe("Agents session removal", function()
        test.it("asks before removing, keeps the session on Escape and removes it once on Enter", function()
            assert(process.registry.register(owner.WAITER))
            local removals = assert(process.listen("bee.tests.harness.app.remove", {message = true}))
            swap(function()
                local state = assert(client.state(call("watch", {})))
                local opened = call("open", {app = "bee.harness.app:app", desktop = state.desktop})
                local id = tostring(opened.id)
                local viewport = assert(tty.attach(tostring(call("attach", {id = id}).ref)))
                local ok, failure = pcall(function()
                    assert(viewport:resize(140, 40))
                    await(viewport, "Doomed agent")
                    key(viewport, "runes", "d")
                    test.contains(await(viewport, "Remove session Doomed agent?"),
                        "Remove session Doomed agent? Its thread history stays. Its agent is stopped first.")
                    key(viewport, "esc")
                    local kept = await(viewport, "Doomed agent", "Remove session Doomed agent?")
                    test.is_nil((kept:find("Removing session", 1, true)))
                    key(viewport, "runes", "d")
                    await(viewport, "Remove session Doomed agent?")
                    key(viewport, "enter")
                    local asked = channel.select({removals:case_receive(), time.after("10s"):case_receive()})
                    assert(asked.channel == removals, "Enter did not remove the session")
                    local request = assert(bounds.object(asked.value:payload():data()))
                    test.eq(request.session, owner.DOOMED)
                    test.not_nil(request.operation_key)
                    assert(process.registry.register(owner.MARKER))
                    assert(process.send(tostring(asked.value:from()), "bee.tests.harness.app.recorded", {}))
                    test.contains(await(viewport, "Kept agent", "Doomed agent"), "Kept agent")
                end)
                call("close", {id = id})
                viewport:close()
                call("leave", {})
                process.registry.unregister(owner.MARKER)
                if not ok then error(tostring(failure)) end
            end)
            process.unlisten(removals)
            process.registry.unregister(owner.WAITER)
        end)
        test.it("keeps the removal prompt on screen while the session list reloads", function()
            assert(process.registry.register(owner.LISTENER))
            local listed = assert(process.listen("bee.tests.harness.app.listed", {message = true}))
            swap(function()
                local state = assert(client.state(call("watch", {})))
                local opened = call("open", {app = "bee.harness.app:app", desktop = state.desktop})
                local id = tostring(opened.id)
                local viewport = assert(tty.attach(tostring(call("attach", {id = id}).ref)))
                local ok, failure = pcall(function()
                    assert(viewport:resize(140, 40))
                    await(viewport, "Doomed agent")
                    key(viewport, "runes", "d")
                    await(viewport, "Remove session Doomed agent?")
                    -- The second list after the prompt starts only once the
                    -- first reload's result has been shown.
                    for _ = 1, 2 do
                        local reloaded = channel.select({listed:case_receive(), time.after("20s"):case_receive()})
                        assert(reloaded.channel == listed, "the session list did not reload")
                    end
                    test.contains(await(viewport, "Doomed agent"), "Remove session Doomed agent? Its thread history stays.")
                    key(viewport, "esc")
                end)
                call("close", {id = id})
                viewport:close()
                call("leave", {})
                if not ok then error(tostring(failure)) end
            end)
            process.unlisten(listed)
            process.registry.unregister(owner.LISTENER)
        end)
        test.it("closes every Agents window showing a removed session and keeps the others", function()
            swap(function()
                local events = assert(process.listen(client.EVENTS, {message = true}))
                local state = assert(client.state(call("watch", {})))
                local doomed = tostring(call("open", {app = "bee.harness.app:app", desktop = state.desktop, args = {arguments = {"--session", owner.DOOMED}}}).id)
                local kept = tostring(call("open", {app = "bee.harness.app:app", desktop = state.desktop, args = {arguments = {"--session", owner.KEPT}}}).id)
                local ok, failure = pcall(function()
                    local raw, err = funcs.call("bee.harness.binding:forget_session_windows", {session = owner.DOOMED, thread_id = "thread-doomed", owner_id = "bee.test.owner"})
                    if err then error(tostring(err)) end
                    local reply = assert(bounds.object(raw))
                    test.is_true(reply.ok == true)
                    local closed = assert(bounds.array(assert(bounds.object(reply.value)).closed, 8))
                    test.eq(#closed, 1)
                    test.eq(closed[1], doomed)
                    event(events, "closed", doomed)
                    local running = false
                    for _, item in ipairs(assert(bounds.array(call("instances", {app = "bee.harness.app:app"}).instances, 64))) do
                        local instance = assert(bounds.object(item))
                        if instance.id == kept then running = true end
                        test.is_false(instance.id == doomed)
                    end
                    test.is_true(running)
                end)
                for _, id in ipairs({doomed, kept}) do
                    for _, item in ipairs(assert(bounds.array(call("instances", {app = "bee.harness.app:app"}).instances, 64))) do
                        if assert(bounds.object(item)).id == id then call("close", {id = id, force = true}) end
                    end
                end
                call("leave", {})
                process.unlisten(events)
                if not ok then error(tostring(failure)) end
            end)
        end)
    end)
end
return test.run_cases(define_tests)
