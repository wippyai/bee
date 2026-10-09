-- MIT. The node owner survives a change to its own code: the new code takes
-- over the same process with its running apps, their viewports and its
-- watchers, so attached displays keep working.
local test = require("test")
local process = require("process")
local channel = require("channel")
local system = require("system")
local time = require("time")
local tty = require("tty")
local registry = require("registry")
local eventbus = require("events")
local appearance = require("appearance")
local client = require("client")

local PROBE = "bee.tests.node:probe_app"
local OWNER = "bee.node.service:owner"

local function call(op: string, args: {[string]: unknown}): {[string]: unknown}
    local value, err = client.call(assert(system.node.id()), op, args)
    if not value then error(op .. ": " .. tostring(err)) end
    return value
end

local function next_event(inbox: unknown, kind: string): client.Event
    local events = inbox :: channel.Channel
    local deadline = time.after("5s")
    while true do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then error("no " .. kind .. " event") end
        local event = client.event(selected.value:payload():data())
        if event and event.kind == kind then return event end
    end
end

local function rows_until(view: tty.Viewport, text: string): boolean
    local updates = assert(view:updates())
    local deadline = time.after("5s")
    while true do
        local snapshot = view:snapshot()
        if snapshot and snapshot.rows[1] and snapshot.rows[1]:find(text, 1, true) then return true end
        local selected = channel.select({updates:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then return false end
    end
end

-- edit_owner applies a change to the owner's source, which makes the running
-- owner outdated.
local function edit_owner()
    local ready = assert(process.listen("bee.test.owner.upgraded", {message = true}))
    local snapshot = assert(registry.snapshot())
    local entry = assert(snapshot:get(OWNER))
    local data = entry.data :: {[string]: unknown}
    local changed: {[string]: unknown} = {}
    for key, value in pairs(data) do changed[key] = value end
    changed.source = (tostring(data.source):gsub('    logger:info%("Node ready",',
        '    assert(process.send(' .. string.format("%q", tostring(process.pid())) ..
        ', "bee.test.owner.upgraded", {}))\n    logger:info("Node ready",', 1))
    local changes = snapshot:changes()
    assert(changes:update({id = OWNER, kind = entry.kind, meta = entry.meta, data = changed}))
    assert(changes:apply())
    local deadline = time.after("5s")
    local selected = channel.select({ready:case_receive(), deadline:case_receive()})
    process.unlisten(ready)
    assert(selected.channel == ready, "owner did not finish its upgrade")
end

local function define_tests()
    test.describe("owner upgrade", function()
        test.it("finishes an applied revision restart across an owner upgrade", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local stopping = assert(process.listen("bee.test.probe.stopping", {message = true}))
            local before = assert(client.state(call("watch", {})))
            local retained: {[string]: boolean} = {}
            for _, instance in ipairs(before.running) do retained[instance.id] = true end
            local opened = call("open", {app = PROBE, desktop = before.desktop,
                args = {exit_controller = tostring(process.pid())}})
            local id, pid = tostring(opened.id), tostring(opened.pid)
            while next_event(events, "opened").id ~= id do end
            local original = assert(registry.get(PROBE))
            local owner = assert(registry.get(OWNER))
            local changed = assert(registry.get(PROBE))
            changed.meta.application.revision = "upgrade-restart"
            local changes = assert(registry.snapshot()):changes()
            assert(changes:update(changed))
            assert(changes:apply())
            local passed, problem = pcall(function()
                assert(eventbus.send("bee.attention", "application.applied", before.home, {component = "bee.tests.node"}))
                local deadline = time.after("5s")
                local selected = channel.select({stopping:case_receive(), deadline:case_receive()})
                assert(selected.channel == stopping, "applied revision did not stop the old app")
                test.eq(tostring(selected.value:from()), pid)
                edit_owner()
                assert(process.send(pid, "bee.test.probe.exit", {}))
                while next_event(events, "closed").id ~= id do end
                local reopened = next_event(events, "opened")
                test.eq(reopened.id, id)
                test.neq(reopened.instance and reopened.instance.pid, pid)
            end)
            local restore = assert(registry.snapshot()):changes()
            assert(restore:update(original))
            assert(restore:update(owner))
            assert(restore:apply())
            local after = assert(client.state(call("list", {})))
            local waiting: {[string]: boolean} = {}
            for _, instance in ipairs(after.running) do
                if not retained[instance.id] then
                    waiting[instance.id] = true
                    assert(process.terminate(instance.pid))
                end
            end
            while next(waiting) do waiting[tostring(next_event(events, "closed").id)] = nil end
            process.unlisten(stopping)
            process.unlisten(events)
            if not passed then error(tostring(problem)) end
        end)

        test.it("keeps its process, apps, viewports and watchers across a code change", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local before = assert(client.state(call("watch", {})))
            local opened = call("open", {app = PROBE, desktop = before.desktop})
            local id = tostring(opened.id)
            local view = assert(tty.attach(tostring(call("attach", {id = id}).ref)))
            local owner = assert(registry.get(OWNER))

            edit_owner()

            local after = assert(client.state(call("list", {})))
            test.eq(after.owner, before.owner)
            local running = false
            for _, instance in ipairs(after.running) do
                if instance.id == id then running = true end
            end
            test.is_true(running)

            local themes = call("themes", {}).themes :: {{[string]: unknown}}
            local target = tostring(themes[1].id)
            if target == after.appearance.theme.id then target = tostring(themes[2].id) end
            call("appearance", {theme = target})
            test.eq((next_event(events, "appearance").appearance or appearance.defaults()).theme.id, target)
            test.is_true(rows_until(view, "theme " .. target))

            call("close", {id = id})
            test.eq(next_event(events, "closed").id, id)
            view:close()
            process.unlisten(events)
            local restore = assert(registry.snapshot()):changes()
            assert(restore:update(owner))
            assert(restore:apply())
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
