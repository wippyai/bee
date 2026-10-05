local test = require("test")
local principal = require("principal")

local function define_tests()
    test.describe("Application principals", function()
        test.it("derives a stable actor ID and bounded launch metadata", function()
            local workspace = "0123456789abcdef0123456789abcdef"
            local first = assert(principal.value(workspace, "instance-1", "bee.example:app", "revision-1", 1))
            local replacement = assert(principal.value(workspace, "instance-1", "bee.example:app", "revision-2", 2))
            test.eq(first.id, "bee.application:" .. workspace .. ":instance-1")
            test.eq(replacement.id, first.id)
            test.eq(first.metadata.workspace_id, workspace)
            test.eq(first.metadata.definition_id, "bee.example:app")
            test.eq(replacement.metadata.definition_revision, "revision-2")
            test.eq(replacement.metadata.execution_generation, 2)
        end)
        test.it("refuses unbounded or malformed host values", function()
            local workspace = "0123456789abcdef0123456789abcdef"
            test.is_nil(principal.value("workspace", "instance", "bee.example:app", "1", 1))
            test.is_nil(principal.value(workspace, "", "bee.example:app", "1", 1))
            test.is_nil(principal.value(workspace, "instance", "bee.example:app", "\n", 1))
            test.is_nil(principal.value(workspace, "instance", "bee.example:app", "1", 0))
            test.is_nil(principal.value(workspace, "instance", "bee.example:app", "1", 1.5))
        end)
    end)
end

return require("test").run_cases(define_tests)
