-- MIT. The node's application library gives the owner and the test runner one
-- definition, admission, actor and scope for an app.
local test = require("test")
local application = require("application")
local catalog = require("catalog")

local WORKSPACE = string.rep("e", 32)
local APPLICATION = "bee.tests.node.runner.fixture:app"

local function define_tests()
    test.describe("node application library", function()
        test.it("reads the definition an app entry declares", function()
            local definition = assert(application.definition(APPLICATION))
            test.eq(definition.process, APPLICATION)
            test.eq(definition.title, "Runner fixture")
            test.eq(definition.revision, "1")
            local missing, reason = application.definition("bee.tests.node.runner.fixture:authority_test")
            test.is_nil(missing)
            test.not_nil(reason)
        end)

        test.it("finds the host admission of an app and none for another", function()
            local binding, record, admission_error = application.admission(APPLICATION, WORKSPACE)
            test.is_nil(admission_error)
            test.is_nil(record)
            test.eq(assert(binding).policies[1], "bee.tests.node.runner.fixture:grant")
            local none, _, none_error = application.admission("bee.tests.node.runner.fixture:unadmitted", WORKSPACE)
            test.is_nil(none)
            test.is_nil(none_error)
        end)

        test.it("rejects a valid process definition without host admission", function()
            local definition = assert(application.definition(APPLICATION))
            definition.process = "unadmitted.vendor:app"
            local scope, err = application.scope(definition, WORKSPACE)
            test.is_nil(scope)
            test.not_nil(err)
        end)

        test.it("lists only applications admitted in the launch workspace", function()
            local apps = assert(catalog.catalog(WORKSPACE))
            local found = false
            for _, app in ipairs(apps) do
                test.neq(app.id, "bee.tests.node:tools_app")
                if app.id == APPLICATION then found = true end
            end
            test.is_true(found)
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
