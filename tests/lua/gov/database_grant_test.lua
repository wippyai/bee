-- MIT. An approved app.database request installs a database the host
-- places under its application database root.
local registry = require("registry")
local test = require("test")
local bounds = require("bounds")
local grants = require("capability_grants")
local model = require("capability_model")

local APP = "app.dbgrant:app"
local OWNER = "bee.gov.apps:" .. string.rep("a", 32) .. ".dbgrant"

local function define_tests()
    test.describe("approved application database", function()
        test.it("installs where the host keeps application databases", function()
            local vocabulary = assert(model.decode(assert(registry.get("bee.capability:catalog"))))
            local proposal = assert(grants.propose(vocabulary, OWNER, APP, {
                {id = "app.dbgrant:notes", expected_kind = "security.policy", targets = {APP},
                    capability_request = {capability = "app.database", parameters = {name = "notes"},
                        template_revision = 1, catalog_revision = model.revisions(vocabulary, "app.database"),
                        reason = "keep notes", target = APP, path = ".security.policies +="}}}))
            local database = assert(bounds.object(proposal.databases[1]))
            local id = assert(bounds.id(database.id))
            local changes = assert(registry.snapshot()):changes()
            changes:create({id = id, kind = "db.sql.sqlite", meta = bounds.object(database.meta) or {}, data = database.data})
            local applied, apply_error = changes:apply()
            local installed = registry.get(id)
            if applied then
                local cleanup = assert(registry.snapshot()):changes()
                cleanup:delete(id)
                assert(cleanup:apply())
            end
            test.is_nil(apply_error, tostring(apply_error))
            test.not_nil(installed)
        end)
    end)
end
return test.run_cases(define_tests)
