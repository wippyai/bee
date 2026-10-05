-- MIT. The node owner answers Hive operations: it reports its state with a
-- desktop for the watching display, lists apps and themes, opens an app on a
-- desktop into a viewport a caller can attach to, applies an appearance to
-- its apps and watchers, manages workspaces and desktops, and stops apps,
-- telling its watchers each time.
local test = require("test")
local process = require("process")
local channel = require("channel")
local system = require("system")
local time = require("time")
local tty = require("tty")
local sql = require("sql")
local registry = require("registry")
local events_bus = require("events")
local appearance = require("appearance")
local client = require("client")

local PROBE = "bee.tests.node:probe_app"
local SINGLE = "bee.tests.node:probe_single"

local function node(): string
    return assert(system.node.id())
end

local function call(op: string, args: {[string]: unknown}): {[string]: unknown}
    local value, err = client.call(node(), op, args)
    if not value then error(op .. ": " .. tostring(err)) end
    return value
end

-- next_event waits for the next node event of kind.
local function next_event(events: unknown, kind: string): client.Event
    local inbox = events :: channel.Channel
    local deadline = time.after("5s")
    while true do
        local selected = channel.select({inbox:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then error("no " .. kind .. " event") end
        local event = client.event(selected.value:payload():data())
        if event and event.kind == kind then return event end
    end
end

-- rows_until reads the viewport until row contains text.
local function rows_until(view: tty.Viewport, row: integer, text: string): boolean
    local updates = assert(view:updates())
    local deadline = time.after("5s")
    while true do
        local snapshot = view:snapshot()
        if snapshot and snapshot.rows[row] and snapshot.rows[row]:find(text, 1, true) then return true end
        local selected = channel.select({updates:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then return false end
    end
end

-- close_all closes the instances ids and waits until the node reports each
-- closed, so no closed event reaches a later test.
local function close_all(events: unknown, ids: {string})
    local waiting: {[string]: boolean} = {}
    for _, id in ipairs(ids) do
        waiting[id] = true
        local _, err = client.call(node(), "close", {id = id})
        if err then error("close: " .. tostring(err)) end
    end
    while next(waiting) do
        local closed = next_event(events, "closed")
        waiting[tostring(closed.id)] = nil
    end
end

local function watched(): client.State
    return assert(client.state(call("watch", {})))
end

local function home_workspace(state: client.State): client.Workspace
    for _, workspace in ipairs(state.workspaces) do
        if workspace.id == state.home then return workspace end
    end
    error("no home workspace")
end

local function desktop_of(desktops: {client.Desktop}, id: string): client.Desktop?
    for _, desktop in ipairs(desktops) do
        if desktop.id == id then return desktop end
    end
    return nil
end

local function kept(id: string): boolean
    local db = assert(sql.get("bee:db"))
    local rows = assert(db:query("SELECT id FROM bee_node_instances WHERE id = ?", {id}))
    db:release()
    return rows[1] ~= nil
end

type Stub = {pid: string, replies: unknown}

local function stub(): Stub
    local replies = assert(process.listen("display_stub.reply", {message = true}))
    local pid = assert(process.spawn_monitored("bee.tests.node:display_stub", "bee:workers"))
    return {pid = tostring(pid), replies = replies}
end

-- by runs op on the node from the stub display and returns its value and error.
local function by(display: Stub, op: string, args: {[string]: unknown}): ({[string]: unknown}?, string?)
    assert(process.send(display.pid, "request", {op = op, args = args}))
    local deadline = time.after("5s")
    local selected = channel.select({(display.replies :: channel.Channel):case_receive(), deadline:case_receive()})
    if selected.channel == deadline then error("the stub display did not answer " .. op) end
    local reply = (selected.value :: process.Message):payload():data() :: {value: {[string]: unknown}?, error: string?}
    return reply.value, reply.error
end

local function shown(desktops: {client.Desktop}, id: string): boolean
    local desktop = desktop_of(desktops, id)
    return desktop ~= nil and desktop.shown
end

-- announced waits for a workspaces event whose desktops satisfy expected.
local function announced(events: unknown, step: string, expected: ({client.Desktop}) -> boolean)
    local inbox = events :: channel.Channel
    local deadline = time.after("5s")
    while true do
        local selected = channel.select({inbox:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then error(step) end
        local event = client.event(selected.value:payload():data())
        if event and event.kind == "workspaces" and expected(assert(event.desktops)) then return end
    end
end

local function define_tests()
    test.describe("node", function()
        test.it("runs each app as its own application principal of its workspace, with a bee.app launch, its workspace in its host context and none of the owner's authority", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local state = watched()
            local home = home_workspace(state)
            local opened = call("open", {app = PROBE, desktop = assert(state.desktop)})
            local instance = tostring(opened.id)
            local view = assert(tty.attach(tostring(call("attach", {id = instance}).ref)))
            test.is_true(rows_until(view, 4, "actor bee.application"))
            test.is_true(rows_until(view, 5, "of " .. home.id))
            test.is_true(rows_until(view, 6, "instance " .. instance))
            test.is_true(rows_until(view, 7, "acts for " .. home.id))
            test.is_true(rows_until(view, 8, "launch " .. instance))
            test.is_true(rows_until(view, 9, "authority none"))
            test.is_true(rows_until(view, 11, "context " .. home.id))
            view:close()
            call("close", {id = instance})
            test.eq(next_event(events, "closed").id, instance)
            process.unlisten(events)
        end)

        test.it("adds an app's admission to its scope: its policies, and scope management when admitted", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local state = watched()
            local opened = call("open", {app = SINGLE, desktop = assert(state.desktop)})
            local instance = tostring(opened.id)
            local view = assert(tty.attach(tostring(call("attach", {id = instance}).ref)))
            local admitted = rows_until(view, 9, "authority security.scope.create bee.tests.probe")
            local snapshot = view:snapshot()
            test.is_true(admitted, "probe shows " .. tostring(snapshot and snapshot.rows[9]))
            view:close()
            close_all(events, {instance})
            process.unlisten(events)
        end)

        test.it("names every workspace by its canonical identity, 32 lowercase hex digits", function()
            local state = watched()
            test.is_true(#state.workspaces >= 1)
            for _, workspace in ipairs(state.workspaces) do
                test.is_true(#workspace.id == 32 and not workspace.id:find("[^0-9a-f]"), "workspace " .. workspace.id)
            end
        end)

        test.it("reports its state with a desktop, its workspaces, an appearance and the probe app", function()
            local state = watched()
            test.eq(state.node, node())
            test.not_nil(state.desktop)
            test.not_nil(desktop_of(state.desktops, tostring(state.desktop)))
            test.not_nil(home_workspace(state))
            test.not_nil(appearance.decode_theme(state.appearance.theme))
            local probe = false
            for _, app in ipairs(state.apps) do
                if app.id == PROBE then probe = true end
            end
            test.is_true(probe)
        end)

        test.it("opens a singleton app once per desktop and an app of many instances each time", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local state = watched()
            local desktop = tostring(state.desktop)
            local first = call("open", {app = SINGLE, desktop = desktop})
            local again = call("open", {app = SINGLE, desktop = desktop})
            test.eq(again.id, first.id)
            test.is_true(again.existing == true)
            local one = call("open", {app = PROBE, desktop = desktop})
            local two = call("open", {app = PROBE, desktop = desktop})
            test.neq(one.id, two.id)
            close_all(events, {tostring(first.id), tostring(one.id), tostring(two.id)})
            process.unlisten(events)
        end)

        test.it("resolves a command name to the app it opens and the arguments it opens with", function()
            local resolved = call("command", {name = "probe", arguments = {"more"}})
            test.eq(resolved.app, PROBE)
            local arguments = resolved.arguments :: {string}
            test.eq(arguments[1], "from-command")
            test.eq(arguments[2], "more")
            test.is_true(resolved.fullscreen == true)
            local _, unknown = client.call(node(), "command", {name = "nothing-here", arguments = {}})
            test.contains(tostring(unknown), "Unknown Bee command: nothing-here")
            local sessions = call("command", {name = "claude", arguments = {}})
            test.eq(sessions.app, "bee.harness.app:app")
        end)

        test.it("reports its runtime numbers and running apps for the hive view", function()
            local state = watched()
            local opened = call("open", {app = PROBE, desktop = assert(state.desktop)})
            local stats = call("stats", {})
            test.eq(stats.node, node())
            test.eq(stats.name, home_workspace(state).label)
            test.is_true(type(stats.heap) == "number" and stats.heap > 0)
            test.is_true(type(stats.reserved) == "number" and stats.reserved >= stats.heap)
            test.is_true(type(stats.goroutines) == "number" and stats.goroutines > 0)
            test.is_true(type(stats.cpu_count) == "number" and stats.cpu_count > 0)
            test.is_true(type(stats.apps) == "number" and stats.apps >= 1)
            test.is_true(type(stats.workspaces) == "number" and stats.workspaces >= 1)
            local events = assert(process.listen(client.EVENTS, {message = true}))
            close_all(events, {tostring(opened.id)})
            process.unlisten(events)
        end)

        test.it("refuses open without a desktop or with args that are not a table", function()
            local state = watched()
            local _, missing = client.call(node(), "open", {app = PROBE})
            test.contains(tostring(missing), "needs a desktop")
            local _, err = client.call(node(), "open", {app = PROBE, desktop = state.desktop, args = "nope"})
            test.contains(tostring(err), "args must be a table")
        end)

        test.it("lists installed themes and refuses one that is not installed", function()
            local listed = call("themes", {})
            test.is_true(type(listed.themes) == "table" and #listed.themes >= 1)
            local _, err = client.call(node(), "appearance", {theme = "acme:missing"})
            test.contains(tostring(err), "not installed")
            local _, background = client.call(node(), "appearance", {background = "lava"})
            test.contains(tostring(background), "unknown background")
        end)

        test.it("opens an app on a desktop, keeps it, restyles it and its watchers, and stops it", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local state = watched()
            local desktop = tostring(state.desktop)
            local themes = call("themes", {}).themes :: {{[string]: unknown}}
            local target = tostring(themes[#themes].id)
            if target == state.appearance.theme.id then target = tostring(themes[1].id) end

            local opened = call("open", {app = PROBE, desktop = desktop, args = {label = "for-test"}})
            local id = tostring(opened.id)
            test.eq(opened.desktop, desktop)
            test.eq((next_event(events, "opened").instance or {desktop = ""}).desktop, desktop)
            test.is_true(kept(id))
            local view = assert(tty.attach(tostring(call("attach", {id = id}).ref)))
            test.is_true(rows_until(view, 2, "label for-test"))
            test.is_true(rows_until(view, 3, "workspace " .. home_workspace(state).path))

            call("appearance", {theme = target, background = "grid"})
            local changed = next_event(events, "appearance").appearance or appearance.defaults()
            test.eq(changed.theme.id, target)
            test.eq(changed.background, "grid")
            test.is_true(rows_until(view, 1, "theme " .. target))

            call("close", {id = id})
            test.eq(next_event(events, "closed").id, id)
            test.is_false(kept(id))
            view:close()
            process.unlisten(events)
        end)
    end)

    test.describe("attention", function()
        -- presented waits for the opened event of an app on desktop and the
        -- attention event that brings that same instance forward.
        local function presented(events: unknown, desktop: string, app_prefix: string): string
            local inbox = events :: channel.Channel
            local deadline = time.after("5s")
            local opened: string? = nil
            while true do
                local selected = channel.select({inbox:case_receive(), deadline:case_receive()})
                if selected.channel == deadline then error("nothing presented for " .. app_prefix) end
                local event = client.event(selected.value:payload():data())
                if event and event.kind == "opened" and event.instance and event.instance.desktop == desktop
                    and event.instance.app:sub(1, #app_prefix) == app_prefix then opened = event.instance.id end
                if event and event.kind == "attention" and opened and event.id == opened then return opened end
            end
        end
        test.it("opens the app declaring the approvals role on a watched desktop of the workspace and brings it forward", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local state = watched()
            local desktop = tostring(state.desktop)
            assert(events_bus.send("bee.attention", "approval.requested", home_workspace(state).id, {approval_id = "approval-probe"}))
            local id = presented(events, desktop, "bee.approvals.inbox.app:")
            close_all(events, {id})
            process.unlisten(events)
        end)
        test.it("opens an approved component's applications once it is applied", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local state = watched()
            local desktop = tostring(state.desktop)
            assert(events_bus.send("bee.attention", "application.applied", home_workspace(state).id, {component = "bee.tests.node"}))
            local id = presented(events, desktop, "bee.tests.node:")
            close_all(events, {id})
            process.unlisten(events)
        end)
    end)

    test.describe("catalog", function()
        test.it("announces installed apps to watchers when the registry changes", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            watched()
            local snapshot = assert(registry.snapshot())
            local changes = snapshot:changes()
            assert(changes:create({id = "bee.tests.node:installed_app", kind = "process.lua",
                meta = {type = "bee.app", application = {api_version = 1, title = "Installed", lifetime = "view",
                    revision = "1", instance_policy = "singleton"}},
                data = {source = "return {main = function() end}", method = "main"}}))
            assert(changes:apply())
            local found = false
            while not found do
                for _, app in ipairs(next_event(events, "catalog").apps or {}) do
                    if app.id == "bee.tests.node:installed_app" then found = true end
                end
            end
            local removal = assert(registry.snapshot()):changes()
            assert(removal:delete("bee.tests.node:installed_app"))
            assert(removal:apply())
            local gone = false
            while not gone do
                gone = true
                for _, app in ipairs(next_event(events, "catalog").apps or {}) do
                    if app.id == "bee.tests.node:installed_app" then gone = false end
                end
            end
            process.unlisten(events)
        end)
    end)

    test.describe("workspaces and desktops", function()
        test.it("adds a workspace and lets a desktop work there; apps opened on it start in that folder", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local state = watched()
            local desktop = tostring(state.desktop)
            local path = "/bee-test-workspace/" .. tostring(time.now():unix_nano())
            local workspace = tostring(call("workspace_add", {path = path, label = "probe space"}).workspace)
            call("desktop_workspace", {id = desktop, workspace = workspace})
            local used = false
            while not used do
                local announced = next_event(events, "workspaces")
                local found = desktop_of(announced.desktops or {}, desktop)
                used = found ~= nil and found.workspace == workspace
            end
            local opened = call("open", {app = PROBE, desktop = desktop})
            local view = assert(tty.attach(tostring(call("attach", {id = opened.id}).ref)))
            test.is_true(rows_until(view, 3, "workspace " .. path))
            call("close", {id = opened.id})
            next_event(events, "closed")
            view:close()
            call("desktop_workspace", {id = desktop, workspace = state.home})
            process.unlisten(events)
        end)

        test.it("creates, renames and closes desktops in one set for the node", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local state = watched()
            local created = call("desktop_create", {})
            local id = tostring(created.desktop)
            test.matches(tostring(created.title), "^Desktop %d+$")
            local listed = client.desktops(call("workspaces", {}).desktops)
            test.eq((desktop_of(listed, id) or {workspace = ""}).workspace, state.home)
            call("desktop_rename", {id = id, title = "Notes"})
            local renamed = false
            while not renamed do
                local found = desktop_of(next_event(events, "workspaces").desktops or {}, id)
                renamed = found ~= nil and found.title == "Notes"
            end
            local _, shown = client.call(node(), "desktop_close", {id = tostring(state.desktop)})
            test.contains(tostring(shown), "a display shows that desktop")
            call("desktop_close", {id = id})
            test.is_nil(desktop_of(client.desktops(call("workspaces", {}).desktops), id))
            process.unlisten(events)
        end)

        test.it("removes a workspace no desktop works in and keeps the others", function()
            local state = watched()
            local path = "/bee-test-removed/" .. tostring(time.now():unix_nano())
            local workspace = tostring(call("workspace_add", {path = path .. "/./"}).workspace)
            local listed = client.workspaces(call("workspaces", {}).workspaces)
            local found = false
            for _, item in ipairs(listed) do
                if item.id == workspace then found = true; test.eq(item.path, path) end
            end
            test.is_true(found)
            local _, home = client.call(node(), "workspace_remove", {id = state.home})
            test.contains(tostring(home), "own folder")
            call("desktop_workspace", {id = state.desktop, workspace = workspace})
            local _, used = client.call(node(), "workspace_remove", {id = workspace})
            test.contains(tostring(used), "works in that workspace")
            call("desktop_workspace", {id = state.desktop, workspace = state.home})
            call("workspace_remove", {id = workspace})
            for _, item in ipairs(client.workspaces(call("workspaces", {}).workspaces)) do test.neq(item.id, workspace) end
        end)

        test.it("refuses a workspace that is not an absolute path and a desktop in no workspace", function()
            local _, err = client.call(node(), "workspace_add", {path = "relative/place"})
            test.contains(tostring(err), "absolute path")
            local state = watched()
            local _, missing = client.call(node(), "desktop_workspace", {id = state.desktop, workspace = "nowhere"})
            test.contains(tostring(missing), "no such workspace")
        end)

        test.it("moves a running app to another desktop and announces it", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local state = watched()
            local other = tostring(call("desktop_create", {}).desktop)
            local opened = call("open", {app = PROBE, desktop = state.desktop})
            local id = tostring(opened.id)
            local moved = call("move", {id = id, desktop = other})
            test.eq(moved.desktop, other)
            local announced = next_event(events, "moved")
            test.eq((announced.instance or {desktop = ""}).desktop, other)
            local _, missing = client.call(node(), "move", {id = id, desktop = "nowhere"})
            test.contains(tostring(missing), "no such desktop")
            call("close", {id = id})
            next_event(events, "closed")
            call("desktop_close", {id = other})
            process.unlisten(events)
        end)

        test.it("forgets a display that leaves", function()
            local state = watched()
            local created = call("desktop_create", {})
            call("show", {desktop = created.desktop})
            call("leave", {})
            call("desktop_close", {id = created.desktop})
            call("watch", {desktop = state.desktop})
        end)

        test.it("shows each desktop on one display at a time", function()
            local mine = watched()
            local other = stub()
            local theirs = assert(client.state(assert(by(other, "watch", {desktop = mine.desktop}))))
            test.neq(theirs.desktop, mine.desktop)
            test.ok(shown(theirs.desktops, mine.desktop), "the snapshot marks the desktop the test display shows")
            test.ok(shown(theirs.desktops, tostring(theirs.desktop)), "the snapshot marks the stub display's own desktop")
            local _, refused = by(other, "show", {desktop = mine.desktop})
            test.contains(tostring(refused), "shown on another display")

            local events = assert(process.listen(client.EVENTS, {message = true}))
            local created = call("desktop_create", {})
            local switched = tostring(created.desktop)
            assert(by(other, "show", {desktop = switched}))
            announced(events, "the node announces the desktop the stub switched to and frees the one it left", function(desktops)
                return shown(desktops, switched) and not shown(desktops, tostring(theirs.desktop))
            end)
            assert(process.cancel(other.pid))
            announced(events, "the node frees the desktop of a display that exits", function(desktops)
                return not shown(desktops, switched)
            end)
            call("desktop_close", {id = created.desktop})
            process.unlisten(events)
            process.unlisten(other.replies :: channel.Channel)
        end)

        test.it("records the desktop a display shows", function()
            local state = watched()
            local created = call("desktop_create", {})
            call("show", {desktop = created.desktop})
            local _, err = client.call(node(), "desktop_close", {id = tostring(created.desktop)})
            test.contains(tostring(err), "a display shows that desktop")
            call("show", {desktop = state.desktop})
            call("desktop_close", {id = created.desktop})
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
