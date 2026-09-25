-- MIT. Receipt decoding is the boundary between an authenticated Hive reply
-- and a local native mount capability.
local test = require("test")
local display = require("display")

local TARGET = {
    node_id = "node-1",
    owner_execution = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    workspace_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    desktop_id = "cccccccccccccccccccccccccccccccc",
    mode = "control",
}

local function receipt(extra: {[string]: unknown}?): {[string]: unknown}
    local value: {[string]: unknown} = {
        owner_execution = TARGET.owner_execution,
        workspace_id = TARGET.workspace_id,
        desktop_id = TARGET.desktop_id,
        session_id = "session-1",
        recipient = "{node-2@bee.hive.desktop:display_host|agent}",
        mode = "control",
        mount_ref = "mount-1",
        expires_at = "2026-09-21T00:00:00.000Z",
    }
    if extra then for name, item in pairs(extra) do value[name] = item end end
    return value
end

local function define_tests()
    test.describe("Hive foreground display", function()
        test.it("accepts only a receipt for its exact target, recipient and mode", function()
            local recipient = "{node-2@bee.hive.desktop:display_host|agent}"
            local target, target_error = display.target("node-1", TARGET.owner_execution, TARGET.workspace_id, TARGET.desktop_id, "control")
            if not target then error(tostring(target_error)) end
            local accepted = display.receipt(receipt(), target, recipient)
            test.not_nil(accepted)
            test.eq(accepted and accepted.session_id, "session-1")
            test.eq(accepted and accepted.mount_ref, "mount-1")
            test.is_nil(display.receipt(receipt({workspace_id = "dddddddddddddddddddddddddddddddd"}), target, recipient))
            test.is_nil(display.receipt(receipt({recipient = "{node-3@bee.hive.desktop:display_host|agent}"}), target, recipient))
            test.is_nil(display.receipt(receipt({mode = "observe"}), target, recipient))
            test.is_nil(display.receipt(receipt({mount_ref = "bad\nmount"}), target, recipient))
            test.is_nil(display.receipt(receipt({unexpected = true}), target, recipient))
        end)
        test.it("decodes command identities and mode without accepting paths or ambiguous modes", function()
            local target = display.target("node-1", TARGET.owner_execution, TARGET.workspace_id, TARGET.desktop_id, nil)
            test.not_nil(target)
            test.eq(target and target.mode, "control")
            test.is_nil(display.target("../node", TARGET.owner_execution, TARGET.workspace_id, TARGET.desktop_id, "control"))
            test.is_nil(display.target("node-1", "bad", TARGET.workspace_id, TARGET.desktop_id, "control"))
            test.is_nil(display.target("node-1", TARGET.owner_execution, TARGET.workspace_id, TARGET.desktop_id, "mirror"))
        end)
        test.it("accepts a reissued mount only for the same session and recipient", function()
            local recipient = "{node-2@bee.hive.desktop:display_host|agent}"
            local target = assert(display.target("node-1", TARGET.owner_execution, TARGET.workspace_id, TARGET.desktop_id, "control"))
            local previous = assert(display.receipt(receipt(), target, recipient))
            test.not_nil(display.reissued(receipt({mount_ref = "mount-2"}), previous, target, recipient))
            test.is_nil(display.reissued(receipt({mount_ref = "mount-1"}), previous, target, recipient))
            test.is_nil(display.reissued(receipt({session_id = "session-2", mount_ref = "mount-2"}), previous, target, recipient))
            test.is_nil(display.reissued(receipt({recipient = "other", mount_ref = "mount-2"}), previous, target, recipient))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
