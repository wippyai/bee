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

local function sdk(): {{[string]: unknown}}
    return {
        {id = "private.sdk:app", kind = "process.lua", meta = {type = "bee.app",
            application = {title = "Project SDK", revision = "1", menus = {"bee.shell:apps_menu"}}},
            data = {source = "return {main = function() end}", method = "main"}},
        {id = "unrelated.tools:execute", kind = "function.lua", meta = {application_ref = "private.sdk:app",
            hive = "policy", hive_service = "test-sdk", hive_operation = {name = "run", revision = "1",
                input = {type = "object", properties = {configuration = {type = "string"}}, required = {"configuration"}},
                output = {type = "object"}}},
            data = {source = "return {run = function() return {} end}", method = "run"}},
    }
end

local function define_tests()
    test.describe("Governance resolved registry artifact", function()
        test.it("keeps authored Hive names and explicit application associations across namespaces", function()
            local made = assert(artifact.create(sdk()))
            local decoded = assert(artifact.decode(made.bytes, made.digest))
            local operation = decoded[2].meta
            test.eq(operation.hive_service, "test-sdk")
            test.eq(operation.hive_operation.name, "run")
            test.eq(operation.application_ref, "private.sdk:app")
        end)
        test.it("refuses partial, malformed or unnamed Hive declarations", function()
            local invalid: {unknown} = {false, "run", {}, {name = "run", revision = "1", input = false, output = {}},
                {name = "run", revision = "1", input = {}, output = "object"},
                {name = "run", revision = "", input = {}, output = {}},
                {name = "run\n", revision = "1", input = {}, output = {}},
                {revision = "1", input = {}, output = {}}}
            for _, value in ipairs(invalid) do
                local input = sdk()
                input[2].meta.hive_operation = value
                local made, err = artifact.create(input)
                test.is_nil(made)
                test.contains(tostring(err), "Hive")
            end
            for _, field in ipairs({"hive", "hive_service", "hive_operation"}) do
                local input = sdk()
                input[2].meta[field] = nil
                test.is_nil(artifact.create(input))
            end
            local input = sdk()
            input[2].meta.hive = "public"
            test.is_nil(artifact.create(input))
            input = sdk()
            input[2].kind = "library.lua"
            test.is_nil(artifact.create(input))
        end)
        test.it("refuses duplicate authored operations within one application's service", function()
            local input = sdk()
            local duplicate = sdk()[2]
            duplicate.id = "third.namespace:other"
            input[#input + 1] = duplicate
            local made, err = artifact.create(input)
            test.is_nil(made)
            test.contains(tostring(err), "duplicate Hive operation")
        end)
        test.it("refuses malformed schema definitions before measuring a Hive operation", function()
            for _, schema in ipairs({{type = "unsupported"}, {properties = {configuration = {type = 7}}}}) do
                local input = sdk()
                input[2].meta.hive_operation.input = schema
                local made, err = artifact.create(input)
                test.is_nil(made)
                test.contains(tostring(err), "valid input/output schemas")
            end
        end)
        test.it("requires the explicit Hive application association to name an app in the measured artifact", function()
            for _, target in ipairs({"absent:app", "unrelated.tools:execute", ""}) do
                local input = sdk()
                input[2].meta.application_ref = target
                local made, err = artifact.create(input)
                test.is_nil(made)
                test.contains(tostring(err), "Hive application")
            end
            local input = sdk()
            input[2].meta.application_ref = nil
            test.is_nil(artifact.create(input))
        end)
        test.it("measures the desktop checkpoint metadata invariant", function()
            local function invalid(restart: unknown, schema: unknown): boolean
                return artifact.application_checkpoint_invalid({meta = {type = "bee.app",
                    application = {restart_policy = restart, resume_schema = schema}}})
            end
            test.is_false(invalid(nil, nil))
            test.is_false(invalid("never", nil))
            test.is_false(invalid("automatic", "demo.v1"))
            test.is_false(invalid("manual", "demo.v1"))
            test.is_true(invalid("automatic", nil))
            test.is_true(invalid("manual", ""))
            test.is_true(invalid("invalid", "demo.v1"))
            test.is_true(invalid("automatic", 1))
            test.is_true(invalid("automatic", string.rep("s", 81)))
            test.is_true(invalid("automatic", "schema\n"))
            test.is_false(artifact.application_checkpoint_invalid({meta = {type = "other"}}))
        end)
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
