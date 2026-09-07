local test = require("test")
local contract = require("contract")
local client = require("client")
local arguments = require("arguments")
local function define_tests()
    test.describe("Application launch arguments", function()
        test.it("copies explicit arguments across both boundary decoders", function()
            local source = {"project-a", "run-a", ""}
            local request = assert(contract.request({version = 1, request_id = "r", op = "open",
                definition_id = "test:app", arguments = source}))
            local launch = assert(client.launch({version = 1, broker_pid = "broker", workspace_pid = "workspace",
                instance_id = "instance", view_id = "view", definition_id = "test:app", definition_revision = "1",
                registry_revision = "1", launch_token = "token", arguments = request.arguments}))
            source[1] = "changed"
            request.arguments[2] = "changed"
            test.eq(launch.arguments[1], "project-a")
            test.eq(launch.arguments[2], "run-a")
            test.eq(launch.arguments[3], "")
        end)
        test.it("rejects sparse, oversized and control-bearing payloads", function()
            test.is_nil(arguments.decode({[2] = "hole"}))
            test.is_nil(arguments.decode({project = "named"}))
            test.is_nil(arguments.decode({false}))
            test.is_nil(arguments.decode({"line\nbreak"}))
            test.is_nil(arguments.decode({string.rep("x", 1025)}))
            local many: {string} = {}
            for i = 1, 17 do many[i] = "" end
            test.is_nil(arguments.decode(many))
            local large: {string} = {}
            for i = 1, 9 do large[i] = string.rep("x", 1024) end
            test.is_nil(arguments.decode(large))
            test.is_nil(contract.request({version = 1, request_id = "r", op = "close", id = "view", arguments = {"unexpected"}}))
        end)
        test.it("keeps distinct argument lists distinct for retry identity", function()
            test.is_true(arguments.fingerprint({"ab", "c"}) ~= arguments.fingerprint({"a", "bc"}))
            test.is_true(arguments.fingerprint({""}) ~= arguments.fingerprint({}))
            local request = assert(contract.request({version = 1, request_id = "r", op = "open", definition_id = "test:app"}))
            test.eq(#request.arguments, 0)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
