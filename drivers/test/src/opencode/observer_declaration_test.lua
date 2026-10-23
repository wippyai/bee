-- SPDX-License-Identifier: MIT
local test = require("test")
local security = require("security")
local observer_protocol = require("observer_protocol")
local function define_tests()
    test.describe("window observer declaration", function()
        test.it("admits observer HTTP requests only to the declared loopback host", function()
            local policy = assert(security.policy("bee.drivers.opencode.observer:http_policy"))
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
    end)
end
return test.run_cases(define_tests)
