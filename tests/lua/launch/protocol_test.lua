-- MIT. Bootstrap identity and receipt validation precede local admission.
local test = require("test")
local protocol = require("protocol")
local workspace = "0123456789abcdef0123456789abcdef"
local function define_tests()
    test.describe("Local supervisor protocol", function()
        test.it("requires durable client receipt and exact workspace", function()
            local value = {version = 1, workspace_id = workspace, client_id = workspace, import_receipt = workspace}
            test.not_nil(protocol.ready(value, workspace, true))
            test.is_nil(protocol.ready(value, "ffffffffffffffffffffffffffffffff", true))
            value.import_receipt = ""
            test.is_nil(protocol.ready(value, workspace, true))
            test.not_nil(protocol.ready(value, workspace, false))
            value.import_receipt = string.rep("z", 32)
            test.is_nil(protocol.ready(value, workspace, true))
            test.is_nil(protocol.ready(value, workspace, false))
        end)
        test.it("requires durable identity even when no legacy import was offered", function()
            test.is_nil(protocol.ready({version = 1, workspace_id = workspace, client_id = "", import_receipt = ""}, workspace, false))
            test.is_nil(protocol.ready({version = 1, workspace_id = workspace, client_id = workspace}, workspace, false))
            test.is_nil(protocol.ready({version = 1, workspace_id = workspace, client_id = workspace, import_receipt = ""}, "ffffffffffffffffffffffffffffffff", false))
        end)
        test.it("rejects malformed boot state and unqualified control receipts", function()
            test.is_nil(protocol.host({version = 1, workspace_id = workspace, saved = {desktop = {}}}))
            test.is_nil(protocol.request({version = 1, request_id = "request"}, workspace))
            test.is_nil(protocol.request({version = 1, workspace_id = workspace, request_id = "bad\nrequest"}, workspace))
            test.eq(protocol.request({version = 1, workspace_id = workspace, request_id = "request"}, workspace), "request")
            test.is_nil(protocol.quit({version = 1, workspace_id = workspace, request_id = "request", emergency = "yes"}, workspace))
            test.is_false(assert(protocol.quit({version = 1, workspace_id = workspace, request_id = "request"}, workspace)).emergency)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
