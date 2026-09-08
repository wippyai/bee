-- MIT. Admission metadata cannot enlarge supervisor-selected authority.
local test = require("test")
local clients = require("clients")
local contract = require("contract")
local identity = "0123456789abcdef0123456789abcdef"
local function define_tests()
    test.describe("Workspace client admission", function()
        test.it("requires explicit bounded authority and copies permissions", function()
            local permissions = {open = true, close = false, control = true}
            local value = {version = 1, request_id = "admit", workspace_id = identity,
                op = "admit", recipient = "client", permissions = permissions}
            local admitted = assert(clients.control(value))
            permissions.open = false
            test.eq(assert(admitted.permissions).open, true)
            value.recipient = string.rep("x", 161)
            test.is_nil(clients.control(value))
            test.is_nil(clients.control({version = 1, request_id = "r", workspace_id = identity,
                op = "admit", recipient = "client", permissions = {open = true, control = true}}))
            test.is_nil(clients.control({version = 1, request_id = "r", workspace_id = identity,
                op = "admit", recipient = "client", permissions = {open = "true", close = false, control = true}}))
            test.is_nil(clients.control({version = 1, request_id = "r", workspace_id = identity,
                op = "shutdown", recipient = "client"}))
        end)
        test.it("denies foreign control, host recovery and lifecycle authority", function()
            local client: clients.Client = {recipient = "client", connection_id = "connection",
                permissions = {open = true, close = false, control = true}, detaching = false}
            local request = assert(contract.request({version = 1, request_id = "r", op = "open", definition_id = "test:app"}))
            test.eq(clients.allowed(client, request), true)
            request.resume_state = "{}"
            test.eq(clients.allowed(client, request), false)
            request.resume_state = ""
            request.restore_view_id = "old"
            test.eq(clients.allowed(client, request), false)
            request.restore_view_id = ""
            request.op = "bind"; request.id = "view"; request.instance_id = "instance"
            test.eq(clients.allowed(client, request), true)
            request.recipient = "foreign"
            test.eq(clients.allowed(client, request), false)
            request.recipient = "client"; request.instance_id = ""
            test.eq(clients.allowed(client, request), false)
            request.instance_id = "instance"; client.detaching = true
            test.eq(clients.allowed(client, request), false)
            client.detaching = false
            request.op = "close"
            test.eq(clients.allowed(client, request), false)
            request.op = "shutdown"
            test.eq(clients.allowed(client, request), false)
            request.op = "unbind"
            test.eq(clients.allowed(client, request), false)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
