-- MIT. Requests cannot turn a package reader into a credential destination.
local test = require("test")
local inspect = require("inspect")
local inspection = require("inspection")
local inventory = require("inventory")
local installed = require("installed")
local function define_tests()
    test.describe("Hub inspection request", function()
        test.it("pages only source owned by the exact installed component and revision", function()
            local state = {resolution = {modules = {{name = "bee/application", version = "0.1.0-dev", source = "local"}}}, entries = {
                {id = "bee.application:frame", kind = "library.lua", registry = {owner = "bee/application"}, data = {source = "frame source"}},
                {id = "bee.private:policy", kind = "library.lua", registry = {owner = "bee/private"}, data = {source = "private source"}},
                {id = "bee.application:config", kind = "registry.entry", registry = {owner = "bee/application"}, data = {secret = "private"}},
            }}
            local listed = assert(inventory.sources(state, 7, {component = "bee/application", version = "0.1.0-dev"}))
            test.eq(#listed.entries, 1)
            test.eq(listed.entries[1].id, "bee.application:frame")
            local page = assert(inventory.sources(state, 7, {component = "bee/application", version = "0.1.0-dev",
                entry_id = "bee.application:frame", expected_revision = 7, offset = 6, limit = 6}))
            test.eq(page.content, "source")
            test.is_true(page.eof)
            test.is_nil(inventory.sources(state, 7, {component = "bee/application", version = "0.1.0-dev",
                entry_id = "bee.private:policy", expected_revision = 7}))
            test.is_nil(inventory.sources(state, 8, {component = "bee/application", version = "0.1.0-dev",
                entry_id = "bee.application:frame", expected_revision = 7}))
        end)
        test.it("reads the frame implementation from the installed development component", function()
            local current = assert(installed.read())
            local version: string? = nil
            for _, item in ipairs(current.modules) do
                if item.component == "bee/application" then version = item.version end
            end
            test.not_nil(version)
            if not version then return end
            local manifest = assert(installed.sources({component = "bee/application", version = version}))
            local revision = manifest.revision :: number
            local entries = manifest.entries :: {{id: string}}
            local found = false
            for _, entry in ipairs(entries) do
                if entry.id == "bee.application:frame" then found = true end
            end
            test.is_true(found)
            local page = assert(installed.sources({component = "bee/application", version = version,
                entry_id = "bee.application:frame", expected_revision = revision, offset = 0, limit = 4096}))
            test.is_true((page.content :: string):find("function M.", 1, true) ~= nil)
        end)
        test.it("requires an exact version and refuses alternate authority inputs", function()
            for _, version in ipairs({"latest", "*", "^1.2.3", ">=1.2.3", "1.2", "1.2.3 || 2.0.0"}) do
                local request = inspection.decode({component = "acme/tool", version = version})
                test.is_nil(request)
            end
            for _, field in ipairs({"registry", "token", "actor", "scope", "path", "approval"}) do
                local raw: {[string]: unknown} = {component = "acme/tool", version = "1.2.3"}
                raw[field] = "caller-selected"
                test.is_nil(inspection.decode(raw))
            end
        end)
        test.it("retains the exact selected version and qualified bindings", function()
            local request, problem = inspection.decode({component = "acme/tool", version = "v1.2.3-beta.1+build.4",
                parameters = {{name = "acme.tool:database", value = "app:database"}}})
            test.is_nil(problem)
            test.not_nil(request)
            if not request then return end
            test.eq(request.version, "v1.2.3-beta.1+build.4")
            test.eq(request.parameters[1].value, "app:database")
        end)
        test.it("refuses malformed parameter values before opening a package", function()
            local result, problem = inspect.read({component = "acme/tool", version = "1.2.3", parameters = false})
            test.is_nil(result)
            test.not_nil(problem)
            test.is_nil(inspection.decode({component = "acme/tool", version = "1.2.3",
                parameters = {{name = "acme.tool:db", value = "app:a"}, {name = "acme.tool:db", value = "app:b"}}}))
            test.is_nil(inspection.decode({component = "https://example.com/tool", version = "1.2.3"}))
        end)
    end)
end
return test.run_cases(define_tests)
