-- SPDX-License-Identifier: MIT
local test = require("test")
local registry = require("registry")
local funcs = require("funcs")
local configuration = require("configuration")
type Object = {[string]: unknown}
local function run()
    test.describe("Native gateway address", function()
        test.it("validates canonical host-selected loopback and private IPv4 ports", function()
            for _, address in ipairs({"127.0.0.1:0", "127.0.0.1:1", "127.0.0.1:65535", "127.0.0.2:0", "172.17.0.1:0", "10.0.0.1:80", "192.168.1.2:65535"}) do
                test.is_true(configuration.valid_address(address, true))
            end
            for _, address in ipairs({"127.0.0.1:0", "127.0.0.1:65536", "127.0.0.1:01", "localhost:80", "0.0.0.0:80", "127.0.0.1:80/path", "172.15.0.1:80", "172.32.0.1:80", "8.8.8.8:80", "172.17.256.1:80", "172.017.0.1:80", "169.254.169.254:80", "224.0.0.1:80"}) do
                test.is_true(not configuration.valid_address(address, false))
            end
        end)
        test.it("requires the selected interface and exact port in Host", function()
            test.is_true(configuration.host_matches("172.17.0.1:43210", "172.17.0.1:43210"))
            test.is_true(configuration.host_matches("localhost:43210", "127.0.0.1:43210"))
            for _, host in ipairs({"172.17.0.1:43211", "172.17.0.2:43210", "localhost:43210", "172.17.0.1:043210", "172.17.0.1:43210.evil", "172.17.0.1:43210@evil"}) do
                test.is_true(not configuration.host_matches(host, "172.17.0.1:43210"))
            end
            test.is_true(not configuration.host_matches("localhost:43211", "127.0.0.1:43210"))
        end)
        test.it("reads the actual selected native listener without accepting a caller address", function()
            local endpoint = registry.get("bee:gateway_endpoint")
            local reference = registry.get("bee.gateway:listener_ref")
            if not endpoint or not reference then error("missing gateway host configuration") end
            local changed_endpoint: Object = {id = endpoint.id, kind = endpoint.kind, meta = endpoint.meta, data = {address = "127.0.0.1:0"}}
            local changed_reference: Object = {id = reference.id, kind = reference.kind, meta = reference.meta,
                data = {resource_ref = "bee.gateway:ephemeral_listener"}}
            local function update(left: Object, right: Object)
                local changes = registry.snapshot():changes()
                changes:update(left); changes:update(right)
                local applied, err = changes:apply()
                if not applied then error(tostring(err)) end
            end
            local ok, failure = pcall(function()
                update(changed_endpoint, changed_reference)
                local address, err = configuration.endpoint()
                if not address then error(tostring(err)) end
                test.is_true(configuration.valid_address(address, false))
                test.neq(address, "127.0.0.1:0")
                local replay = configuration.endpoint()
                test.eq(replay, address)
                local supplied, supplied_error = funcs.call("bee.gateway:address", {address = "127.0.0.1:1"})
                test.is_true(supplied == nil)
                test.is_true(supplied_error ~= nil)
                -- A real listener on another loopback interface exercises
                -- interface selection without depending on Docker on the test host.
                changed_endpoint.data = {address = "127.0.0.2:0"}
                update(changed_endpoint, changed_reference)
                local mismatched = configuration.endpoint()
                test.is_true(mismatched == nil)
                changed_reference.data = {resource_ref = "bee.gateway:alternate_listener"}
                update(changed_endpoint, changed_reference)
                local alternate, alternate_error = configuration.endpoint()
                if not alternate then error(tostring(alternate_error)) end
                test.is_true(alternate:match("^127%.0%.0%.2:%d+$") ~= nil)
                test.neq(alternate, "127.0.0.2:0")
                changed_reference.data = {resource_ref = "bee.gateway:absent_listener"}
                update(changed_endpoint, changed_reference)
                local missing = configuration.endpoint()
                test.is_true(missing == nil)
            end)
            update(endpoint, reference)
            if not ok then error(tostring(failure)) end
        end)
    end)
end
return test.run_cases(run)
