local test = require("test")
local contract = require("contract")
local decode = require("decode")
local client = require("client")
local arguments = require("arguments")
local function define_tests()
    test.describe("Application launch arguments", function()
        test.it("limits observer requests to exact bind targets", function()
            local value = {version = 1, request_id = "observe", op = "bind", id = "view", instance_id = "instance", observer = true}
            local request = contract.request(value)
            if not request then error("Observer bind rejected") end
            test.is_true(request.observer)
            value.instance_id = ""
            test.is_nil(contract.request(value))
            value.instance_id = "instance"; value.id = ""
            test.is_nil(contract.request(value))
            value.id = "view"; value.op = "close"
            test.is_nil(contract.request(value))
            value.observer = false
            test.is_nil(contract.request(value))
            test.is_nil(contract.request({version = 1, request_id = "r", op = "bind", id = "view", instance_id = "instance", observer = "true"}))
        end)

        test.it("preserves request workspace identity and rejects malformed routing values", function()
            local identity = "0123456789abcdef0123456789abcdef"
            local value = {version = 1, request_id = "route", op = "open", definition_id = "test:app", workspace_id = identity}
            local request = assert(contract.request(value))
            test.eq(request.workspace_id, identity)
            value.workspace_id = "ffffffffffffffffffffffffffffffff"
            test.eq(request.workspace_id, identity)
            for _, invalid in ipairs({"", "workspace", "0123456789ABCDEF0123456789ABCDEF", identity .. "0"}) do
                value.workspace_id = invalid
                test.is_nil(contract.request(value))
            end
        end)
        test.it("accepts only bounded explicit thread associations on open", function()
            local thread_id = "thread:review"
            local request = assert(contract.request({version = 1, request_id = "threaded", op = "open",
                definition_id = "test:app", thread_id = thread_id}))
            test.eq(request.thread_id, thread_id)
            test.is_nil(contract.request({version = 1, request_id = "threaded-close", op = "close", id = "view",
                instance_id = "instance", thread_id = thread_id}))
            test.is_nil(contract.request({version = 1, request_id = "threaded-empty", op = "open",
                definition_id = "test:app", thread_id = ""}))
            test.is_nil(contract.request({version = 1, request_id = "threaded-control", op = "open",
                definition_id = "test:app", thread_id = "review\n"}))
            test.is_nil(contract.request({version = 1, request_id = "threaded-large", op = "open",
                definition_id = "test:app", thread_id = string.rep("x", 161)}))
            local reply = contract.reply("threaded", "open")
            reply.thread_id = thread_id
            test.eq(assert(decode.reply(reply)).thread_id, thread_id)
        end)
        test.it("copies explicit arguments across both boundary decoders", function()
            local source = {"project-a", "run-a", ""}
            local request = assert(contract.request({version = 1, request_id = "r", op = "open",
                definition_id = "test:app", arguments = source}))
            local launch = assert(client.launch({version = 1, broker_pid = "broker", workspace_pid = "workspace", workspace_id = "0123456789abcdef0123456789abcdef",
                instance_id = "instance", view_id = "view", definition_id = "test:app", definition_revision = "1",
                registry_revision = "1", launch_token = "token", arguments = request.arguments}))
            source[1] = "changed"
            request.arguments[2] = "changed"
            test.eq(launch.arguments[1], "project-a")
            test.eq(launch.arguments[2], "run-a")
            test.eq(launch.arguments[3], "")
        end)
        test.it("requires canonical workspace identity and returns an independent view reference", function()
            local value = {version = 1, broker_pid = "broker", workspace_pid = "workspace",
                workspace_id = "0123456789abcdef0123456789abcdef", instance_id = "instance", view_id = "view",
                definition_id = "test:app", definition_revision = "1", registry_revision = "1", launch_token = "token"}
            local launch = client.launch(value)
            if not launch then error("Valid launch was rejected") end
            local reference = client.reference(launch)
            test.eq(reference.workspace_id, value.workspace_id)
            test.eq(reference.instance_id, "instance")
            test.eq(reference.view_id, "view")
            reference.workspace_id = "ffffffffffffffffffffffffffffffff"
            test.eq(launch.workspace_id, value.workspace_id)
            for _, invalid in ipairs({"", "workspace", "0123456789abcdef0123456789abcdefff0", "0123456789ABCDEF0123456789ABCDEF", "0123456789abcdef0123456789abcdef\n"}) do
                value.workspace_id = invalid
                test.is_nil(client.launch(value))
            end
            test.is_nil(client.launch({version = 1, broker_pid = "broker", workspace_pid = "workspace",
                instance_id = "instance", view_id = "view", definition_id = "test:app", definition_revision = "1",
                registry_revision = "1", launch_token = "token"}))
        end)
        test.it("authenticates cancellation results before resuming work", function()
            local launch = assert(client.launch({version = 1, broker_pid = "broker", workspace_pid = "workspace", workspace_id = "0123456789abcdef0123456789abcdef",
                instance_id = "instance", view_id = "view", definition_id = "test:app", definition_revision = "1",
                registry_revision = "1", launch_token = "token"}))
            local reply = {version = 1, id = "view", instance_id = "instance", request_id = "close", action = "cancel"}
            test.not_nil(client.close_result(launch, "broker", reply))
            test.is_nil(client.close_result(launch, "stranger", reply))
            reply.instance_id = "stale"
            test.is_nil(client.close_result(launch, "broker", reply))
            reply.instance_id = "instance"; reply.action = "accept"
            test.is_nil(client.close_result(launch, "broker", reply))
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
