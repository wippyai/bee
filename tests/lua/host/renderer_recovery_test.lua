-- SPDX-License-Identifier: MIT
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local connections = require("connections")
local contract = require("contract")
local inventory = require("inventory")
local questions = require("questions")
local identity = "0123456789abcdef0123456789abcdef"
local display = "fedcba9876543210fedcba9876543210"
local function spawn_idle(monitored: boolean): string
    if monitored then return tostring(assert(process.spawn_monitored("bee.host:idle_process", "bee:workers"))) end
    return tostring(assert(process.spawn("bee.host:idle_process", "bee:workers")))
end
type Message = {[string]: any}
local function receive(inbox: any): Message
    local deadline = time.after("5s")
    local selected = channel.select({inbox:case_receive(), deadline:case_receive()})
    assert(selected.channel == inbox, "expected host message")
    return selected.value:payload():data() :: Message
end
local function define_tests()
    test.describe("Host renderer recovery", function()
        test.it("delivers an unexpected application exit to its assigned display", function()
            local self = tostring(process.pid())
            local replies = assert(process.listen("bee.host.reply", {message = true}))
            local assignments = connections.assignment_access(
                function(_: unknown) return {assignment = {view_id = "view", instance_id = "instance", display_id = display, revision = 1}}, nil end,
                function() return {}, nil end,
                function(_: unknown) error("failure notification must not claim an assignment") end)
            local host = connections.new(self, self, identity, assignments)
            host.admitted[self] = {recipient = self, connection_id = "connection",
                permissions = {open = true, close = true, control = true, appearance = true}, detaching = false,
                renderer = self, renderer_generation = "generation", rendering = false, display_id = display}
            local failed = contract.reply("", "closed", "application_failed", "Auto Research failed: view error")
            failed.workspace_id, failed.id, failed.instance_id = identity, "view", "instance"
            test.is_true(connections.failure(host, failed))
            local delivered = receive(replies)
            test.eq(delivered.reply.error_code, "application_failed")
            test.eq(delivered.reply.error, "Auto Research failed: view error")
            process.unlisten(replies)
        end)
        test.it("delivers the current inventory to admitted clients when the host resumes serving", function()
            local self = tostring(process.pid())
            local catalogs = assert(process.listen("bee.host.catalog", {message = true}))
            local views = assert(process.listen("bee.host.views", {message = true}))
            local assignments = connections.assignment_access(
                function(_: unknown) return nil, nil end,
                function() return {}, nil end,
                function(_: unknown) return nil, nil end)
            local host = connections.new(self, self, identity, assignments)
            host.admitted[self] = {recipient = self, connection_id = "connection",
                permissions = {open = true, close = true, control = true, appearance = true}, detaching = false,
                renderer = self, renderer_generation = "generation", rendering = false, display_id = display}
            local current = assert(inventory.set_catalog(inventory.new(identity), {}))
            connections.publish_all(host, current)
            local catalog = receive(catalogs)
            test.eq(catalog.connection_id, "connection")
            test.eq(catalog.revision, current.catalog_revision)
            local live = receive(views)
            test.eq(live.connection_id, "connection")
            test.eq(live.revision, current.views_revision)
            process.unlisten(catalogs)
            process.unlisten(views)
        end)
        test.it("publishes the checkpointed inventory when client connections resume", function()
            local self = tostring(process.pid())
            local catalogs = assert(process.listen("bee.host.catalog", {message = true}))
            local views = assert(process.listen("bee.host.views", {message = true}))
            local assignments = connections.assignment_access(
                function(_: unknown) return nil, nil end,
                function() return {}, nil end,
                function(_: unknown) return nil, nil end)
            local host = connections.new(self, self, identity, assignments)
            host.admitted[self] = {recipient = self, connection_id = "restored-connection",
                permissions = {open = true, close = true, control = true, appearance = true}, detaching = false,
                renderer = self, renderer_generation = "generation", rendering = false, display_id = display}
            local opened = contract.reply("restored-open", "open")
            opened.workspace_id, opened.id, opened.instance_id = identity, "restored-view", "restored-instance"
            opened.definition_id, opened.thread_id, opened.title = "test:app", "thread:restored", "Restored"
            local current = assert(inventory.observe(inventory.new(identity), opened))
            connections.resume(host, host.admitted, 1, 3, current, questions.new(identity))

            local catalog = receive(catalogs)
            local live = receive(views)
            test.eq(catalog.connection_id, "restored-connection")
            test.eq(catalog.revision, current.catalog_revision)
            test.eq(live.connection_id, "restored-connection")
            test.eq(live.revision, current.views_revision)
            test.eq(live.items[1].view_id, "restored-view")
            process.unlisten(catalogs)
            process.unlisten(views)
        end)
        test.it("admits a replacement renderer while the crashed renderer's grants are still being released", function()
            local events = assert(process.events())
            local requests = assert(process.listen("bee.app.request", {message = true}))
            local results = assert(process.listen("bee.host.client_result", {message = true}))
            local self = tostring(process.pid())
            -- The host itself monitors renderers, so only the crashed one is watched up front.
            local client, crashed, replacement = spawn_idle(false), spawn_idle(true), spawn_idle(false)
            local assignments = connections.assignment_access(
                function(_: unknown): (nil, string) error("renderer recovery read assignments") end,
                function(): ({}, nil) return {}, nil end,
                function(_: unknown): (nil, string) error("renderer recovery claimed assignments") end
            )
            local host = connections.new(self, self, identity, assignments)
            host.admitted[client] = {recipient = client, connection_id = "connection",
                permissions = {open = true, close = true, control = true, appearance = true}, detaching = false,
                renderer = crashed, renderer_generation = "generation", rendering = false, display_id = display}
            host.count = 1
            process.terminate(crashed)
            repeat
                local event = events:receive()
            until event.kind == process.event.EXIT and tostring(event.from) == crashed

            -- The host observes the crash first and starts releasing that renderer's grants.
            connections.exited(host, crashed)
            local release = receive(requests)
            test.eq(release.op, "unbind")
            test.eq(release.recipient, crashed)

            -- The client's replacement renderer arrives before the broker confirms the release.
            test.is_nil(connections.control(host, self, {version = 1, workspace_id = identity, request_id = "replace",
                op = "render", recipient = client, renderer = replacement}, true))
            local deadline = time.after("200ms")
            local early = channel.select({results:case_receive(), requests:case_receive(), deadline:case_receive()})
            if early.channel ~= deadline then
                local answered = early.value:payload():data() :: Message
                error("replacement was answered before the release completed: " .. tostring(answered.error_code) .. " " .. tostring(answered.error))
            end

            test.is_true(connections.reply(host, contract.reply(release.request_id, "unbind"), host.inventory))
            local answered = receive(results)
            test.eq(answered.request_id, "replace")
            test.eq(answered.op, "render")
            test.eq(answered.error_code, "")
            local admitted = host.admitted[client]
            test.eq(admitted.renderer, replacement)
            test.is_false(admitted.rendering)
            test.eq(next(host.changes), nil)

            for _, pid in ipairs({client, replacement}) do process.cancel(pid, "renderer recovery test complete") end
            process.unlisten(requests)
            process.unlisten(results)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
