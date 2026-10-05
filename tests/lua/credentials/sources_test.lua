-- MIT. The credential host admits an approved overlay driver's own login
-- beside the providers it serves itself, and only through its admission reader.
local test = require("test")
local registry = require("registry")
local bounds = require("bounds")
local sources = require("sources")

local SOURCES = "bee.credentials.env:credential_sources"

local function with_admission(reader: string?, run: () -> ())
    local original = assert(registry.get(SOURCES))
    local changed = assert(registry.get(SOURCES))
    local data = assert(bounds.object(changed.data))
    data.admission = reader
    local changes = assert(registry.snapshot()):changes()
    assert(changes:update(changed))
    assert(changes:apply())
    local ok, problem = pcall(run)
    local restore = assert(registry.snapshot()):changes()
    assert(restore:update(original))
    assert(restore:apply())
    if not ok then error(tostring(problem)) end
end

local function define_tests()
    test.describe("Approved driver logins", function()
        test.it("ships credential sources that read the logins governance approved", function()
            local data = assert(bounds.object(assert(registry.get(SOURCES)).data))
            test.eq(data.admission, "bee.gov.binding:driver_logins")
        end)

        test.it("adds an approved driver's format and machine login file source beside the host's own", function()
            with_admission("bee.credentials:approved_login_fixture", function()
                local admitted = assert(sources.host_sources())
                test.eq(admitted.formats.gem, "bee.driver.gem.credentials:credential_format")
                test.eq(admitted.formats.claude, "bee.driver.claude.credentials:credential_format")
                local found: {[string]: unknown}? = nil
                for _, source in ipairs(admitted.sources) do
                    if source.provider == "gem" then found = source end
                end
                local source = assert(found)
                test.eq(source.ref, "bee.env:machine_login_source")
                test.eq(source.path, ".gem/creds.json")
                test.eq(source.workspace_id, "*")
                test.eq(#assert(bounds.array(source.projection_kinds, 4)), 1)
            end)
        end)

        test.it("refuses an approved login that claims a provider the host serves", function()
            with_admission("bee.credentials:claiming_login_fixture", function()
                local admitted, problem = sources.host_sources()
                test.is_nil(admitted)
                test.not_nil(problem)
            end)
        end)
    end)
end

return test.run_cases(define_tests)
