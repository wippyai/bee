-- SPDX-License-Identifier: MIT
local test = require("test")
local configuration = require("configuration")
local configuration_types = require("configuration_types")
local hash = require("hash")

local function gateway(count: integer): configuration_types.GatewayInput
    local tools: {string} = {}
    for index = 1, count do tools[index] = "tool_" .. tostring(index) end
    return {endpoint = "127.0.0.1:4100", action_id = "action", tools = tools, hooks = {}, token_environment = "BEE_GATEWAY_TOKEN"}
end

local function define_tests()
    test.describe("Gateway configuration bounds", function()
        test.it("admits product bundles and the complete 128-tool surface in order", function()
            for _, count in ipairs({32, 33, 38, 64, 65, 128}) do
                local selected = gateway(count)
                local decoded, err = configuration.decode_request({fixture = false, gateway = selected})
                if not decoded then error(tostring(err)) end
                local actual = assert(decoded.gateway)
                test.eq(#actual.tools, count)
                test.eq(table.concat(actual.tools, ","), table.concat(selected.tools, ","))
            end
        end)
        test.it("rejects 129 tools and malformed identifier lists", function()
            local rejected, err = configuration.decode_request({fixture = false, gateway = gateway(129)})
            test.is_nil(rejected)
            test.eq(err, "configuration request.gateway.tools exceeds 128 tools or is invalid")
            for _, tools in ipairs({{"a", "a"}, {""}, {"a\nb"}, {string.rep("x", 161)}, {[1] = "a", [3] = "b"}, {name = "a"}}) do
                local selected = gateway(1)
                selected.tools = tools
                test.is_nil(configuration.decode_request({fixture = false, gateway = selected}))
            end
            local selected = gateway(1)
            selected.tools = {string.rep("x", 160)}
            test.not_nil(configuration.decode_request({fixture = false, gateway = selected}))
        end)
        test.it("keeps the independent 32-hook bound", function()
            local selected = gateway(128)
            selected.hook_token_environment = "BEE_GATEWAY_HOOK_TOKEN"
            for index = 1, 32 do selected.hooks[index] = "event_" .. tostring(index) end
            test.not_nil(configuration.decode_request({fixture = false, gateway = selected}))
            selected.hooks[33] = "event_33"
            local rejected, err = configuration.decode_request({fixture = false, gateway = selected})
            test.is_nil(rejected)
            test.eq(err, "configuration request.gateway.hooks exceeds 32 items")
        end)
        test.it("keeps generated file and aggregate delivery byte bounds", function()
            local function file(path: string, bytes: integer): configuration_types.Configuration
                local content = string.rep("x", bytes)
                return {revision = "fixture@1", path = path, content = content, digest = assert(hash.sha256(content)), provider_ref = configuration.GATEWAY_PROVIDER_REF}
            end
            test.not_nil(configuration.decode_file(file("one", 8192)))
            test.is_nil(configuration.decode_file(file("one", 8193)))
            local files = {file("one", 8192), file("two", 8192), file("three", 8192)}
            test.not_nil(configuration.decode_delivery({arguments = {}, files = files}))
            files[4] = file("four", 1)
            test.is_nil(configuration.decode_delivery({arguments = {}, files = files}))
            test.not_nil(configuration.decode_delivery({arguments = {string.rep("x", 16384)}, files = {}}))
            test.is_nil(configuration.decode_delivery({arguments = {string.rep("x", 16384), "x"}, files = {}}))
        end)
    end)
end

return test.run_cases(define_tests)
