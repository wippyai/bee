-- SPDX-License-Identifier: MIT
local test = require("test")
local process = require("process")
local channel = require("channel")
local system = require("system")
local tty = require("tty")
local registry = require("registry")
local client = require("client")

local function call(op: string, args: {[string]: unknown}): {[string]: unknown}
    local value, err = client.call(assert(system.node.id()), op, args)
    if not value then error(op .. ": " .. tostring(err)) end
    return value
end

local function next_event(inbox: unknown, kind: string): client.Event
    local events = inbox :: channel.Channel
    while true do
        local selected = channel.select({events:case_receive()})
        assert(selected.ok, "node observation closed before " .. kind)
        local event = client.event(selected.value:payload():data())
        if kind == "moved" and event and event.kind == "closed" then error("live update closed its window") end
        if event and event.kind == kind then return event end
    end
end

local function rows_until(view: tty.Viewport, text: string): boolean
    local updates = assert(view:updates())
    while true do
        local snapshot = view:snapshot()
        if snapshot and snapshot.rows[1] and snapshot.rows[1]:find(text, 1, true) then return true end
        local selected = channel.select({updates:case_receive()})
        assert(selected.ok, "viewport update stream closed")
    end
end

local function define_tests()
    test.describe("application upgrade", function()
        for _, mode in ipairs({"durable", "overlay"}) do
        test.it("serves a new " .. mode .. " app entry in the same window with its checkpoint", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local before = assert(client.state(call("watch", {})))
            local app = "bee.tests.node:broker_probe"
            local original = assert(registry.get(app))
            local owner = "bee.tests.node.application-upgrade"
            if mode == "overlay" then
                local remove = assert(registry.snapshot()):changes()
                assert(remove:delete(app))
                assert(remove:apply())
                local install = assert(registry.overlay(owner)):changes()
                assert(install:create(original))
                assert(install:apply())
            end
            local opened = call("open", {app = app, desktop = before.desktop,
                args = {arguments = {"accept", "", "kept-state"}}})
            local id = tostring(opened.id)
            local view = assert(tty.attach(tostring(call("attach", {id = id}).ref)))
            local updates = assert(view:updates())
            while true do
                local snapshot = view:snapshot()
                if snapshot and snapshot.rows[3] and snapshot.rows[3]:find("checkpoint |", 1, true) then break end
                assert(channel.select({updates:case_receive()}).ok)
            end
            local changed = assert(registry.get(app))
            changed.meta.application.revision = "2"
            local data = changed.data :: {[string]: unknown}
            data.source = tostring(data.source):gsub('"resume "', '"revision 2 resume "', 1)
            local version = assert(registry.current_version()):string()
            local changes = (mode == "overlay" and assert(registry.overlay(owner)) or assert(registry.snapshot())):changes()
            assert(changes:update(changed))
            assert(changes:apply())
            local passed, problem = pcall(function()
                if mode == "overlay" then test.eq(assert(registry.current_version()):string(), version) end
                local updated = next_event(events, "moved")
                test.eq(updated.id, id)
                test.eq(updated.instance and updated.instance.desktop, before.desktop)
                test.neq(updated.instance and updated.instance.pid, opened.pid)
                test.is_true(rows_until(view, "revision 2 resume kept-state"))
                local running = assert(client.state(call("list", {}))).running
                local count = 0
                for _, instance in ipairs(running) do if instance.id == id then count = count + 1 end end
                test.eq(count, 1)
                test.is_nil(assert(client.state(call("list", {}))).problem)
                local edited = assert(registry.get(app))
                local source = edited.data :: {[string]: unknown}
                source.source = tostring(source.source):gsub("revision 2 resume", "new code resume", 1)
                local update = (mode == "overlay" and assert(registry.overlay(owner)) or assert(registry.snapshot())):changes()
                assert(update:update(edited))
                assert(update:apply())
                test.eq(next_event(events, "moved").id, id)
                test.is_true(rows_until(view, "new code resume kept-state"))
            end)
            call("close", {id = id, force = true})
            while next_event(events, "closed").id ~= id do end
            view:close()
            local restore = assert(registry.snapshot()):changes()
            if mode == "overlay" then
                local remove = assert(registry.overlay(owner)):changes()
                assert(remove:delete(app))
                assert(remove:apply())
                restore = assert(registry.snapshot()):changes()
                assert(restore:create(original))
            else assert(restore:update(original)) end
            assert(restore:apply())
            process.unlisten(events)
            if not passed then error(tostring(problem)) end
        end)
        end
        test.it("reports an application that declines its update", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local before = assert(client.state(call("watch", {})))
            local app = "bee.tests.node:broker_probe"
            local original = assert(registry.get(app))
            local opened = call("open", {app = app, desktop = before.desktop, args = {arguments = {"cancel"}}})
            local id = tostring(opened.id)
            local view = assert(tty.attach(tostring(call("attach", {id = id}).ref)))
            test.is_true(rows_until(view, "resume none"))
            while next_event(events, "title").id ~= id do end
            local changed = assert(registry.get(app))
            changed.meta.application.revision = "declined"
            local changes = assert(registry.snapshot()):changes()
            assert(changes:update(changed))
            assert(changes:apply())
            while true do
                local event = next_event(events, "catalog")
                if event.problem and event.problem:find("declined its live update", 1, true) then break end
            end
            local state = assert(client.state(call("list", {})))
            test.is_true(state.problem ~= nil and state.problem:find("declined its live update", 1, true) ~= nil)
            for _, instance in ipairs(state.running) do if instance.id == id then test.eq(instance.pid, opened.pid) end end
            call("close", {id = id, force = true})
            while next_event(events, "closed").id ~= id do end
            view:close()
            local restore = assert(registry.snapshot()):changes()
            assert(restore:update(original))
            assert(restore:apply())
            process.unlisten(events)
        end)
        test.it("reports an application whose new execution fails", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local before = assert(client.state(call("watch", {})))
            local app = "bee.tests.node:probe_app"
            local original = assert(registry.get(app))
            local opened = call("open", {app = app, desktop = before.desktop})
            local id = tostring(opened.id)
            local view = assert(tty.attach(tostring(call("attach", {id = id}).ref)))
            test.is_true(rows_until(view, "theme "))
            local changed = assert(registry.get(app))
            changed.meta.application.revision = "broken"
            local data = changed.data :: {[string]: unknown}
            data.source = [[local process = require("process")
                return {main = function()
                    local fail = assert(process.listen("bee.test.app.fail", {message = true}))
                    assert((fail:receive()))
                    error("broken application revision")
                end}]]
            local changes = assert(registry.snapshot()):changes()
            assert(changes:update(changed))
            assert(changes:apply())
            local updated = next_event(events, "moved")
            assert(process.send(assert(updated.instance).pid, "bee.test.app.fail", {}))
            while true do
                local event = next_event(events, "catalog")
                if event.problem and event.problem:find("failed after its live update", 1, true) then break end
            end
            while next_event(events, "closed").id ~= id do end
            test.is_true(assert(client.state(call("list", {}))).problem ~= nil)
            view:close()
            local restore = assert(registry.snapshot()):changes()
            assert(restore:update(original))
            assert(restore:apply())
            while next_event(events, "catalog").problem ~= nil do end
            test.is_nil(assert(client.state(call("list", {}))).problem)
            process.unlisten(events)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
