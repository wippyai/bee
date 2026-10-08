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

local DISPLAY = "bee.shell:client"

local function screen(view: tty.Viewport): string
    local snapshot = view:snapshot()
    if not snapshot then return "" end
    return (table.concat(snapshot.rows, "\n"):gsub("\27%[[0-9;]*m", ""))
end

-- shows waits until the viewport shows text, or until it no longer does.
local function shows(view: tty.Viewport, text: string, present: boolean): boolean
    local updates = assert(view:updates())
    local deadline = time.after("5s")
    while true do
        if (screen(view):find(text, 1, true) ~= nil) == present then return true end
        local selected = channel.select({updates:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then return false end
    end
end

-- expect fails the test with step and the screen unless the viewport comes to
-- show text (present) or stops showing it.
local function expect(view: tty.Viewport, step: string, text: string, present: boolean)
    if not shows(view, text, present) then error(step .. ": screen was\n" .. screen(view)) end
end

local function key(view: tty.Viewport, name: string, modifiers: {[string]: boolean}?)
    local event: {[string]: unknown} = {type = "key", key = name, key_type = #name == 1 and "runes" or name, action = "press"}
    for flag, value in pairs(modifiers or {}) do event[flag] = value end
    assert(view:send(event))
end

local function start(): (tty.Viewport, string)
    local view = assert(tty.viewport({width = 100, height = 30}))
    local pid = assert(process.with_options({terminal = assert(view:grant())})
        :spawn_monitored(DISPLAY, "bee:workers", assert(system.node.id())))
    return view, tostring(pid)
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

local function exits(lifecycle: unknown, pids: {string})
    local events = lifecycle :: channel.Channel
    local waiting: {[string]: boolean} = {}
    for _, pid in ipairs(pids) do
        waiting[pid] = true
        assert(process.cancel(pid))
    end
    local deadline = time.after("5s")
    while next(waiting) do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then error("displays did not exit") end
        if selected.value.kind == process.event.EXIT then waiting[tostring(selected.value.from)] = nil end
    end
end

-- open_probe selects the probe after Agents and Needs you in the Apps menu.
local function open_probe(view: tty.Viewport)
    expect(view, "an empty desktop opens the Start panel", "Bees", true)
    key(view, "enter")
    expect(view, "Apps lists the probe", "Probe", true)
    expect(view, "Apps lists the Inbox", "Needs you", true)
    expect(view, "Apps lists Agents", "Agents", true)
    key(view, "down")
    key(view, "down")
    key(view, "enter")
    expect(view, "the probe opens in a window", "label ", true)
end

local function define_tests()
    test.describe("displays", function()
        test.it("open apps on their own desktops, switch desktops, survive an upgrade and close apps", function()
            local lifecycle = assert(process.events())
            local before = running()
            local first, first_pid = start()
            expect(first, "first display shows the bar", " BEE ", true)
            open_probe(first)
            test.eq(running(), before + 1)
            local first_label = bar(first):match("(Desktop %d+)")

            local second, second_pid = start()
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
            -- The owner takes its new code when it next handles an event; the
            -- upgrade is not observable from outside, so the test lets it land.
            time.sleep("300ms")
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
            first:close()
            second:close()
        end)

        test.it("opens the app a command names full-pane when bee runs with that command", function()
            local lifecycle = assert(process.events())
            local view = assert(tty.viewport({width = 100, height = 30}))
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
            local opened, shown_on = "", ""
            for _, instance in ipairs(assert(client.state(assert(client.call(assert(system.node.id()), "list", {})))).running) do
                if instance.app == "bee.tests.node:probe_app" then opened, shown_on = instance.id, instance.desktop end
            end
            -- An app another display opens on this desktop joins the bar; the
            -- full-pane probe keeps the pane and the keyboard.
            local other = assert(client.call(assert(system.node.id()), "open", {app = "bee.tests.node:probe_single", desktop = shown_on}))
            expect(view, "the other app joins the bar", "Single probe", true)
            local after = assert(view:snapshot())
            test.is_true((after.rows[2]:gsub("\27%[[0-9;]*m", "")):match("^theme ") ~= nil, "the full-pane probe keeps the pane")
            assert(client.call(assert(system.node.id()), "close", {id = other.id}))
            assert(client.call(assert(system.node.id()), "close", {id = opened}))
            key(view, "q", {ctrl = true})
            exits(lifecycle, {pid})
            view:close()
        end)

        test.it("opens a command's app full-pane from a client display of the folder's node", function()
            local lifecycle = assert(process.events())
            local view = assert(tty.viewport({width = 100, height = 30}))
            local pid = tostring(assert(process.with_options({terminal = assert(view:grant())})
                :spawn_monitored(DISPLAY, "bee:workers", assert(system.node.id()), "probe", "tail")))
            expect(view, "the command opens the probe", "args from-command tail", true)
            local snapshot = assert(view:snapshot())
            test.is_true((snapshot.rows[2]:gsub("\27%[[0-9;]*m", "")):match("^theme ") ~= nil, "the probe fills the pane")
            local opened = ""
            for _, instance in ipairs(assert(client.state(assert(client.call(assert(system.node.id()), "list", {})))).running) do
                if instance.app == "bee.tests.node:probe_app" then opened = instance.id end
            end
            assert(client.call(assert(system.node.id()), "close", {id = opened}))
            exits(lifecycle, {pid})
            view:close()
        end)

        test.it("exits on a command no installed app answers", function()
            local lifecycle = assert(process.events())
            local view = assert(tty.viewport({width = 100, height = 30}))
            local pid = tostring(assert(process.with_options({terminal = assert(view:grant())})
                :spawn_monitored("bee.shell:main", "bee:workers", "no-such-agent")))
            local events = lifecycle :: channel.Channel
            local deadline = time.after("10s")
            while true do
                local selected = channel.select({events:case_receive(), deadline:case_receive()})
                if selected.channel == deadline then error("bee did not exit on an unknown command") end
                if selected.value.kind == process.event.EXIT and tostring(selected.value.from) == pid then break end
            end
            view:close()
        end)

        test.it("alerts on arrival, preserves a busy keyboard and opens the request by key or click", function()
            local lifecycle = assert(process.events())
            local view, pid = start()
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
            view:close()
        end)

        test.it("shows an app's question over the desktop and sends the person's answer back to the app", function()
            local lifecycle = assert(process.events())
            local view, pid = start()
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
            view:close()
        end)
    end)
end

local function node_state(): client.State
    return assert(client.state(assert(client.call(assert(system.node.id()), "list", {}))))
end

local function define_recovery_tests()
    test.describe("display recovery", function()
        test.it("ignores node events from any process but the owner", function()
            local lifecycle = assert(process.events())
            local view, pid = start()
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
            view:close()
        end)

        test.it("reconnects when the node's owner fails and comes back with its apps", function()
            local lifecycle = assert(process.events())
            local view, pid = start()
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
            view:close()
        end)

        test.it("reopens a kept app in the workspace it was opened in after its desktop moved to another", function()
            local lifecycle = assert(process.events())
            local view, pid = start()
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
            expect(view, "the reopened probe works in its own workspace", "workspace " .. home_path, true)
            test.eq(node_state().running[1].id, probe)
            assert(client.call(assert(system.node.id()), "desktop_workspace", {id = desktop, workspace = before.home}))
            key(view, "w", {ctrl = true})
            expect(view, "Ctrl+W closes the reopened probe", "label ", false)
            exits(lifecycle, {pid})
            view:close()
        end)

        test.it("waits for an owner that stays away longer than a request waits", function()
            local lifecycle = assert(process.events())
            local service = "bee.node.service:owner_service"
            local owner = node_state().owner
            assert(process.monitor(owner))
            assert(events.send("supervisor", "service.stop", service))
            local deadline = time.after("5s")
            while true do
                local selected = channel.select({lifecycle:case_receive(), deadline:case_receive()})
                if selected.channel == deadline then error("the owner did not stop with its service") end
                local event = selected.value :: {kind: string, from: unknown}
                if event.kind == process.event.EXIT and tostring(event.from) == owner then break end
            end

            local view, pid = start()
            expect(view, "the display shows the loader while its node is away", "Connecting to", true)
            -- The owner stays away past the time one request waits for it.
            time.sleep(client.TIMEOUT)
            time.sleep("1s")
            assert(events.send("supervisor", "service.start", service))
            expect(view, "the display shows the node once its owner is back", "Bees", true)
            exits(lifecycle, {pid})
            view:close()
        end)
    end)
end

local cases = test.run_cases(function()
    define_tests()
    define_recovery_tests()
end)
return {run = function(options: unknown) return cases(options) end}
