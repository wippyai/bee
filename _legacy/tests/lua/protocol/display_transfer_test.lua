local test = require("test")
local transfer = require("transfer")

local display = "0123456789abcdef0123456789abcdef"
local target = "fedcba9876543210fedcba9876543210"

local function item(targets: {string}): {[string]: unknown}
    return {tab_id = "tab", instance_id = "instance", assignment_revision = 3, targets = targets}
end

local function define_tests()
    test.describe("Presenter display-transfer protocol", function()
        test.it("decodes bounded snapshots and canonical display IDs", function()
            local value = {version = 1, revision = 4, items = {item({target})}}
            local snapshot = transfer.snapshot(value)
            test.not_nil(snapshot)
            if snapshot then
                test.eq(snapshot.revision, 4)
                test.eq(snapshot.items[1].targets[1], target)
            end
            local uppercase = {version = 1, revision = 4, items = {item({string.upper(target)})}}
            test.is_nil(transfer.snapshot(uppercase))
            local duplicate = {version = 1, revision = 4, items = {item({target, target})}}
            test.is_nil(transfer.snapshot(duplicate))
        end)

        test.it("rejects sparse, oversized and unknown snapshot fields", function()
            local sparse = {version = 1, revision = 1, items = { [2] = item({target}) }}
            test.is_nil(transfer.snapshot(sparse))
            local oversized = {version = 1, revision = 1, items = {}}
            for index = 1, 17 do oversized.items[index] = item({target}) end
            test.is_nil(transfer.snapshot(oversized))
            local extra = {version = 1, revision = 1, items = {item({target})}, extra = true}
            test.is_nil(transfer.snapshot(extra))
        end)

        test.it("strictly decodes actions and enforces result consistency", function()
            local action = {version = 1, op = "transfer", request_id = "request", id = "tab",
                instance_id = "instance", target_display_id = target, expected_revision = 3}
            test.not_nil(transfer.action(action))
            action.source_display_id = display
            test.is_nil(transfer.action(action))
            local result = {version = 1, request_id = "request", id = "tab", instance_id = "instance",
                target_display_id = target, error_code = "", error = ""}
            test.not_nil(transfer.result(result))
            result.error = "should be empty on success"
            test.is_nil(transfer.result(result))
            result.error_code, result.error = "stale", "assignment changed"
            test.not_nil(transfer.result(result))
            result.error = "bad\nmessage"
            test.is_nil(transfer.result(result))
        end)
    end)
end

return {run = test.run_cases(define_tests)}
