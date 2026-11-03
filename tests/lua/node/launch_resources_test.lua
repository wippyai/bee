-- MIT. An application receives its granted resource identities at launch.
local test = require("test")
local client = require("client")

local function options(resources: unknown): {[string]: unknown}
    return {version = 1, broker_pid = "{host|broker}", workspace_pid = "{host|workspace}",
        workspace_id = string.rep("a", 32), instance_id = "instance-1", view_id = "instance-1",
        definition_id = "app.notes:app", definition_revision = "1", execution_generation = 1,
        registry_revision = "7", launch_token = "token-1", arguments = {}, resources = resources}
end

local function define_tests()
    test.describe("launch resources", function()
        test.it("names each granted folder, database and executor", function()
            local launch = assert(client.launch(options({volumes = {docs = "bee.gov.grants:volume.a1"},
                databases = {notes = "bee.gov.grants:database.b2"},
                executors = {["/bin/echo hi"] = {lua = "bee.gov.grants:executor.c3"}}})))
            test.eq(launch.resources.volumes.docs, "bee.gov.grants:volume.a1")
            test.eq(launch.resources.databases.notes, "bee.gov.grants:database.b2")
            test.eq(launch.resources.executors["/bin/echo hi"].lua, "bee.gov.grants:executor.c3")
        end)
        test.it("holds no identities for an application without grants", function()
            local launch = assert(client.launch(options(nil)))
            test.is_nil(next(launch.resources.volumes))
            test.is_nil(next(launch.resources.databases))
            test.is_nil(next(launch.resources.executors))
        end)
        test.it("refuses malformed identities", function()
            test.is_nil(client.launch(options({volumes = {docs = 7}})))
            test.is_nil(client.launch(options({volumes = {[1] = "bee.gov.grants:volume.a1"}})))
            test.is_nil(client.launch(options({executors = {["/bin/echo"] = "bee.gov.grants:executor.c3"}})))
            test.is_nil(client.launch(options("bee.gov.grants:volume.a1")))
        end)
    end)
end
return test.run_cases(define_tests)
