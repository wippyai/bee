-- MIT. The node owner brokers its apps: an app titles its window, negotiates
-- its close, asks the display a question, keeps a checkpoint the node gives
-- back when it reopens the app, and navigates to an app already running.
local test = require("test")
local process = require("process")
local channel = require("channel")
local system = require("system")
local time = require("time")
local tty = require("tty")
local sql = require("sql")
local client = require("client")

local BROKER = "bee.tests.node:broker_probe"

type Object = {[string]: unknown}

local function call(op: string, args: Object): Object
    local value, err = client.call(assert(system.node.id()), op, args)
    if not value then error(op .. ": " .. tostring(err)) end
    return value
end

local function raw_event(events: unknown, kind: string): Object
    local inbox = events :: channel.Channel
    local deadline = time.after("5s")
    while true do
        local selected = channel.select({inbox:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then error("no " .. kind .. " event") end
        local data: unknown = selected.value:payload():data()
        if type(data) == "table" and data.kind == kind then return data end
    end
end

local function shows(view: tty.Viewport, row: integer, text: string): boolean
    local updates = assert(view:updates())
    local deadline = time.after("5s")
    while true do
        local snapshot = view:snapshot()
        if snapshot and snapshot.rows[row] and snapshot.rows[row]:find(text, 1, true) then return true end
        local selected = channel.select({updates:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then return false end
    end
end

local function open(events: unknown, arguments: {string}): (string, tty.Viewport)
    local state = assert(client.state(call("watch", {})))
    local opened = call("open", {app = BROKER, desktop = assert(state.desktop), args = {arguments = arguments}})
    local id = tostring(opened.id)
    raw_event(events, "opened")
    return id, assert(tty.attach(tostring(call("attach", {id = id}).ref)))
end

local function closed(events: unknown, id: string)
    test.eq(raw_event(events, "closed").id, id)
end

local function define_tests()
    test.describe("node broker", function()
        test.it("titles an app's window as the app says and tells the watchers", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local id, view = open(events, {"accept"})
            local titled = raw_event(events, "title")
            test.eq(titled.id, id)
            test.eq(titled.title, "Broker probe accept")
            test.eq(call("attach", {id = id}).title, "Broker probe accept")
            view:close()
            call("close", {id = id})
            closed(events, id)
            process.unlisten(events)
        end)

        test.it("asks a negotiating app before closing it and closes it when the app accepts", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local id, view = open(events, {"accept", "", "", "", "observe-close"})
            raw_event(events, "title")
            local pid = ""
            for _, instance in ipairs(assert(client.state(call("list", {}))).running) do
                if instance.id == id then pid = instance.pid end
            end
            assert(pid ~= "")
            test.is_true(call("close", {id = id}).closing == true)
            test.is_true(shows(view, 5, "close asked"))
            assert(process.send(pid, "bee.tests.close_seen", {}))
            closed(events, id)
            view:close()
            process.unlisten(events)
        end)

        test.it("keeps an app that cancels its close running, and stops it when the close is forced", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local id, view = open(events, {"cancel"})
            raw_event(events, "title")
            call("close", {id = id})
            test.is_true(shows(view, 5, "close cancelled"))
            local running = false
            for _, instance in ipairs((assert(client.state(call("watch", {}))).running)) do
                if instance.id == id then running = true end
            end
            test.is_true(running)
            call("close", {id = id, force = true})
            closed(events, id)
            view:close()
            process.unlisten(events)
        end)

        test.it("shows an app's close confirmation on the display and closes on acceptance", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local id, view = open(events, {"confirm"})
            raw_event(events, "title")
            call("close", {id = id})
            local asked = raw_event(events, "dialog")
            local dialog = asked.dialog :: Object
            test.eq(dialog.id, id)
            test.eq(dialog.kind, "confirm")
            test.eq(dialog.title, "Close probe?")
            test.eq(dialog.message, "It has work")
            call("answer", {id = id, request_id = dialog.request_id, action = "accept", value = ""})
            closed(events, id)
            view:close()
            process.unlisten(events)
        end)

        test.it("puts an app's question to the display, lists it to a new watcher and returns the answer", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local id, view = open(events, {"accept", "Name?"})
            local asked = raw_event(events, "dialog")
            local dialog = asked.dialog :: Object
            test.eq(dialog.kind, "text")
            test.eq(dialog.title, "Name?")
            test.eq(dialog.initial, "draft")
            local listed = false
            for _, item in ipairs((call("watch", {}).dialogs or {}) :: {Object}) do
                if item.id == id and item.request_id == dialog.request_id then listed = true end
            end
            test.is_true(listed)
            local _, stale = client.call(assert(system.node.id()), "answer", {id = id, request_id = "stale", action = "accept", value = "x"})
            test.not_nil(stale)
            call("answer", {id = id, request_id = dialog.request_id, action = "accept", value = "hello"})
            test.eq(raw_event(events, "dialog_closed").id, id)
            test.is_true(shows(view, 2, "answer accept hello"))
            view:close()
            call("close", {id = id})
            closed(events, id)
            process.unlisten(events)
        end)

        test.it("keeps an app's checkpoint with its instance for the node to give back", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local id, view = open(events, {"accept", "", "state-1"})
            test.is_true(shows(view, 3, "checkpoint |"))
            local db = assert(sql.get("bee:db"))
            local rows = assert(db:query("SELECT args FROM bee_node_instances WHERE id = ?", {id}))
            db:release()
            test.is_true(tostring(rows[1] and rows[1].args):find('"resume_state":"state-1"', 1, true) ~= nil)
            view:close()
            call("close", {id = id})
            closed(events, id)
            process.unlisten(events)
        end)

        test.it("delivers navigation to the singleton app already running instead of opening another", function()
            local events = assert(process.listen(client.EVENTS, {message = true}))
            local id, view = open(events, {"accept", "", "", "navigate"})
            test.is_true(shows(view, 4, "navigated to here"))
            local count = 0
            for _, instance in ipairs((assert(client.state(call("watch", {}))).running)) do
                if instance.app == BROKER then count = count + 1 end
            end
            test.eq(count, 1)
            view:close()
            call("close", {id = id})
            closed(events, id)
            process.unlisten(events)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
