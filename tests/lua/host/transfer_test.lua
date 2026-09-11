-- MIT. Display-transfer values carry a requested target, never source authority.
local test = require("test")
local transfer = require("transfer")
local workspace = "0123456789abcdef0123456789abcdef"
local target = "1123456789abcdef0123456789abcdef"
local function request(): {[string]: unknown}
    return {version = 1, workspace_id = workspace, connection_id = "connection",
        renderer_generation = "generation", request_id = "request", view_id = "view",
        instance_id = "instance", target_display_id = target, expected_revision = 1}
end
local function define_tests()
    test.describe("Display transfer boundary", function()
        test.it("copies stable identities without accepting source authority", function()
            local input = request()
            local checked = transfer.request(input)
            if not checked then error("valid transfer request rejected") end
            input.target_display_id = workspace
            test.eq(checked.target_display_id, target)
            test.eq(checked.expected_revision, 1)
            for _, field in ipairs({"source_display_id", "recipient", "renderer", "mount", "permissions", "observer"}) do
                local forged = request()
                forged[field] = "authority"
                test.is_nil(transfer.request(forged))
            end
        end)
        test.it("requires exact app and current client identities", function()
            for _, field in ipairs({"workspace_id", "connection_id", "renderer_generation", "request_id", "view_id", "instance_id", "target_display_id"}) do
                local empty = request()
                empty[field] = ""
                test.is_nil(transfer.request(empty))
                empty[field] = string.rep("x", 161)
                test.is_nil(transfer.request(empty))
            end
        end)
        test.it("rejects invalid or exhausted assignment revisions", function()
            for _, value in ipairs({-1, 0, 1.5, 9007199254740990, math.huge}) do
                local invalid = request()
                invalid.expected_revision = value
                test.is_nil(transfer.request(invalid))
            end
            local invalid = request()
            invalid.expected_revision = "1"
            test.is_nil(transfer.request(invalid))
            invalid = request()
            invalid.version = 2
            test.is_nil(transfer.request(invalid))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
