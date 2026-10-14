-- SPDX-License-Identifier: MIT
local test = require("test")
local security = require("security")
local observer = require("observer")
local observer_protocol = require("observer_protocol")
local function define_tests()
    test.describe("window observer supervision", function()
        test.it("admits observer HTTP requests only to the declared loopback host", function()
            local policy = assert(security.policy("bee.driver.opencode.observer:http_policy"))
            local actor = assert(security.actor())
            test.eq(policy:evaluate(actor, "http_client.request", "http://127.0.0.1:4096/event"), "allow")
            test.eq(policy:evaluate(actor, "http_client.request", "http://127.0.0.1:4096/session"), "allow")
            test.eq(policy:evaluate(actor, "http_client.private_ip", "127.0.0.1"), "allow")
            test.is_false(policy:evaluate(actor, "http_client.request", "http://127.0.0.2:4096/event") == "allow")
            test.is_false(policy:evaluate(actor, "http_client.request", "https://example.com/event") == "allow")
        end)
        test.it("pins observer declaration and process data in the profile digest", function()
            local profiles = {driver = {profiles = {{id = "window", observer = "local_http"}}}}
            local measured = {window = {declaration = {data = {process = "fixture:subscriber"}}, process = {data = {source = "first"}}}}
            local first = assert(observer_protocol.digest(profiles, measured))
            measured.window.process.data.source = "changed"
            test.is_false(first == assert(observer_protocol.digest(profiles, measured)))
            measured.window.declaration.data.process = "fixture:other"
            test.is_false(first == assert(observer_protocol.digest(profiles, measured)))
        end)
        test.it("records nonfatal hook failures while waiting for subscription readiness", function()
            local queue = {{kind = "delivery_failed", detail = "hook endpoint refused delivery"}, {kind = "ready", arguments = {"attach", "http://127.0.0.1:1234"}}}
            local evidence: {string} = {}
            local args = assert(observer.readiness(function(): {[string]: unknown}? return table.remove(queue, 1) end,
                function(kind: string, _: string) evidence[#evidence + 1] = kind end))
            test.eq(args[1], "attach")
            test.eq(evidence[1], "observer.delivery_failed")
        end)
        test.it("subscribes before releasing the first prompt and stops once with the window", function()
            local order: {string} = {}
            local handle = assert(observer.lifecycle({
                server = function(_: {string}): (string?, (() -> ())?) order[#order + 1] = "server"; return "http://127.0.0.1:1234", function() order[#order + 1] = "server stopped" end end,
                spawn = function(_: string): boolean order[#order + 1] = "observer"; return true end,
                ready = function(): {string}? order[#order + 1] = "subscription"; return {"attach", "http://127.0.0.1:1234"} end,
                release = function() order[#order + 1] = "prompt" end,
                stop = function() order[#order + 1] = "observer stopped" end,
                record = function(_: string, _: string) end,
            }, {process = "fixture", server_arguments = {}, endpoint_pattern = "fixture"}))
            test.eq(table.concat(order, ","), "server,observer,subscription")
            handle.release()
            handle.stop()
            handle.stop()
            test.eq(table.concat(order, ","), "server,observer,subscription,prompt,observer stopped,server stopped")
        end)
        test.it("contains a thrown observer startup error", function()
            local recorded: {string} = {}
            local handle = observer.lifecycle({server = function(_: {string}): (string?, (() -> ())?) error("fixture server failure") end,
                spawn = function(_: string): boolean return true end,
                ready = function(): {string}? return {} end,
                release = function() end, stop = function() end,
                record = function(kind: string, _: string) recorded[#recorded + 1] = kind end},
                {process = "fixture", server_arguments = {}, endpoint_pattern = "fixture"})
            test.is_nil(handle)
            test.eq(recorded[1], "observer.failed")
        end)
        test.it("records observer shutdown failure and still closes the server", function()
            local facts = {closed = false, failed = false}
            local handle = assert(observer.lifecycle({server = function(_: {string}): (string?, (() -> ())?)
                return "http://127.0.0.1:1234", function() facts.closed = true end
            end, spawn = function(_: string): boolean return true end, ready = function(): {string}? return {"attach"} end,
                release = function() end, stop = function() error("fixture shutdown error") end,
                record = function(kind: string, _: string) if kind == "observer.stop_failed" then facts.failed = true end end},
                {process = "fixture", server_arguments = {}, endpoint_pattern = "fixture"}))
            local stopped_ok = pcall(handle.stop)
            test.is_true(stopped_ok)
            test.is_true(facts.closed)
            test.is_true(facts.failed)
        end)
        test.it("records setup failures and leaves the original CLI launch available", function()
            for _, failure in ipairs({"server", "spawn", "readiness"}) do
                local closed = false
                local stopped = false
                local evidence: {string} = {}
                local handle = observer.lifecycle({
                    server = function(_: {string}): (string?, (() -> ())?)
                        if failure == "server" then return nil, nil end
                        return "http://127.0.0.1:1234", function() closed = true end
                    end,
                    spawn = function(_: string): boolean return failure ~= "spawn" end,
                    ready = function(): {string}? if failure == "readiness" then return nil end; return {"attach"} end,
                    release = function() error("failed observer cannot release a prompt") end,
                    stop = function() stopped = true end,
                    record = function(kind: string, _: string) evidence[#evidence + 1] = kind end,
                }, {process = "fixture", server_arguments = {}, endpoint_pattern = "fixture"})
                test.is_nil(handle)
                test.eq(evidence[1], "observer.failed")
                test.eq(closed, failure ~= "server")
                test.eq(stopped, failure == "readiness")
            end
        end)
    end)
end
return test.run_cases(define_tests)
