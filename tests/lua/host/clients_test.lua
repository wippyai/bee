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
        test.it("requires an explicit workspace appearance grant alongside appearance writes", function()
            local base = {version = 1, request_id = "r", workspace_id = identity, op = "admit", recipient = "client",
                permissions = {open = true, close = true, control = true, appearance = false, workspace_appearance = true}}
            test.is_nil(clients.control(base))
            base.permissions.appearance = true
            local selected = clients.control(base)
            if not selected or not selected.permissions then error("Missing appearance admission") end
            test.is_true(selected.permissions.workspace_appearance)
            test.is_false(clients.same_permissions(selected.permissions,
                {open = true, close = true, control = true, appearance = true, workspace_appearance = false}))
            local ordinary = clients.control({version = 1, request_id = "r", workspace_id = identity,
                op = "admit", recipient = "client", permissions = {open = true, close = true, control = true, appearance = true}})
            if not ordinary or not ordinary.permissions then error("Missing ordinary admission") end
            test.is_false(ordinary.permissions.workspace_appearance)
        end)
        test.it("denies foreign control, host recovery and lifecycle authority", function()
            local client: clients.Client = {recipient = "client", connection_id = "connection",
                permissions = {open = true, close = false, control = true}, detaching = false,
                renderer = "client", renderer_generation = "generation", rendering = false}
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
            request.recipient = ""; client.renderer = "selected-renderer"
            test.eq(clients.allowed(client, request), true)
            request.recipient = "selected-renderer"
            test.eq(clients.allowed(client, request), false)
            request.recipient = ""; client.rendering = true
            test.eq(clients.allowed(client, request), false)
            request.op = "open"
            test.eq(clients.allowed(client, request), true)
            request.op = "bind"; client.rendering = false; client.renderer = ""
            test.eq(clients.allowed(client, request), false)
            request.op = "close"
            test.eq(clients.allowed(client, request), false)
            client.permissions.close = true
            request.instance_id = ""
            test.eq(clients.allowed(client, request), false)
            request.instance_id = "instance"
            test.eq(clients.allowed(client, request), true)
            request.op = "shutdown"
            test.eq(clients.allowed(client, request), false)
            request.op = "unbind"
            test.eq(clients.allowed(client, request), false)
        end)
        test.it("requires an explicit bounded renderer selection", function()
            local value = {version = 1, request_id = "render", workspace_id = identity, op = "render", recipient = "client", renderer = "renderer"}
            local selected = assert(clients.control(value))
            test.eq(selected.renderer, "renderer")
            test.is_nil(selected.permissions)
            value.renderer = ""
            test.not_nil(clients.control(value))
            value.renderer = string.rep("x", 161)
            test.is_nil(clients.control(value))
            value.renderer = "renderer\n"
            test.is_nil(clients.control(value))
            test.is_nil(clients.control({version = 1, request_id = "r", workspace_id = identity, op = "render", recipient = "client"}))
        end)
        test.it("requires a qualified bounded inventory alongside private operation results", function()
            local reply = contract.reply("open", "open", "", "")
            reply.workspace_id = identity
            local value = {version = 1, reply = reply, views = {version = 1, workspace_id = identity,
                connection_id = "connection", revision = 3, items = {}}}
            local result = assert(clients.result(value))
            test.eq(result.views.connection_id, "connection")
            test.eq(result.views.revision, 3)
            value.views.revision = 4
            test.eq(result.views.revision, 3)
            value.views.revision = -1
            test.is_nil(clients.result(value))
            value.views.revision = 3
            value.views.workspace_id = "ffffffffffffffffffffffffffffffff"
            test.is_nil(clients.result(value))
            test.is_nil(clients.result(reply))
        end)
        test.it("keeps appearance authority explicit and validates scoped receipts", function()
            local value = {version = 1, request_id = "admit", workspace_id = identity,
                op = "admit", recipient = "client", permissions = {open = true, close = true, control = true}}
            local admitted = clients.control(value)
            if not admitted or not admitted.permissions then error("Missing admission") end
            test.is_false(admitted.permissions.appearance == true)
            local receipt = {version = 1, request_id = "appearance", action = "set", workspace_id = identity,
                connection_id = "connection", renderer = "renderer", renderer_generation = "generation",
                revision = 2, theme = "honey", background = "dots", taskbar = "labels",
                error_code = "", error = ""}
            test.not_nil(clients.appearance_result(receipt))
            receipt.revision = -1
            test.is_nil(clients.appearance_result(receipt))
            receipt.revision = 2
            receipt.renderer_generation = ""
            test.is_nil(clients.appearance_result(receipt))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
