-- MIT. An agent starts an installed application on the person's desktop and
-- talks to it while it runs: the corpus starter is delivered to a workspace,
-- the person shows a desktop of that workspace, and a stock session asks for
-- bee.app:runtime, which the person approves in Needs you. application_open
-- then opens the app in a window on that desktop; opening the running
-- singleton again delivers new arguments to the same window.
local test = require("test")
local json = require("json")
local funcs = require("funcs")
local security = require("security")
local system = require("system")
local channel = require("channel")
local process = require("process")
local tty = require("tty")
local bounds = require("bounds")
local client = require("client")
local application = require("application")
local harness = require("harness")
local sessions = require("stock_session")
local test_fixtures = require("test_fixtures")
type Object = {[string]: unknown}

local OVERLAY = "appopen"
local APP = "app.appopen.app:app"

local function node(): string return assert(system.node.id()) end

local function call(op: string, args: Object): Object
    local value, err = client.call(node(), op, args)
    if not value then error(op .. ": " .. tostring(err)) end
    return value
end

-- screen_until reads the window until a row contains text.
local function screen_until(view: tty.Viewport, text: string)
    local updates = assert(view:updates())
    while true do
        local snapshot = view:snapshot()
        for _, row in ipairs(snapshot and snapshot.rows or {}) do
            if row:find(text, 1, true) then return end
        end
        assert(channel.select({updates:case_receive()}).ok, "window update stream closed before " .. text)
    end
end

local function install_starter(workspace: string)
    local reader = funcs.new():with_actor(assert(security.new_actor("bee.tests.appopen_author", {workspace_id = workspace})))
        :with_scope(security.new_scope({assert(security.policy("bee.security.gateway:gateway_tool_docs_policy"))}))
    local page = harness.value(harness.reply(reader:call("bee.docs.binding:call", {operation = "read", id = "reference_apps/starter"})))
    local source = assert(tostring(page.content):match("```json%s*(.-)%s*```"))
    local renamed = source:gsub("app%.hello", "app." .. OVERLAY)
        :gsub("bee%.shell:apps_menu", "bee.tests.gov:unplaced_menu")
        :gsub('"type":%s*"test"', '"type":"app_test"')
    local author = harness.author(workspace, OVERLAY)
    local digest = harness.freeze(author, OVERLAY, assert(json.decode(renamed)) :: {Object}, "1")
    local requested = harness.value(harness.request(author, OVERLAY, workspace, "1", digest))
    test.eq(requested.ready, true, tostring(json.encode(requested)))
    harness.settle(author, OVERLAY, workspace, requested, "1")
end

-- close_opened closes the windows opened since before and waits until the
-- node reports each closed, so the desktop holds none when it closes.
local function close_opened(events: unknown, before: {[string]: boolean})
    local waiting: {[string]: boolean} = {}
    for id in pairs(harness.running()) do
        if not before[id] then
            waiting[id] = true
            call("close", {id = id, force = true})
        end
    end
    local inbox = events :: channel.Channel
    while next(waiting) do
        local selected = channel.select({inbox:case_receive()})
        assert(selected.ok, "node observation closed before the windows closed")
        local event = client.event(selected.value:payload():data())
        if event and event.kind == "closed" and event.id then waiting[event.id] = nil end
    end
end

local function refusal(answer: Object): string
    local result = bounds.object(answer.result)
    if result and result.isError == true then return tostring(json.encode(result.structuredContent)) end
    local fault = bounds.object(answer.error)
    return fault and tostring(fault.message) or ""
end

local function define_tests()
    test.describe("an agent opens an installed app on the person's desktop", function()
        test.after_all(test_fixtures.registry_cleanup(true))
        test.it("opens the app in the shown desktop's window and delivers new arguments to the running singleton", function()
            local workspace = harness.isolated(OVERLAY)
            local before = harness.running()
            install_starter(workspace)
            harness.close_presented(before)
            local desktop = tostring(call("desktop_create", {workspace = workspace, title = "Agent desktop"}).desktop)
            local events = assert(process.listen(client.EVENTS, {message = true}))
            test.eq(call("watch", {desktop = desktop}).desktop, desktop)

            local session = sessions.open(workspace, "appopen-agent")
            test.is_nil(sessions.listed(session).application_open)
            test.eq(refusal(sessions.tool_call(session, "application_open", {definition_id = APP, arguments = {"Ada"},
                idempotency_key = "greet-early"})), "tool is not admitted for this binding")
            local requested = sessions.structured(sessions.tool_call(session, "session", {operation = "request_access",
                idempotency_key = "appopen-runtime", traits = {"bee.app:runtime"}, reason = "Start Hello on your desktop"}))
            local asked = harness.approve(workspace, requested.approval_id)
            test.is_true(tostring(assert(bounds.object(asked.prompt)).text):find("Open apps on your desktop", 1, true) ~= nil,
                tostring(json.encode(asked.prompt)))
            local granted = sessions.structured(sessions.tool_call(session, "session", {operation = "access_status",
                approval_id = requested.approval_id}))
            test.eq(granted.status, "granted")
            test.is_true(sessions.listed(session).application_open)

            local opened = sessions.structured(sessions.tool_call(session, "application_open",
                {definition_id = APP, arguments = {"Ada"}, idempotency_key = "greet-ada"}))
            local instance = tostring(opened.instance_id)
            test.eq(opened.desktop, desktop)
            test.eq(opened.workspace_id, workspace)
            test.eq(opened.reused, false)
            local running: Object? = nil
            for _, raw in ipairs(assert(bounds.array(call("list", {}).running, 256))) do
                local item = assert(bounds.object(raw))
                if item.id == instance then running = item end
            end
            test.eq(assert(running, "the node reports the opened app running").app, APP)
            test.eq(assert(running).desktop, desktop)
            local view = assert(tty.attach(tostring(call("attach", {id = instance}).ref)))
            assert(view:resize(80, 24))
            screen_until(view, "Hello, Ada")

            local retried = sessions.structured(sessions.tool_call(session, "application_open",
                {definition_id = APP, arguments = {"Ada"}, idempotency_key = "greet-ada"}))
            test.eq(retried.instance_id, instance)
            test.eq(retried.reused, true)
            local told = sessions.structured(sessions.tool_call(session, "application_open",
                {definition_id = APP, arguments = {"Grace"}, idempotency_key = "greet-grace"}))
            test.eq(told.instance_id, instance)
            test.eq(told.reused, true)
            screen_until(view, "Hello, Grace")

            local missing = refusal(sessions.tool_call(session, "application_open",
                {definition_id = "app.appopen_absent.app:app", arguments = {}, idempotency_key = "absent"}))
            test.is_true(missing:find("FAILED", 1, true) ~= nil, missing)

            view:close()
            -- Needs you opened on the shown desktop for the access request.
            close_opened(events, before)
            call("leave", {})
            call("desktop_close", {id = desktop})
            process.unlisten(events)
            harness.value(harness.library(workspace, {operation = "uninstall", source_workspace = OVERLAY,
                receipt_key = "appopen-remove"}))
        end)

        test.it("keeps process names out of an app's scope, so an app tool cannot address the running window by name", function()
            local workspace = harness.isolated(OVERLAY .. "-names")
            local definition = assert(application.definition("bee.tests.node:probe_app"))
            local actor = assert(application.actor(workspace, "names-test", definition, 1))
            local scope = assert(application.scope(definition, workspace))
            test.is_true(scope:evaluate(actor, "process.registry.register", "app.hello:inbox") ~= "allow")
        end)
    end)
end
return test.run_cases(define_tests)
