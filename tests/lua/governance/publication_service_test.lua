-- MIT. Publication prepares exactly the frozen artifact the author measured.
local test = require("test")
local service = require("publication_service")
local artifact = require("artifact")
local base64 = require("base64")

local function define_tests()
    test.describe("application publication artifacts", function()
        test.it("builds an exact artifact from declarative frozen entries", function()
            local entries = "[{\"data\":{\"source\":\"return 'private'\"},\"kind\":\"function.lua\",\"id\":\"demo:main\"}]"
            local exact = assert(artifact.create({{id = "demo:main", kind = "function.lua", data = {source = "return 'private'"}}}))
            local encoded = assert(base64.encode(entries))
            local prepared, err = service.snapshot_artifact({ok = true, value = {
                path = "entries.json", content_base64 = encoded}})
            test.is_nil(err)
            test.eq((prepared :: {[string]: unknown}).digest, exact.digest)
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
            test.not_nil(string.find(missing_error :: string, "no entries.json", 1, true))
            -- A present entries.json that is not a JSON list of complete entries.
            local broken, broken_error, broken_code = service.snapshot_artifact({ok = true, value = {
                path = "entries.json", content_base64 = assert(base64.encode("[{\"id\":\"demo:x\"}]"))}})
            test.is_nil(broken)
            test.eq(broken_code, "INVALID_ARTIFACT")
            test.not_nil(string.find(broken_error :: string, "data", 1, true))
            -- A usable list measures with no refusal.
            local good, good_error, good_code = service.snapshot_artifact({ok = true, value = {
                path = "entries.json", content_base64 = assert(base64.encode(
                    "[{\"id\":\"demo:main\",\"kind\":\"process.lua\",\"data\":{\"source\":\"return true\"}}]"))}})
            test.is_nil(good_error)
            test.is_nil(good_code)
            test.eq((good :: {[string]: unknown}).digest and #((good :: {[string]: unknown}).digest :: string), 64)
        end)
        test.it("carries the remedy in the failure value under the destination's own field name", function()
            local reply = service.artifact_refusal("MISSING_ARTIFACT")
            test.is_false(reply.ok)
            test.eq(reply.code, "MISSING_ARTIFACT")
            local value = reply.value :: {[string]: unknown}
            test.not_nil(value.remedy)
            test.not_nil(string.find(value.remedy :: string, "entries.json", 1, true))
        end)
    end)
end

return test.run_cases(define_tests)
