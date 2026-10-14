-- MIT. The node's application library gives the owner and the test runner one
-- definition, admission, actor and scope for an app.
local test = require("test")
local application = require("application")

local WORKSPACE = string.rep("e", 32)
local APPLICATION = "app.runner_fixture:app"

local function define_tests()
    test.describe("node application library", function()
        test.it("reads the definition an app entry declares", function()
            local definition = assert(application.definition(APPLICATION))
            test.eq(definition.process, APPLICATION)
            test.eq(definition.title, "Runner fixture")
            test.eq(definition.revision, "1")
            local missing, reason = application.definition("app.runner_fixture:authority_test")
            test.is_nil(missing)
            test.not_nil(reason)
        end)

        test.it("finds the host admission of an app and none for another", function()
            local binding, record, admission_error = application.admission(APPLICATION, WORKSPACE)
            test.is_nil(admission_error)
            test.is_nil(record)
            test.eq(assert(binding).policies[1], "app.runner_fixture:grant")
            local none, _, none_error = application.admission("app.runner_fixture:unadmitted", WORKSPACE)
            test.is_nil(none)
            test.is_nil(none_error)
        end)

        test.it("names an instance actor by workspace and definition", function()
            local definition = assert(application.definition(APPLICATION))
            local actor = assert(application.actor(WORKSPACE, "instance-1", definition, 1))
            test.eq(actor:id(), "bee.application:" .. WORKSPACE .. ":instance-1")
            local meta = actor:meta() :: {[string]: unknown}
            test.eq(meta.workspace_id, WORKSPACE)
            test.eq(meta.definition_id, APPLICATION)
            test.eq(meta.definition_revision, "1")
            test.eq(meta.execution_generation, 1)
        end)

        test.it("builds the scope of the application boundary plus its admitted policies", function()
            local definition = assert(application.definition(APPLICATION))
            local actor = assert(application.actor(WORKSPACE, "instance-1", definition, 1))
            local scope = assert(application.scope(definition, WORKSPACE))
            test.eq(scope:evaluate(actor, "fixture.probe", "granted"), "allow")
            test.eq(scope:evaluate(actor, "process.send", "anything"), "allow")
            test.neq(scope:evaluate(actor, "db.get", "bee:db"), "allow")
            test.neq(scope:evaluate(actor, "registry.apply", "registry"), "allow")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
