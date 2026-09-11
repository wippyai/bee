-- MIT. Activation declarations are deliberately narrow: they select from a
-- host-pinned catalog but confer no publication, launch or process authority.
local test = require("test")
local activation = require("activation")

local function entry(data: {[string]: unknown}?): {[string]: unknown}
    return {id = "test:activation", kind = "registry.entry", meta = {type = "bee.harness_activation"}, data = data}
end

local function define_tests()
    test.describe("Harness activation declaration", function()
        test.it("decodes a bounded, distinct binding selection", function()
            local decoded, err = activation.decode("test:activation", entry({schema_revision = "bee.harness-activation@1", bindings = {"bee.driver.claude:binding", "bee.driver.codex:binding"}}))
            if not decoded then error(tostring(err)) end
            test.is_true(decoded.bindings["bee.driver.claude:binding"])
            test.is_true(decoded.bindings["bee.driver.codex:binding"])
            test.is_nil(decoded.bindings["bee.harness.catalog:fake_binding"])
        end)
        test.it("rejects missing, malformed and broadened declarations", function()
            local missing, missing_error = activation.decode("test:activation", entry(nil))
            test.is_nil(missing)
            test.eq(missing_error, "test:activation has no data")
            local old, old_error = activation.decode("test:activation", entry({bindings = {}}))
            test.is_nil(old)
            test.eq(old_error, "test:activation: schema_revision must be bee.harness-activation@1")
            local duplicate, duplicate_error = activation.decode("test:activation", entry({schema_revision = "bee.harness-activation@1", bindings = {"bee.driver.claude:binding", "bee.driver.claude:binding"}}))
            test.is_nil(duplicate)
            test.eq(duplicate_error, "test:activation: bindings: list item 2 repeats")
            local unknown, unknown_error = activation.decode("test:activation", entry({schema_revision = "bee.harness-activation@1", bindings = {}, publish = true}))
            test.is_nil(unknown)
            test.eq(unknown_error, "test:activation: unknown field publish")
            local foreign = entry({schema_revision = "bee.harness-activation@1", bindings = {}})
            local foreign_meta = foreign.meta :: {[string]: unknown}
            foreign_meta.type = "bee.launch_policy"
            local wrong, wrong_error = activation.decode("test:activation", foreign)
            test.is_nil(wrong)
            test.eq(wrong_error, "test:activation is not a harness activation declaration")
        end)
    end)
end

return test.run_cases(define_tests)
