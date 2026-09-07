local test = require("test")
local recovery = require("recovery")
local json = require("json")
local model = require("model")
local function define_tests()
    test.describe("Durable workspace boundary", function()
        test.it("rejects unsupported versions and malformed app checkpoints", function()
            test.is_nil(recovery.decode('{"version":2}'))
            test.is_nil(recovery.record({id = "v", instance_id = "i", definition_id = "x:a", resume_schema = "v1",
                restart_policy = "automatic", resume_state = "not json"}))
            test.is_nil(recovery.record({id = "v", instance_id = "i", definition_id = "x:a", resume_schema = "v1",
                restart_policy = "never", resume_state = "{}"}))
            test.is_nil(recovery.record({id = "v", instance_id = "i", definition_id = "x:a", resume_schema = "v1",
                restart_policy = "automatic", resume_state = string.rep("x", 65537)}))
        end)
        test.it("rejects duplicate persisted identities and mismatched windows", function()
            local record = {id = "v", instance_id = "i", definition_id = "x:a", resume_schema = "v1",
                restart_policy = "automatic", resume_state = '{"session":"uid"}'}
            local encoded = json.encode({version = 1, desktop = {scene = model.new(80, 24), tabs = {}}, applications = {record, record}})
            test.is_nil(recovery.decode(encoded))
            local scene = model.add(model.new(80, 24), "other", "i", "Other")
            test.is_nil(recovery.record({id = "v", instance_id = "i", definition_id = "x:a", resume_schema = "v1",
                restart_policy = "automatic", resume_state = "{}", window = scene.windows[1]}))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
