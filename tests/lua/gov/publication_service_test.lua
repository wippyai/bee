-- MIT. Publication prepares exactly the frozen artifact the author measured.
local test = require("test")
local bounds = require("bounds")
local service = require("publication_service")
local artifact = require("artifact")
local base64 = require("base64")
local funcs = require("funcs")
local security = require("security")
local app_scope = require("app_scope")

local function define_tests()
    test.describe("application publication artifacts", function()
        test.it("prepares through the owning facade while the application cannot open governance storage", function()
            local workspace = string.rep("e", 32)
            local actor = security.new_actor("bee.application:" .. workspace .. ":publication-test",
                {workspace_id = workspace})
            local scope = app_scope.boundary({"bee.tests.gov:publication_test_policy"})
            -- Nothing an application holds opens the node database.
            test.neq(scope:evaluate(actor, "db.get", "bee:db"), "allow")
            local caller = funcs.new():with_actor(actor):with_scope(scope)
            local raw, err = caller:call("bee.gov.binding:publication_call", {operation = "prepare",
                workspace_id = workspace, component = "app.publication_scope_test", version = "1.0.0",
                snapshot_digest = string.rep("f", 64)})
            test.is_nil(err)
            local result = assert(bounds.object(raw))
            test.eq(result.code, "BLOCKED")
            local other = assert(bounds.object(caller:call("bee.gov.binding:publication_call", {operation = "prepare",
                workspace_id = string.rep("d", 32), component = "app.publication_scope_test", version = "1.0.0",
                snapshot_digest = string.rep("f", 64)})))
            test.eq(other.code, "DENIED")
            local direct = assert(bounds.object(caller:call("bee.gov.binding:publication_backend_call", {operation = "prepare",
                workspace_id = workspace, component = "app.publication_scope_test", version = "1.0.0",
                snapshot_digest = string.rep("f", 64)})))
            test.eq(direct.code, "DENIED")
            local publish = assert(bounds.object(caller:call("bee.gov.binding:publication_call", {operation = "publish",
                workspace_id = workspace, component = "app.publication_scope_test", version = "1.0.0"})))
            test.eq(publish.code, "DENIED")
        end)

        test.it("builds an exact artifact from declarative frozen entries", function()
            local entries = "[{\"data\":{\"source\":\"return 'private'\"},\"kind\":\"function.lua\",\"id\":\"demo:main\"}]"
            local exact = assert(artifact.create({{id = "demo:main", kind = "function.lua", data = {source = "return 'private'"}}}))
            local encoded = assert(base64.encode(entries))
            local prepared, err = service.snapshot_artifact({ok = true, value = {
                path = "entries.json", content_base64 = encoded}})
            test.is_nil(err)
            test.eq((assert(bounds.object(prepared))).digest, exact.digest)
            test.is_nil(service.snapshot_artifact({ok = true, value = {
                path = "other.json", content_base64 = encoded}}))
            test.is_nil(service.snapshot_artifact({ok = true, value = {
                path = "entries.json", content_base64 = assert(base64.encode("{}"))}}))
        end)
        test.it("names a refusal and remedy when a frozen overlay cannot become an application", function()
            -- No entries.json at all: only other files were frozen.
            local missing, missing_error, missing_code = service.snapshot_artifact({ok = true, value = {
                path = "entries.json", content_base64 = nil}})
            test.is_nil(missing)
            test.eq(missing_code, "MISSING_ARTIFACT")
            test.not_nil((string.find(missing_error, "no entries.json", 1, true)))
            -- A present entries.json that is not a JSON list of complete entries.
            local broken, broken_error, broken_code = service.snapshot_artifact({ok = true, value = {
                path = "entries.json", content_base64 = assert(base64.encode("[{\"id\":\"demo:x\"}]"))}})
            test.is_nil(broken)
            test.eq(broken_code, "INVALID_ARTIFACT")
            test.not_nil((string.find(broken_error, "data", 1, true)))
            -- A usable list measures with no refusal.
            local good, good_error, good_code = service.snapshot_artifact({ok = true, value = {
                path = "entries.json", content_base64 = assert(base64.encode(
                    "[{\"id\":\"demo:main\",\"kind\":\"process.lua\",\"data\":{\"source\":\"return true\"}}]"))}})
            test.is_nil(good_error)
            test.is_nil(good_code)
            test.eq((assert(bounds.object(good))).digest and #((assert(bounds.object(good))).digest), 64)
        end)
        test.it("carries the remedy in the failure value under the destination's own field name", function()
            local reply = service.artifact_refusal("MISSING_ARTIFACT")
            test.is_false(reply.ok)
            test.eq(reply.code, "MISSING_ARTIFACT")
            local value = assert(bounds.object(reply.value))
            test.not_nil(value.remedy)
            test.not_nil((string.find(value.remedy, "entries.json", 1, true)))
        end)
    end)
end

return test.run_cases(define_tests)
