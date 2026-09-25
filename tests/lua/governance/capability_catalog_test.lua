-- MIT. Host vocabulary is decoded before it can describe an app request.
local test = require("test")
local catalog = require("capability_catalog")
local registry = require("registry")

local function fixture(): {[string]: unknown}
    return {id = "bee:capability_catalog", kind = "registry.entry",
        meta = {type = "bee.capability_catalog"}, data = {revision = 1,
            never = {"exec", "credentials"}, capabilities = {
                {id = "workspace.files.read", revision = 1, confirm = "standard",
                    parameters = {subpath = "relative_subpath"},
                    text = "Read workspace files under {subpath}",
                    policies = {{operation = "files.read", resource = "workspace", scope = {subpath = "$subpath"}}},
                    resources = {{kind = "fs.directory", mode = "readonly"}}},
                {id = "http.api", revision = 1, confirm = "explicit",
                    parameters = {origin = "https_origin", methods = "http_methods", path_prefix = "url_path_prefix"},
                    text = "Send HTTP requests to {origin} at {path_prefix} using {methods}",
                    policies = {{operation = "http.request", resource = "$origin",
                        scope = {methods = "$methods", path_prefix = "$path_prefix"}}}, resources = {}}
            }}}
end

local function define_tests()
    test.describe("Capability catalog", function()
        test.it("decodes the shipped host-owned catalog with all initial rows", function()
            local shipped = assert(registry.get("bee:capability_catalog"))
            local decoded = assert(catalog.decode(shipped))
            local count = 0
            for _ in pairs(decoded.capabilities) do count = count + 1 end
            test.eq(count, 9)
            test.is_true(decoded.never.credentials)
            test.eq(decoded.capabilities["hive.expose"].confirm, "explicit")
            test.eq(decoded.capabilities["workspace.files.write"].confirm, "explicit")
            local database = assert(catalog.resolve(decoded, "app.database", {name = "journal"}))
            local api = assert(catalog.resolve(decoded, "http.api", {
                origin = "https://api.example.com", methods = {"POST"}, path_prefix = "/upload"}))
            local lines = assert(catalog.render(decoded, {database[1], api[1]}))
            test.is_true(table.concat(lines, "\n"):find(
                "Application database journal may be sent to https://api.example.com", 1, true) ~= nil)
        end)
        test.it("decodes host templates and normalizes bounded request parameters", function()
            local decoded = assert(catalog.decode(fixture()))
            local normalized = assert(catalog.normalize(decoded, "workspace.files.read", {subpath = "docs/api"}))
            test.eq(normalized.subpath, "docs/api")
            local grants = assert(catalog.resolve(decoded, "workspace.files.read", normalized))
            test.eq(grants[1].operation, "files.read")
            test.eq(grants[1].scope.subpath, "docs/api")
            test.eq(grants[1].template_revision, 1)
            test.is_nil(catalog.normalize(decoded, "workspace.files.read", {subpath = "docs/../private"}))
            test.is_nil(catalog.normalize(decoded, "workspace.files.read", {subpath = "/absolute"}))
            test.is_nil(catalog.normalize(decoded, "workspace.files.read", {subpath = "docs", extra = true}))
            test.is_nil(catalog.normalize(decoded, "http.api", {origin = "http://example.com", methods = {"GET"}, path_prefix = "/"}))
            test.is_nil(catalog.normalize(decoded, "http.api", {origin = "https://example.com", methods = {"GET", "GET"}, path_prefix = "/"}))
            local http = assert(catalog.normalize(decoded, "http.api", {
                origin = "https://API.Example.COM:443", methods = {"POST", "GET"}, path_prefix = "/v1/"}))
            test.eq(http.origin, "https://api.example.com")
            test.eq(http.path_prefix, "/v1")
            test.eq((http.methods :: {string})[1], "GET")
        end)
        test.it("rejects altered catalog shape and never-listed capability", function()
            local raw = fixture()
            local data = raw.data :: {[string]: unknown}
            local rows = data.capabilities :: {{[string]: unknown}}
            rows[1].id = "exec"
            test.is_nil(catalog.decode(raw))
            rows[1].id = "workspace.files.read"
            rows[1].confirm = "silent"
            test.is_nil(catalog.decode(raw))
        end)
        test.it("renders host wording and combined read to egress flow", function()
            local decoded = assert(catalog.decode(fixture()))
            local read = assert(catalog.resolve(decoded, "workspace.files.read", {subpath = "docs"}))
            local send = assert(catalog.resolve(decoded, "http.api", {
                origin = "https://api.example.com", methods = {"POST"}, path_prefix = "/upload"}))
            local lines = assert(catalog.render(decoded, {read[1], send[1]}))
            local all = table.concat(lines, "\n")
            test.is_true(all:find("Read workspace files under docs", 1, true) ~= nil)
            test.is_true(all:find("https://api.example.com", 1, true) ~= nil)
            test.is_true(all:find("Workspace files under docs may be sent to https://api.example.com", 1, true) ~= nil)
            test.is_nil(all:find("app reason", 1, true))
            send[1].scope.path_prefix = "/private"
            test.is_nil(catalog.render(decoded, {read[1], send[1]}))
        end)
    end)
end
return test.run_cases(define_tests)
