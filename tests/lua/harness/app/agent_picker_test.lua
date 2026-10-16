-- SPDX-License-Identifier: MIT
local test = require("test")
local tty = require("tty")
local system = require("system")
local time = require("time")
local channel = require("channel")
local client = require("client")
local registry = require("registry")
local process = require("process")
local bounds = require("bounds")

local function call(operation: string, request: {[string]: unknown}): {[string]: unknown}
    return assert(client.call(assert(system.node.id()), operation, request))
end
local function await(viewport: tty.Viewport, needle: string, absent: string?, present: string?): string
    local updates = assert(viewport:updates())
    local deadline = time.after("10s")
    while true do
        local snapshot = viewport:snapshot()
        local shown = snapshot and tty.text.plain(table.concat(snapshot.rows, "\n")) or ""
        if shown:find(needle, 1, true) and (not absent or not shown:find(absent, 1, true))
            and (not present or shown:find(present, 1, true)) then return shown end
        local selected = channel.select({updates:case_receive(), deadline:case_receive()})
        assert(selected.channel ~= deadline, "Agents screen did not show " .. needle .. "\n" .. shown)
    end
end
local function key(viewport: tty.Viewport, kind: string, value: string?)
    assert(viewport:send({type = "key", action = "press", key_type = kind, key = value or ""}))
end
-- swap makes the node's sessions owner and catalog the defaults for body;
-- with held, the catalog lists the test definition and opening it calls held.
local function swap(held: string?, body: () -> ())
    local originals: {registry.Entry} = {}
    local changes = assert(registry.snapshot()):changes()
    for _, ref in ipairs({"bee.tests.threads.sessions:fake_owner", "bee.tests.threads.sessions:fake_catalog_owner", "bee.threads.sessions.binding:owner_binding", "bee.threads.sessions.binding:catalog_binding"}) do
        originals[#originals + 1] = assert(registry.get(ref))
        local entry = assert(registry.get(ref))
        local data = assert(bounds.object(entry.data))
        for _, contract in ipairs(assert(bounds.array(data.contracts, 2))) do
            local selected = assert(bounds.object(contract))
            selected.default = ref:find("bee.threads", 1, true) ~= nil
            local methods = assert(bounds.object(selected.methods))
            if held and ref == "bee.threads.sessions.binding:owner_binding" then methods.open = held end
            if held and ref == "bee.threads.sessions.binding:catalog_binding" then methods.list = "bee.tests.threads.sessions:fake_held_catalog" end
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
    test.describe("Agent launch feedback", function()
        test.it("shows the launch frame from the keypress while the session opens", function()
            assert(process.registry.register("bee.tests.threads.sessions.held_open"))
            local held = assert(process.listen("bee.tests.held_open.held", {message = true}))
            swap("bee.tests.threads.sessions:fake_held_open", function()
                local state = assert(client.state(call("watch", {})))
                local opened = call("open", {app = "bee.harness.app:app", desktop = state.desktop})
                local id = tostring(opened.id)
                local viewport = assert(tty.attach(tostring(call("attach", {id = id}).ref)))
                local opener: string? = nil
                local ok, failure = pcall(function()
                    assert(viewport:resize(120, 40))
                    await(viewport, "SESSIONS")
                    key(viewport, "runes", "p")
                    await(viewport, "Held", "Loading profiles")
                    key(viewport, "enter")
                    await(viewport, "START AGENT")
                    key(viewport, "enter")
                    local waiting = channel.select({held:case_receive(), time.after("10s"):case_receive()})
                    assert(waiting.channel == held, "the session open did not start")
                    opener = tostring(waiting.value:from())
                    local shown = await(viewport, "Starting Agent", "PROFILES", "Opening session")
                    test.contains(shown, "Opening session")
                    process.send(tostring(opener), "bee.tests.held_open.resume", {})
                    opener = nil
                    test.contains(await(viewport, "held open refused", "Starting Agent", "PROFILES"), "Held")
                end)
                if opener then process.send(opener, "bee.tests.held_open.resume", {}) end
                call("close", {id = id})
                viewport:close()
                call("leave", {})
                if not ok then error(tostring(failure)) end
            end)
            process.unlisten(held)
            process.registry.unregister("bee.tests.threads.sessions.held_open")
        end)
    end)
    test.describe("Agent profile search", function()
        test.it("filters typed rune chunks and erases a complete Unicode character", function()
            swap(nil, function()
                local state = assert(client.state(call("watch", {})))
                local opened = call("open", {app = "bee.harness.app:app", desktop = state.desktop})
                local id = tostring(opened.id)
                local viewport = assert(tty.attach(tostring(call("attach", {id = id}).ref)))
                local ok, failure = pcall(function()
                    assert(viewport:resize(120, 40))
                    await(viewport, "SESSIONS")
                    key(viewport, "runes", "p")
                    await(viewport, "PROFILES", "Loading profiles")
                    key(viewport, "runes", "u")
                    await(viewport, "Claude")
                    key(viewport, "runes", "/")
                    await(viewport, "Search:")
                    key(viewport, "runes", "cod")
                    key(viewport, "runes", "ex")
                    test.contains(await(viewport, "Search: codex", "Claude", "Codex CLI"), "Codex CLI")
                    key(viewport, "runes", "é")
                    await(viewport, "Search: codexé", "Codex CLI")
                    key(viewport, "backspace")
                    test.contains(await(viewport, "Search: codex", "codexé", "Codex CLI"), "Codex CLI")
                    key(viewport, "esc")
                    key(viewport, "esc")
                    await(viewport, "SESSIONS")
                end)
                call("close", {id = id})
                viewport:close()
                call("leave", {})
                if not ok then error(tostring(failure)) end
            end)
        end)
    end)
end
return test.run_cases(define_tests)
