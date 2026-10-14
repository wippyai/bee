-- MIT. Public package reads must never select host paths or caller authority.
local test = require("test")
local preview = require("preview")

local function define_tests()
    test.describe("Hub package preview boundary", function()
        test.it("reads exact state without requiring installation parameters", function()
            local request, problem = preview.decode("state", {component = "userspace/docker", version = "0.5.12"})
            test.is_nil(problem)
            test.not_nil(request)
            if request then
                test.eq(request.component, "userspace/docker")
                test.eq(request.version, "0.5.12")
                test.is_nil(request.resource)
            end
            test.is_nil(preview.decode("state", {component = "userspace/docker", version = "^0.5"}))
        end)
        test.it("accepts package resource paths and separate directory and byte cursors", function()
            local listing, problem = preview.decode("files", {component = "bee/example", version = "1.0.0", resource = "example:assets"})
            test.is_nil(problem)
            test.not_nil(listing)
            if listing then test.eq(listing.path, "."); test.eq(listing.offset, 0); test.eq(listing.limit, 100) end
            local file = preview.decode("read_file", {component = "bee/example", version = "1.0.0",
                resource = "example:assets", path = "images/logo.png", offset = 64, limit = 1024,
                expected_digest = string.rep("a", 64)})
            test.not_nil(file)
            if file then test.eq(file.path, "images/logo.png"); test.eq(file.offset, 64); test.eq(file.limit, 1024) end
        end)
        test.it("rejects host paths and traversal before opening an artifact", function()
            for _, path in ipairs({"/etc/passwd", "../secret", "assets/../secret", "assets/./secret", "assets//secret", "assets\\secret", "bad\npath"}) do
                test.is_nil(preview.decode("read_file", {component = "bee/example", version = "1.0.0", resource = "example:assets", path = path}))
            end
            test.is_nil(preview.decode("files", {component = "bee/example", version = "1.0.0"}))
        end)
        test.it("rejects invalid cursors, digests and caller-selected authority", function()
            for _, offset in ipairs({-1, 1.5, "0"}) do
                test.is_nil(preview.decode("files", {component = "bee/example", version = "1.0.0", resource = "example:assets", offset = offset}))
            end
            for _, limit in ipairs({0, -1, 1.5, 1001}) do
                test.is_nil(preview.decode("files", {component = "bee/example", version = "1.0.0", resource = "example:assets", limit = limit}))
            end
            test.is_nil(preview.decode("read_file", {component = "bee/example", version = "1.0.0", resource = "example:assets", limit = 1048577}))
            for _, digest in ipairs({"", string.rep("g", 64), string.rep("a", 63)}) do
                test.is_nil(preview.decode("state", {component = "bee/example", version = "1.0.0", expected_digest = digest}))
            end
            for _, key in ipairs({"actor", "scope", "token", "url", "registry", "parameters", "path"}) do
                local raw: {[string]: unknown} = {component = "bee/example", version = "1.0.0"}
                raw[key] = "caller-selected"
                test.is_nil(preview.decode("state", raw))
            end
        end)
    end)
end
return test.run_cases(define_tests)
