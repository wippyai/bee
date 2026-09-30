-- MIT. Singleton reopens deliver arguments to the retained producer.
local test = require("test")
local process = require("process")
local channel = require("channel")
local security = require("security")
local time = require("time")
local tty = require("tty")
local appearance = require("appearance")
local WORKSPACE = string.rep("d", 32)

local function journey(definition: string, check: (tty.Viewport, string, integer, integer) -> ())
    local owner = tostring(process.pid())
    local events = assert(process.events())
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner,
        ["bee.workspace_id"] = WORKSPACE}):with_scope(security.new_scope({
        assert(security.policy("bee.security.desktop:broker_policy")),
        assert(security.policy("bee.security:core_spawn_boundary"))}))
        :spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults(), {})))
    local function reply(id: string): {[string]: unknown}
        local deadline = time.after("10s")
        while true do
            local selected = channel.select({replies:case_receive(), deadline:case_receive()})
            assert(selected.ok and selected.channel == replies, "broker reply timed out: " .. id)
            local message = selected.value
            local raw: unknown = message:payload():data()
            if tostring(message:from()) == broker and type(raw) == "table" and raw.request_id == id then
                return raw :: {[string]: unknown}
            end
        end
        error("broker reply channel closed")
    end
    local function open(id: string, args: {string}): {[string]: unknown}
        assert(process.send(broker, "bee.app.request", {version = 1, op = "open", request_id = id,
            workspace_id = WORKSPACE, definition_id = definition, arguments = args}))
        local result = reply(id)
        test.eq(result.error_code, "", tostring(result.error))
        return result
    end
    local ok, fault = pcall(function()
        assert(tostring(catalogs:receive():from()) == broker)
        assert(process.send(broker, "bee.app.request", {version = 1, op = "bind", request_id = "reopen-bind", workspace_id = WORKSPACE, recipient = owner}))
        test.eq(reply("reopen-bind").error_code, "")
        local first = open("reopen-first", {"src/clock.lua:2-4"})
        local retained = assert(tty.attach(tostring(first.mount)))
        assert(retained:send({type = "resize", width = 120, height = 36}))
        check(retained, "src/clock.lua", 2, 4)
        local second = open("reopen-second", {"src/apps/command.lua:5-8"})
        test.eq(second.op, "focus")
        test.eq(second.instance_id, first.instance_id)
        test.eq(second.id, first.id)
        check(retained, "src/apps/command.lua", 5, 8)
        local third = open("reopen-third", {"src/apps/command.lua:10-12"})
        test.eq(third.instance_id, first.instance_id)
        check(retained, "src/apps/command.lua", 10, 12)
        open("reopen-second", {"src/apps/command.lua:5-8"})
        open("reopen-empty", {})
        if definition == "bee.files.app:app" then
            for index, arg in ipairs({"../outside.lua:1-2", "/outside.lua:1-2", ".wippy/private.db:1-2", "src/clock.lua:0"}) do
                open("reopen-unsafe-" .. tostring(index), {arg})
            end
        end
        check(retained, "src/apps/command.lua", 10, 12)
    end)
    assert(process.cancel(broker, "reopen test complete"))
    local deadline = time.after("10s")
    while true do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel == events, "broker cleanup timed out")
        if selected.value.kind == process.event.EXIT and tostring(selected.value.from) == broker then break end
    end
    process.unlisten(catalogs)
    process.unlisten(replies)
    if not ok then error(fault) end
end

local function preview(view: tty.Viewport, path: string, first: integer, last: integer)
    local deadline = time.after("5s")
    while true do
        local rows = table.concat(assert(view:snapshot()).rows, "\n"):gsub("\27%[[%d;]*m", "")
        local matches = rows:find(path .. " (", 1, true) ~= nil
        for line = first, last do
            if not rows:find("›%s*" .. tostring(line) .. " │") then matches = false end
        end
        if matches then return end
        local poll = time.after("20ms")
        local selected = channel.select({poll:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel == poll, "preview did not move to " .. path .. ":" .. tostring(first) .. "-" .. tostring(last) .. "\n" .. rows)
    end
end
local function define_tests()
    test.describe("Workspace broker singleton reopen", function()
        test.it("moves the live Files preview to a second file and range without replacing the instance", function()
            journey("bee.files.app:app", preview)
        end)
        test.it("delivers arguments to another singleton using the shared default topic", function()
            journey("bee.apps:singleton_probe", function(view, path, first, last)
                local target = path .. ":" .. tostring(first) .. "-" .. tostring(last)
                local deadline = time.after("5s")
                while not table.concat(assert(view:snapshot()).rows):find(target, 1, true) do
                    local poll = time.after("20ms")
                    local selected = channel.select({poll:case_receive(), deadline:case_receive()})
                    assert(selected.ok and selected.channel == poll, "singleton did not receive " .. target)
                end
            end)
        end)
    end)
end
return test.run_cases(define_tests)
