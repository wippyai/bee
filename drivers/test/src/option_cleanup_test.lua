-- SPDX-License-Identifier: MIT
local test = require("test")
local descriptors = require("descriptors")
local bounds = require("bounds")
local canonical = require("canonical")
local universal = require("universal")
local json = require("json")
type Object = {[string]: unknown}
local function object(value: unknown): Object return assert(bounds.object(value)) end
local function define_tests()
    test.describe("Generic driver option forms", function()
        test.it("uses generic value forms and unconditional capability rights", function()
            local cli = assert(descriptors.load("bee.drivers.claude.descriptor:cli"))
            local fields = object(cli.options.fields)
            test.eq(descriptors.runtime_spec(object(fields.autocompact)).type, "text")
            test.eq(descriptors.runtime_spec(object(fields.json_schema)).type, "json")
            test.not_nil(descriptors.decode_option("json_schema", object(fields.json_schema), {type = "object", properties = {ok = {type = "boolean"}}}))
            test.eq(descriptors.decode_option("json_schema", object(fields.json_schema), false), false)
            test.eq(descriptors.decode_option("json_schema", object(fields.json_schema), true), true)
            test.is_nil(descriptors.decode_option("json_schema", object(fields.json_schema), json.decode("[]")))
            test.eq(canonical.encode(descriptors.decode_option("json_schema", object(fields.json_schema), json.decode("{}"))), "{}")
            local rendered = assert(universal.render_argv({{render = "json_schema", context = "first_turn"}}, {profile_id = "batch", brief = "Fixture", json_schema = false}, cli))
            test.eq(canonical.encode(rendered), canonical.encode({"--json-schema", "false"}))
            test.is_nil(descriptors.decode_option("json_schema", object(fields.json_schema), "{}"))
            test.not_nil(descriptors.decode_option("budget_usd", object(fields.budget_usd), "1.25"))
            test.is_nil(descriptors.decode_option("budget_usd", object(fields.budget_usd), "0"))
            test.is_nil(descriptors.decode_option("budget_usd", object(fields.budget_usd), "1e3"))
            local codex = assert(descriptors.load("bee.drivers.codex.descriptor:cli"))
            test.eq(canonical.encode(object(object(codex.options.fields).model_providers).capabilities), canonical.encode({"profile-option"}))
            for _, driver in ipairs({cli, codex}) do
                for _, raw in pairs(object(driver.options.fields)) do
                    local field = object(raw)
                    local rights = bounds.object(field.capabilities)
                    if rights then test.is_nil(rights["*"]); test.is_nil(rights["[]"]) end
                end
            end
            local field = object(fields.permission_bypass)
            local original = field.capabilities
            for _, key in ipairs({"*", "[]"}) do
                field.capabilities = {[key] = {"profile-option"}}
                test.is_true(descriptors.decode(cli) == nil)
            end
            field.capabilities = original
            local text = {type = "text", pattern = "^[a-z]+$"}
            test.eq(descriptors.decode_option("label", text, "abc"), "abc")
            test.is_nil(descriptors.decode_option("label", text, "123"))
            test.is_nil(descriptors.decode_option("label", {type = "text", pattern = "["}, "abc"))
        end)
    end)
end
return test.run_cases(define_tests)
