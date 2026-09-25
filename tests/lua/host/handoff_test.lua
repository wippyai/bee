-- MIT. A host checkpoint carries descriptive state and exact owner identity.
local test = require("test")
local handoff = require("handoff")
local inventory = require("inventory")
local questions = require("questions")
local workspace = "0123456789abcdef0123456789abcdef"
local owner = "owner-pid"
local function define_tests()
    test.describe("Workspace host handoff", function()
        test.it("accepts a versioned checkpoint for the same owner and workspace", function()
            local saved = handoff.pack(owner, workspace, "broker-pid", inventory.new(workspace), {}, 0, 3, questions.new(workspace))
            local resumed = assert(handoff.decode(saved, owner, workspace))
            test.eq(resumed.broker, "broker-pid")
            test.eq(resumed.assignment_revision, 3)
            test.eq(resumed.questions.workspace_id, workspace)
            test.is_nil(handoff.decode(saved, "another-owner", workspace))
            test.is_nil(handoff.decode(saved, owner, "ffffffffffffffffffffffffffffffff"))
        end)
        test.it("rejects unknown fields, invalid inventory and malformed admissions", function()
            local saved = handoff.pack(owner, workspace, "broker-pid", inventory.new(workspace), {}, 0, 0, questions.new(workspace))
            local raw = saved :: {[string]: unknown}
            raw.version = 2
            test.is_nil(handoff.decode(raw, owner, workspace))
            raw.version = 1
            raw.unexpected = true
            test.is_nil(handoff.decode(raw, owner, workspace))
            raw.unexpected = nil
            raw.views = {{workspace_id = workspace, view_id = "", instance_id = "bad", definition_id = "app", title = "bad"}}
            test.is_nil(handoff.decode(raw, owner, workspace))
            raw.views = {}
            raw.admitted = {other = {recipient = "other"}}
            raw.count = 1
            test.is_nil(handoff.decode(raw, owner, workspace))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
