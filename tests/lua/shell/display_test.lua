-- MIT. Displays run as ordinary terminal producers. Each new display starts
-- on its own desktop and no two displays show the same desktop; a display
-- opens apps from the Start menu into windows, switches to another desktop
-- from the workspace menu and then shows that desktop's apps, keeps its windows across an upgrade of its own code, closes
-- the focused app on Ctrl+W and exits when cancelled.
local test = require("test")
local process = require("process")
local channel = require("channel")
local system = require("system")
local time = require("time")
local tty = require("tty")
local registry = require("registry")
local client = require("client")
local events = require("events")
local env = require("env")
local uuid = require("uuid")
local funcs = require("funcs")
local bounds = require("bounds")
local menu = require("menu")
local processes = require("processes")
local protocol = require("protocol")

local DISPLAY = "bee.shell:client"

local function screen(view: tty.Viewport): string
    local snapshot = view:snapshot()
    if not snapshot then return "" end
    return (table.concat(snapshot.rows, "\n"):gsub("\27%[[0-9;]*m", ""))
end

-- shows waits until the viewport shows text, or until it no longer does.
local function shows(view: tty.Viewport, text: string, present: boolean): boolean
    local updates = assert(view:updates())
    local deadline = time.after("8s")
    while true do
        if (screen(view):find(text, 1, true) ~= nil) == present then return true end
        local selected = channel.select({updates:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then return false end
        assert(selected.ok, "display update stream closed")
    end
end

-- expect fails the test with step and the screen unless the viewport comes to
-- show text (present) or stops showing it.
local function expect(view: tty.Viewport, step: string, text: string, present: boolean)
    if not shows(view, text, present) then
        local supervisor = assert(system.supervisor.state("bee.hive.service:supervisor_service"))
        error(step .. ": Hive " .. supervisor.status .. " " .. tostring(supervisor.details) .. "; screen was\n" .. screen(view))
    end
end

local function key(view: tty.Viewport, name: string, modifiers: {[string]: boolean}?)
    local event: {[string]: unknown} = {type = "key", key = name, key_type = #name == 1 and "runes" or name, action = "press"}
    for flag, value in pairs(modifiers or {}) do event[flag] = value end
    assert(view:send(event))
end

type Fixture = {
    viewport: (Fixture) -> tty.Viewport,
    start: (Fixture) -> (tty.Viewport, string),
}
local function with_fixture(body: (Fixture) -> (), after_snapshot: ((client.State) -> ())?)
    local node = assert(system.node.id())
    local existing: {[string]: boolean} = {}
    for _, instance in ipairs(assert(client.state(assert(client.call(node, "list", {})))).running) do
        existing[instance.id] = true
    end
    local retire = processes.owned("bee:workers", {[DISPLAY] = true, ["bee.shell:main"] = true}, {})
    local views: {tty.Viewport} = {}
    local function viewport(_: Fixture): tty.Viewport
        local view = assert(tty.viewport({width = 100, height = 30}))
        views[#views + 1] = view
        return view
    end
    local function start(self: Fixture): (tty.Viewport, string)
        local view = self:viewport()
        local pid = assert(process.with_options({terminal = assert(view:grant())})
            :spawn_monitored(DISPLAY, "bee:workers", node))
        return view, tostring(pid)
    end
    local ok, problem = pcall(body, {viewport = viewport, start = start})
    retire()
    for _, view in ipairs(views) do view:close() end
    local inbox = assert(process.listen(client.EVENTS, {message = true}))
    local remaining = assert(client.state(assert(client.call(node, "watch", {}))))
    if after_snapshot then after_snapshot(remaining) end
    local waiting: {[string]: boolean} = {}
    for _, instance in ipairs(remaining.running) do
        if not existing[instance.id] then
            waiting[instance.id] = true
            processes.cancel(instance.pid)
        end
    end
    while next(waiting) do
        local message = assert((inbox:receive()))
        local event = client.event(message:payload():data())
        if tostring(message:from()) == remaining.owner and event and event.kind == "closed" then
            waiting[tostring(event.id)] = nil
        end
    end
    assert(client.call(node, "leave", {}))
    process.unlisten(inbox)
    assert(ok, tostring(problem))
end
local function display_case(name: string, body: (Fixture) -> ())
    test.it(name, function() with_fixture(body) end)
end

local function retirement_fixture(controller: string, desktop: string)
    local release = assert(process.listen("bee.test.display.retire", {message = true}))
    local id = ""
    with_fixture(function(_: Fixture)
        local opened = assert(client.call(assert(system.node.id()), "open", {
            app = "bee.tests.node:probe_app", desktop = desktop, args = {exit_controller = controller}}))
        id = tostring(opened.id)
        assert(client.call(assert(system.node.id()), "close", {id = id}))
    end, function(snapshot: client.State)
        local found = false
        for _, instance in ipairs(snapshot.running) do if instance.id == id then found = true end end
        assert(found, "teardown did not capture the closing probe")
        assert(process.send(controller, "bee.test.display.snapshot", {id = id}))
        assert(tostring(assert((release:receive())):from()) == controller)
    end)
    process.unlisten(release)
end

local function bar(view: tty.Viewport): string
    local snapshot = view:snapshot()
    if not snapshot or not snapshot.rows[1] then return "" end
    return (snapshot.rows[1]:gsub("\27%[[0-9;]*m", ""))
end

local function running(): integer
    local state = assert(client.state(assert(client.call(assert(system.node.id()), "list", {}))))
    return #state.running
end

local function edit(id: string)
    local snapshot = assert(registry.snapshot())
    local entry = assert(snapshot:get(id))
    local data = entry.data :: {[string]: unknown}
    local changed: {[string]: unknown} = {}
    for k, v in pairs(data) do changed[k] = v end
    changed.source = tostring(data.source) .. "\n-- upgraded " .. tostring(time.now():unix_nano()) .. "\n"
    local changes = snapshot:changes()
    assert(changes:update({id = id, kind = entry.kind, meta = entry.meta, data = changed}))
    assert(changes:apply())
end

local function wait_exits(lifecycle: unknown, pids: {string})
    local events = lifecycle :: channel.Channel
    local waiting: {[string]: boolean} = {}
    for _, pid in ipairs(pids) do
        waiting[pid] = true
    end
    while next(waiting) do
        local selected = channel.select({events:case_receive()})
        assert(selected.ok, "display supervision closed")
        if selected.value.kind == process.event.EXIT then waiting[tostring(selected.value.from)] = nil end
    end
end

local function exits(lifecycle: unknown, pids: {string})
    for _, pid in ipairs(pids) do assert(process.cancel(pid)) end
    wait_exits(lifecycle, pids)
end

local function open_probe(view: tty.Viewport)
    local descriptors: {menu.Descriptor} = {}
    for _, app in ipairs(assert(client.state(assert(client.call(assert(system.node.id()), "list", {})))).apps) do
        descriptors[#descriptors + 1] = {definition_id = app.id, title = app.title, menus = app.menus}
    end
    local group, selected = 0, 0
    for index, item in ipairs(menu.items(descriptors)) do
        if item.action == "group:bee.shell:apps_menu" then
            group = index
            for position, app in ipairs(item.children or {}) do
                if app.action == "open:bee.tests.node:probe_app" then selected = position end
            end
        end
    end
    assert(group > 0 and selected > 0, "Probe is not in the installed Apps menu")
    expect(view, "an empty desktop opens the Start panel", "Bees", true)
    key(view, "home")
    for _ = 2, group do key(view, "down") end
    key(view, "enter")
    expect(view, "Apps lists the probe", "Probe", true)
    expect(view, "Apps lists the Inbox", "Needs you", true)
    expect(view, "Apps lists Agents", "Agents", true)
    key(view, "home")
    for _ = 2, selected do key(view, "down") end
    key(view, "enter")
    expect(view, "the probe opens in a window", "label ", true)
end

local function define_tests()
    test.describe("displays", function()
        test.it("keeps the supervisor, display and queued route across a core upgrade", function()
            local source = "bee.hive.service:supervisor"
            local baseline = assert(assert(registry.snapshot()):get(source))
            local ready = assert(process.listen("bee.test.hive.upgrade_ready", {message = true}))
            local parked = assert(process.listen("bee.test.hive.upgrade_parked", {message = true}))
            assert(process.registry.register("bee.test.hive.upgrade_ready"))
            assert(process.registry.register("bee.test.hive.upgrade_parked"))
            local before = assert(process.registry.lookup("bee.hive.supervisor", process.registry.LOCAL))
            local started = assert(system.supervisor.state("bee.hive.service:supervisor_service")).started_at
            local ok, problem = pcall(function()
                with_fixture(function(fixture: Fixture)
                    local view = fixture:start()
                    open_probe(view)
                    local reply = channel.new(1)
                    coroutine.spawn(function()
                        local result, err = protocol.call(assert(system.node.id()), "parked.ping", {label = "kept across upgrade"}, "5s")
                        reply:send(result and result.ok and result.value and result.value.label or tostring(err))
                    end)
                    test.eq(tostring(assert((parked:receive())):from()), tostring(before))
                    edit(source)
                    test.eq(tostring(assert((ready:receive())):from()), tostring(before))
                    test.eq(assert(system.supervisor.state("bee.hive.service:supervisor_service")).started_at, started)
                    local provider = assert(process.spawn_monitored("bee.tests.hive:parked_service", "bee:workers"))
                    test.eq(reply:receive(), "kept across upgrade")
                    processes.join(tostring(provider))
                    local state = assert(client.state(assert(client.call(assert(system.node.id()), "list", {}))))
                    test.eq(state.supervisor, tostring(before))
                    key(view, "f1")
                    expect(view, "the display accepts input after the supervisor upgrade", "Bees", true)
                end)
            end)
            local changes = assert(assert(registry.snapshot()):changes())
            assert(changes:update(baseline))
            assert(changes:apply())
            assert((ready:receive()))
            process.unlisten(ready)
            process.unlisten(parked)
            assert(process.registry.unregister("bee.test.hive.upgrade_ready"))
            assert(process.registry.unregister("bee.test.hive.upgrade_parked"))
            assert(client.call(assert(system.node.id()), "list", {}))
            assert(ok, tostring(problem))
        end)
        test.it("retires an app that closes after the fixture snapshot", function()
            local lifecycle = assert(process.events())
            local inbox = assert(process.listen(client.EVENTS, {message = true}))
            local stopping = assert(process.listen("bee.test.probe.stopping", {message = true}))
            local snapshots = assert(process.listen("bee.test.display.snapshot", {message = true}))
            local node = assert(system.node.id())
            local watched = assert(client.state(assert(client.call(node, "watch", {}))))
            local fixture = tostring(assert(process.spawn_monitored("bee.tests.shell:retirement_fixture", "bee:workers",
                tostring(process.pid()), assert(watched.desktop))))
            local captured = assert((snapshots:receive()))
            test.eq(tostring(captured:from()), fixture)
            local id = assert(bounds.id(assert(bounds.object(captured:payload():data())).id))
            local probe = tostring(assert((stopping:receive())):from())
            assert(process.send(probe, "bee.test.probe.exit", {}))
            while true do
                local message = assert((inbox:receive()))
                local event = client.event(message:payload():data())
                if tostring(message:from()) == watched.owner and event and event.kind == "closed" and event.id == id then break end
            end
            assert(process.send(fixture, "bee.test.display.retire", {}))
            local failure: unknown = nil
            while true do
                local event = assert((lifecycle:receive()))
                if event.kind == process.event.EXIT and tostring(event.from) == fixture then
                    failure = event.result and event.result.error
                    break
                end
            end
            assert(client.call(node, "leave", {}))
            process.unlisten(inbox)
            process.unlisten(stopping)
            process.unlisten(snapshots)
            test.is_nil(failure, tostring(failure))
        end)
        display_case("retires a failed display and its node-owned apps while preserving earlier apps", function(fixture: Fixture)
            local view = fixture:start()
            open_probe(view)
            local node = assert(system.node.id())
            local kept = assert(client.state(assert(client.call(node, "list", {})))).running[1].pid
            local display_pid, app_pid = "", ""
            local ok, problem = pcall(with_fixture, function(failed: Fixture)
                local other, pid = failed:start()
                display_pid = pid
                expect(other, "the failure fixture opens its desktop", "Bees", true)
                key(other, "esc")
                local title = assert(bar(other):match("Desktop %d+"))
                local listed = assert(client.state(assert(client.call(node, "list", {}))))
                local desktop = ""
                for _, item in ipairs(listed.desktops) do if item.title == title then desktop = item.id end end
                local opened = assert(client.call(node, "open", {app = "bee.approvals.inbox.app:app", desktop = desktop}))
                for _, item in ipairs(assert(client.state(assert(client.call(node, "list", {})))).running) do
                    if item.id == opened.id then app_pid = item.pid end
                end
                expect(other, "the failure fixture shows its node-owned app", "NEEDS YOU", true)
                error("display fixture assertion")
            end)
            test.is_false(ok)
            assert(tostring(problem):find("display fixture assertion", 1, true), tostring(problem))
            test.neq(display_pid, "")
            test.neq(app_pid, "")
            local remaining: {[string]: boolean} = {}
            for _, actor in ipairs(assert(system.hosts.processes("bee:workers"))) do remaining[actor.pid] = true end
            test.is_nil(remaining[display_pid], "the failed display outlived its fixture")
            test.is_nil(remaining[app_pid], "the failed display's app outlived its fixture")
            test.is_true(remaining[kept] == true, "cleanup stopped an earlier fixture's app")
            expect(view, "the earlier app keeps its window", "label ", true)
        end)
        display_case("open apps on their own desktops, switch desktops, survive an upgrade and close apps", function(fixture: Fixture)
            local lifecycle = assert(process.events())
            local before = running()
            local first, first_pid = fixture:start()
            expect(first, "first display shows the bar", " BEE ", true)
            open_probe(first)
            test.eq(running(), before + 1)
            local first_label = bar(first):match("(Desktop %d+)")

            local second, second_pid = fixture:start()
            expect(second, "second display shows the bar", " BEE ", true)
            expect(second, "second display starts on an empty desktop", "Bees", true)
            test.neq(bar(second):match("(Desktop %d+)"), first_label)
            key(second, "esc")
            key(second, "f3")
            expect(second, "the workspace menu opens", " Bees ", true)
            expect(second, "the menu marks the first display's desktop", "other display", true)
            key(second, "up")
            key(second, "enter")
            expect(second, "the second display keeps off the first display's desktop", "is on another display", true)
            expect(second, "the second display shows none of the first desktop's apps", "label ", false)
            key(second, "esc")

            local probe, origin = "", ""
            for _, instance in ipairs(assert(client.state(assert(client.call(assert(system.node.id()), "list", {})))).running) do
                probe, origin = instance.id, instance.desktop
            end
            local own = assert(client.call(assert(system.node.id()), "desktop_create", {}))
            assert(client.call(assert(system.node.id()), "move", {id = probe, desktop = own.desktop}))
            expect(first, "the first display drops the moved probe", "label ", false)
            expect(second, "the second display drops the moved probe", "label ", false)
            key(second, "f3")
            expect(second, "the workspace menu opens again", " Bees ", true)
            key(second, "/")
            for character in tostring(own.title):gmatch(".") do key(second, character == " " and "space" or character) end
            key(second, "enter")
            key(second, "enter")
            expect(second, "the second display shows the probe on its new desktop", "label ", true)
            assert(client.call(assert(system.node.id()), "move", {id = probe, desktop = origin}))
            expect(first, "the probe comes back to the first display", "label ", true)

            edit("bee.node.service:owner")
            local fresh = assert(client.call(assert(system.node.id()), "open",
                {app = "bee.tests.node:probe_app", desktop = origin, args = {label = "after-upgrade"}}))
            expect(first, "the first display shows an app opened after the owner upgrade", "label after-upgrade", true)
            assert(client.call(assert(system.node.id()), "close", {id = fresh.id}))

            edit(DISPLAY)
            key(first, "f1")
            expect(first, "the Start panel opens after the upgrade", "Bees", true)
            key(first, "esc")
            expect(first, "the probe window stays after the upgrade", "label ", true)

            key(first, "w", {ctrl = true})
            expect(first, "Ctrl+W closes the probe", "label ", false)
            expect(second, "the other display drops the closed probe", "label ", false)
            test.eq(running(), before)

            exits(lifecycle, {first_pid, second_pid})
        end)

        display_case("opens the app a command names full-pane when bee runs with that command", function(fixture: Fixture)
            local lifecycle = assert(process.events())
            local view = fixture:viewport()
            local pid = tostring(assert(process.with_options({terminal = assert(view:grant())})
                :spawn_monitored("bee.shell:main", "bee:workers", "probe", "tail")))
            expect(view, "the command opens the probe", "label ", true)
            local snapshot = assert(view:snapshot())
            local labelled = false
            for _, row in ipairs(snapshot.rows) do
                if row:find("args from-command tail", 1, true) then labelled = true end
            end
            test.is_true(labelled, "the probe shows the command's arguments")
            test.is_true((snapshot.rows[2]:gsub("\27%[[0-9;]*m", "")):match("^theme ") ~= nil, "the probe fills the pane")
            local shown_on = ""
            for _, instance in ipairs(assert(client.state(assert(client.call(assert(system.node.id()), "list", {})))).running) do
                if instance.app == "bee.tests.node:probe_app" then shown_on = instance.desktop end
            end
            -- An app another display opens on this desktop joins the bar; the
            -- full-pane probe keeps the pane and the keyboard.
            assert(client.call(assert(system.node.id()), "open", {app = "bee.tests.node:probe_single", desktop = shown_on}))
            expect(view, "the other app joins the bar", "Single probe", true)
            local after = assert(view:snapshot())
            test.is_true((after.rows[2]:gsub("\27%[[0-9;]*m", "")):match("^theme ") ~= nil, "the full-pane probe keeps the pane")
            key(view, "q", {ctrl = true})
            wait_exits(lifecycle, {pid})
        end)

        display_case("opens a command's app full-pane from a client display of the folder's node", function(fixture: Fixture)
            local lifecycle = assert(process.events())
            local view = fixture:viewport()
            local pid = tostring(assert(process.with_options({terminal = assert(view:grant())})
                :spawn_monitored(DISPLAY, "bee:workers", assert(system.node.id()), "probe", "tail")))
            expect(view, "the command opens the probe", "args from-command tail", true)
            local snapshot = assert(view:snapshot())
            test.is_true((snapshot.rows[2]:gsub("\27%[[0-9;]*m", "")):match("^theme ") ~= nil, "the probe fills the pane")
            exits(lifecycle, {pid})
        end)

        display_case("exits on a command no installed app answers", function(fixture: Fixture)
            local lifecycle = assert(process.events())
            local view = fixture:viewport()
            local pid = tostring(assert(process.with_options({terminal = assert(view:grant())})
                :spawn_monitored("bee.shell:main", "bee:workers", "no-such-agent")))
            local events = lifecycle :: channel.Channel
            local deadline = time.after("10s")
            while true do
                local selected = channel.select({events:case_receive(), deadline:case_receive()})
                if selected.channel == deadline then error("bee did not exit on an unknown command") end
                if selected.value.kind == process.event.EXIT and tostring(selected.value.from) == pid then break end
            end
        end)

        display_case("refuses a handover whose nested records are malformed", function(fixture: Fixture)
            local lifecycle = assert(process.events())
            local view = fixture:viewport()
            local handover = {target = assert(system.node.id()), origin = assert(system.node.id()), desktop = "desk",
                scenes = {desk = {width = 100, height = 30, revision = 1, focus = "", windows = {{id = "w1"}}}},
                orders = {}, windows = {}, welcomed = true}
            local pid = tostring(assert(process.with_options({terminal = assert(view:grant())})
                :spawn_monitored("bee.shell:main", "bee:workers", handover)))
            local events = lifecycle :: channel.Channel
            local deadline = time.after("10s")
            while true do
                local selected = channel.select({events:case_receive(), deadline:case_receive()})
                if selected.channel == deadline then error("bee kept a malformed handover") end
                if selected.value.kind == process.event.EXIT and tostring(selected.value.from) == pid then
                    test.eq(selected.value.result and selected.value.result.value, 2)
                    break
                end
            end
        end)

        display_case("shows in the status line that the app list is out of date until a refresh succeeds", function(fixture: Fixture)
            local lifecycle = assert(process.events())
            local view, pid = fixture:start()
            expect(view, "the display shows the bar", " BEE ", true)
            local failure = "bee.test.node.registry_failure"
            local installed = "bee.tests.node:stale_app"
            assert(process.registry.register(failure))
            local changes = assert(registry.snapshot()):changes()
            assert(changes:create({id = installed, kind = "process.lua",
                meta = {type = "bee.app", application = {api_version = 1, title = "Stale", lifetime = "view",
                    revision = "1", instance_policy = "singleton"}},
                data = {source = "return {main = function() end}", method = "main"}}))
            assert(changes:apply())
            local shown = shows(view, "App list is out of date", true)
            process.registry.unregister(failure)
            local removal = assert(registry.snapshot()):changes()
            assert(removal:delete(installed))
            assert(removal:apply())
            expect(view, "a successful refresh clears the status", "App list is out of date", false)
            test.is_true(shown)
            exits(lifecycle, {pid})
        end)

        display_case("alerts on arrival, preserves a busy keyboard and opens the request by key or click", function(fixture: Fixture)
            local lifecycle = assert(process.events())
            local view, pid = fixture:start()
            expect(view, "the display shows its desktop", " BEE ", true)
            local desktop_title = assert(bar(view):match("Desktop %d+"))
            local node = assert(system.node.id())
            local added = assert(client.call(node, "workspace_add", {
                path = assert(env.get("bee.env:machine_home")) .. "/display-attention-" .. uuid.v7(), label = "attention"}))
            local desktops = assert(client.state(assert(client.call(node, "list", {})))).desktops
            local desktop, original_workspace = "", ""
            for _, item in ipairs(desktops) do
                if item.title == desktop_title then desktop, original_workspace = item.id, item.workspace end
            end
            assert(desktop ~= "")
            assert(client.call(node, "desktop_workspace", {id = desktop, workspace = added.workspace}))
            expect(view, "the display works in its isolated workspace", "attention ▾", true)
            open_probe(view)
            local listed = assert(client.state(assert(client.call(assert(system.node.id()), "list", {}))))
            local workspace = tostring(added.workspace)
            assert(events.send("bee.attention", "approval.requested", workspace,
                {approval_id = "busy-request", count = 2, title = "Allow a workspace edit?"}))
            expect(view, "arrival shows the counted badge", "! 2 Needs you", true)
            expect(view, "arrival names the request", "Allow a workspace edit?", true)
            key(view, "w", {ctrl = true})
            expect(view, "arrival leaves the probe holding the keyboard", "label ", false)
            test.eq(running(), #listed.running)
            key(view, "f4")
            expect(view, "F4 dismisses the card", "Allow a workspace edit?", false)
            expect(view, "F4 opens Needs you", "No decisions needed", true)
            key(view, "w", {ctrl = true})
            expect(view, "F4 focuses and closes Needs you", "No decisions needed", false)
            expect(view, "closing Needs you retains the pending badge", "! 2 Needs you", true)
            key(view, "f4")
            expect(view, "the pending badge reopens Needs you", "No decisions needed", true)
            key(view, "w", {ctrl = true})
            expect(view, "the reopened request closes", "No decisions needed", false)

            assert(events.send("bee.attention", "approval.requested", workspace,
                {approval_id = "idle-request", count = 1, title = "Review the idle request"}))
            expect(view, "idle arrival names the request", "Review the idle request", true)
            expect(view, "idle arrival attaches Needs you", "No decisions needed", true)
            key(view, "w", {ctrl = true})
            expect(view, "idle arrival gives Needs you the keyboard", "No decisions needed", false)
            expect(view, "idle request keeps its badge when closed", "! 1 Needs you", true)

            assert(events.send("bee.attention", "approval.requested", workspace,
                {approval_id = "click-request", count = 1, title = "Review the clicked request"}))
            expect(view, "another arrival shows the card", "Review the clicked request", true)
            expect(view, "click arrival attaches Needs you", "No decisions needed", true)
            local position = assert((bar(view):find("! 1 Needs you", 1, true)))
            assert(view:send({type = "mouse", action = "press", button = "left", x = position, y = 1}))
            expect(view, "clicking the badge dismisses the card", "Review the clicked request", false)
            key(view, "w", {ctrl = true})
            expect(view, "clicking focuses Needs you", "No decisions needed", false)
            expect(view, "clicking keeps the pending badge", "! 1 Needs you", true)
            assert(events.send("bee.attention", "approval.changed", workspace, {count = 0}))
            expect(view, "resolved requests clear the badge", "! 1 Needs you", false)
            assert(client.call(node, "desktop_workspace", {id = desktop, workspace = original_workspace}))
            expect(view, "the display restores its desktop's workspace", "attention ▾", false)
            exits(lifecycle, {pid})
        end)

        display_case("routes decisions only to the deliberately opened card while preserving a typing window", function(fixture: Fixture)
            local lifecycle = assert(process.events())
            local viewport, pid = fixture:start()
            expect(viewport, "the desktop opens", " BEE ", true)
            open_probe(viewport)
            local node = assert(system.node.id())
            local listed = assert(client.state(assert(client.call(node, "list", {}))))
            local title = assert(bar(viewport):match("Desktop %d+"))
            local workspace = ""
            for _, item in ipairs(listed.desktops) do if item.title == title then workspace = item.workspace end end
            local raw, err = funcs.call("bee.approvals.binding:request", {workspace_id = workspace, idempotency_key = uuid.v7(),
                policy = "agent-access", request_kind = "permission", proposal = {kind = "operation", ref = "desktop-review", revision = "1", payload = {}},
                prompt = {text = "Review this desktop permission?"}})
            assert(not err, tostring(err))
            local reply = assert(bounds.object(raw))
            assert(reply.ok == true, tostring(reply.error))
            local id = assert(bounds.id(assert(bounds.object(reply.value)).approval_id))
            local function pending(): boolean
                local raw = funcs.call("bee.approvals.binding:read", {approval_id = id})
                return assert(bounds.object(assert(bounds.object(raw)).value)).state == "pending"
            end
            expect(viewport, "arrival shows a badge", "! 1 Needs you", true)
            key(viewport, "a")
            key(viewport, "w", {ctrl = true})
            expect(viewport, "the typing window keeps both keys", "label ", false)
            test.is_true(pending(), "another window approved a request")
            key(viewport, "f4")
            expect(viewport, "the request list is visible", "Choose a request", true)
            key(viewport, "f11")
            expect(viewport, "the request is visible", "Review this desktop permission?", true)
            key(viewport, "a")
            key(viewport, "enter")
            expect(viewport, "the card is visible", "Reviewing request", true)
            test.is_true(pending(), "the list approved before its card was shown")
            key(viewport, "d")
            expect(viewport, "the visible card records the decision", "Recorded:", true)
            test.is_false(pending())
            exits(lifecycle, {pid})
        end)

        display_case("shows an app's question over the desktop and sends the person's answer back to the app", function(fixture: Fixture)
            local lifecycle = assert(process.events())
            local view, pid = fixture:start()
            expect(view, "the display shows the bar", " BEE ", true)
            key(view, "esc")
            local shown = ""
            local listed = assert(client.state(assert(client.call(assert(system.node.id()), "list", {}))))
            for _, item in ipairs(listed.desktops) do
                if item.shown then shown = item.id end
            end
            local opened = assert(client.call(assert(system.node.id()), "open",
                {app = "bee.tests.node:broker_probe", desktop = shown, args = {arguments = {"accept", "Name?"}}}))
            expect(view, "the app's question shows", "Name?", true)
            key(view, "enter")
            expect(view, "the answer reaches the app", "answer accept draft", true)
            expect(view, "the question is gone", "Name?", false)
            assert(client.call(assert(system.node.id()), "close", {id = opened.id, force = true}))
            expect(view, "the app closes", "answer accept", false)
            exits(lifecycle, {pid})
        end)
    end)
end

local function node_state(): client.State
    return assert(client.state(assert(client.call(assert(system.node.id()), "list", {}))))
end

local function define_recovery_tests()
    test.describe("display recovery", function()
        display_case("ignores node events from any process but the owner", function(fixture: Fixture)
            local lifecycle = assert(process.events())
            local view, pid = fixture:start()
            open_probe(view)
            local probe = node_state().running[1].id
            process.send(pid, client.EVENTS, {kind = "closed", id = probe, revision = 1000000})
            process.send(pid, client.EVENTS, {kind = "closed", id = probe, revision = node_state().revision + 1})
            key(view, "f1")
            expect(view, "the display still answers", "Bees", true)
            key(view, "esc")
            expect(view, "the forged close leaves the probe", "label ", true)
            key(view, "w", {ctrl = true})
            expect(view, "Ctrl+W closes the probe", "label ", false)
            exits(lifecycle, {pid})
        end)

        display_case("reconnects when the node's owner fails and comes back with its apps", function(fixture: Fixture)
            local lifecycle = assert(process.events())
            local view, pid = fixture:start()
            open_probe(view)
            local before = node_state()
            local probe = before.running[1].id
            assert(process.terminate(before.owner))
            expect(view, "the failed owner takes its app with it", "label ", false)
            expect(view, "the display shows the reopened probe", "label ", true)
            local after = node_state()
            test.neq(after.owner, before.owner)
            test.eq(#after.running, 1)
            test.eq(after.running[1].id, probe)
            key(view, "w", {ctrl = true})
            expect(view, "Ctrl+W closes the reopened probe", "label ", false)
            exits(lifecycle, {pid})
        end)

        display_case("reopens a kept app in the workspace it was opened in after its desktop moved to another", function(fixture: Fixture)
            local lifecycle = assert(process.events())
            local view, pid = fixture:start()
            open_probe(view)
            local before = node_state()
            local probe = before.running[1].id
            local desktop = before.running[1].desktop
            local home_path = ""
            for _, workspace in ipairs(before.workspaces) do
                if workspace.id == before.home then home_path = workspace.path end
            end
            local other = assert(client.call(assert(system.node.id()), "workspace_add",
                {path = "/bee-test-moved/" .. tostring(time.now():unix_nano()), label = "moved"}))
            assert(client.call(assert(system.node.id()), "desktop_workspace", {id = desktop, workspace = other.workspace}))
            assert(process.terminate(before.owner))
            expect(view, "the failed owner takes its app with it", "label ", false)
            expect(view, "the display shows the reopened probe", "label ", true)
            assert(view:resize(math.max(100, #home_path + 80), 30))
            key(view, "f11")
            expect(view, "the reopened probe works in its own workspace", "workspace " .. home_path, true)
            key(view, "f11")
            assert(view:resize(100, 30))
            test.eq(node_state().running[1].id, probe)
            assert(client.call(assert(system.node.id()), "desktop_workspace", {id = desktop, workspace = before.home}))
            key(view, "w", {ctrl = true})
            expect(view, "Ctrl+W closes the reopened probe", "label ", false)
            exits(lifecycle, {pid})
        end)

        display_case("waits for an owner that stays away longer than a request waits", function(fixture: Fixture)
            local lifecycle = assert(process.events())
            local service = "bee.node.service:owner_service"
            local boot = assert(system.supervisor.state("wippy.bootloader:bootloader.service")).started_at
            local recovery = assert(system.supervisor.state("bee.gov.service:recovery_service")).started_at
            local hive = assert(process.registry.lookup("bee.hive.supervisor", process.registry.LOCAL))
            local owner = node_state().owner
            assert(process.monitor(owner))
            assert(events.send("supervisor", "service.stop", service))
            while true do
                local selected = channel.select({lifecycle:case_receive()})
                assert(selected.ok, "owner supervision closed")
                local event = selected.value :: {kind: string, from: unknown}
                if event.kind == process.event.EXIT and tostring(event.from) == owner then break end
            end

            local view, pid = fixture:start()
            expect(view, "the display shows the loader while its node is away", "Connecting to", true)
            -- The owner stays away past the time one request waits for it.
            time.sleep(client.TIMEOUT)
            time.sleep("1s")
            assert(events.send("supervisor", "service.start", service))
            expect(view, "the display shows the node once its owner is back", "Bees", true)
            test.eq(assert(system.supervisor.state("wippy.bootloader:bootloader.service")).started_at, boot)
            test.eq(assert(system.supervisor.state("bee.gov.service:recovery_service")).started_at, recovery)
            test.eq(assert(system.supervisor.state("bee:changes")).status, "running")
            test.eq(process.registry.lookup("bee.hive.supervisor", process.registry.LOCAL), hive)
            exits(lifecycle, {pid})
        end)
    end)
end

return {retirement_fixture = retirement_fixture, run = test.run_cases(function()
    define_tests()
    define_recovery_tests()
end)}
