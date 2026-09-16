-- MIT. Artifact tests cover exact full-definition measurements only; no
-- registry, filesystem, authority or overlay operation is involved.
local test = require("test")
local artifact = require("artifact")

local function entries(): {{[string]: unknown}}
    return {
        {id = "demo:service", kind = "process.service", meta = {title = "Demo"},
            data = {dependencies = {"demo:database"}, lifecycle = {auto_start = true}}},
        {id = "demo:database", kind = "db.sql.sqlite", data = {file = ".wippy/demo.db",
            lifecycle = {auto_start = true}, security = {scope = "demo"}}},
    }
end

local function define_tests()
    test.describe("Governance resolved registry artifact", function()
        test.it("requires native configuration data rather than YAML shorthand", function()
            local flat, flat_error = artifact.create({{id = "demo:run", kind = "function.lua", source = "return true"}})
            test.is_nil(flat)
            test.is_true(tostring(flat_error):find("configuration belongs in data", 1, true) ~= nil)
            test.is_nil(artifact.create({{id = "demo:run", kind = "function.lua"}}))
            test.is_nil(artifact.create({{id = "demo:run", kind = "function.lua", data = "not an object"}}))
            test.not_nil(artifact.create({{id = "demo:run", kind = "function.lua", data = {source = "return true"}}}))
        end)
        test.it("sorts IDs and preserves complete definitions in measured bytes", function()
            local input = entries()
            local reversed = {input[2], input[1]}
            local first = assert(artifact.create(input))
            local second = assert(artifact.create(reversed))
            test.eq(first.digest, second.digest)
            test.eq(first.entries[1].id, "demo:database")
            test.eq(first.entries[2].data.lifecycle.auto_start, true)
            test.eq(first.entries[1].data.security.scope, "demo")
            test.is_true(assert(artifact.verify(first)))
            local decoded = assert(artifact.decode(first.bytes, first.digest))
            test.eq(decoded[1].id, "demo:database")
            test.eq(decoded[2].data.dependencies[1], "demo:database")
            input[1].data.lifecycle.auto_start = false
            test.is_true(assert(artifact.verify(first)))
        end)
        test.it("rejects duplicate IDs, malformed IDs or kinds, and unsupported values", function()
            local duplicate = entries()
            duplicate[2].id = duplicate[1].id
            test.is_nil(artifact.create(duplicate))
            local malformed = entries()
            malformed[1].id = "demo service"
            test.is_nil(artifact.create(malformed))
            malformed = entries()
            malformed[1].kind = ""
            test.is_nil(artifact.create(malformed))
            malformed = entries()
            malformed[1].data = {callback = function() end}
            test.is_nil(artifact.create(malformed))
        end)
        test.it("verifies exact bytes and digest, including tampering and limits", function()
            local made = assert(artifact.create(entries()))
            test.is_true(assert(artifact.verify_bytes(made.entries, made.bytes, made.digest)))
            test.is_false(artifact.verify_bytes(made.entries, made.bytes .. " ", made.digest))
            test.is_false(artifact.verify_bytes(made.entries, made.bytes, string.rep("a", 64)))
            local padded = made.bytes .. " "
            test.is_nil(artifact.decode(padded, assert(artifact.digest(padded))))
            test.is_nil(artifact.decode(made.bytes, string.rep("b", 64)))
            local extra = '{"entries":[],"extra":true,"schema_revision":"' .. artifact.SCHEMA .. '"}'
            test.is_nil(artifact.decode(extra, assert(artifact.digest(extra))))
            made.entries[2].data.lifecycle.auto_start = false
            test.is_false(artifact.verify(made))
            test.is_nil(artifact.create({}))
            local too_many: {{{[string]: unknown}}} = {}
            for index = 1, artifact.MAX_ENTRIES + 1 do
                too_many[index] = {id = "demo:item" .. tostring(index), kind = "library.lua", data = {}}
            end
            test.is_nil(artifact.create(too_many))
        end)
        test.it("measures a definition near the 256 KiB artifact limit", function()
            local made = assert(artifact.create({{id = "demo:large", kind = "function.lua",
                data = {source = string.rep("x", artifact.MAX_BYTES - 1024)}}}))
            test.is_true(#made.bytes > 128 * 1024)
            test.is_true(#made.bytes <= artifact.MAX_BYTES)
            test.is_true(assert(artifact.verify(made)))
        end)
    end)
end

return test.run_cases(define_tests)
