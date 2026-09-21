-- MIT. The delivery boundary admits only an agent's own operations and bounds
-- every field; authority stays with the facade and the owner services.
local test = require("test")
local delivery = require("delivery_protocol")

local function define_tests()
    test.describe("Governance delivery protocol", function()
        test.it("decodes request, status and publish identities", function()
            local request = delivery.decode({operation = "request", workspace_id = "ws", source_overlay_id = "src",
                version = "1.0.1", snapshot_digest = string.rep("a", 64)})
            test.not_nil(request)
            test.eq(request and request.operation, "request")
            test.eq(request and request.source_workspace, "src")
            local status = delivery.decode({operation = "status", workspace_id = "ws", source_overlay_id = "src",
                version = "1.0.1", source_node = "node", intent_id = "intent-1"})
            test.not_nil(status)
            test.eq(status and status.intent_id, "intent-1")
            local publish = delivery.decode({operation = "publish", workspace_id = "ws", source_overlay_id = "src",
                version = "1.0.1"})
            test.not_nil(publish)
            test.eq(publish and publish.source_workspace, "src")
        end)
        test.it("refuses unknown operations and misplaced fields", function()
            test.is_nil(delivery.decode({operation = "apply", workspace_id = "ws", source_overlay_id = "src", version = "1"}))
            test.is_nil(delivery.decode({operation = "request", workspace_id = "ws", source_overlay_id = "src",
                version = "1", snapshot_digest = string.rep("a", 64), intent_id = "x"}))
            test.is_nil(delivery.decode({operation = "request", workspace_id = "ws", source_overlay_id = "src", version = "1"}))
            test.is_nil(delivery.decode({operation = "publish", workspace_id = "ws", source_overlay_id = "src",
                version = "1", snapshot_digest = string.rep("a", 64)}))
            test.is_nil(delivery.decode({operation = "status", workspace_id = "ws", source_overlay_id = "src",
                version = "1", overlay = "bee:x"}))
            test.is_nil(delivery.decode({operation = "status", workspace_id = "ws", source_overlay_id = "src"}))
            test.is_nil(delivery.decode({operation = "request", workspace_id = "ws", source_workspace = "src",
                version = "1", snapshot_digest = string.rep("a", 64)}))
        end)
    end)
end

return test.run_cases(define_tests)
