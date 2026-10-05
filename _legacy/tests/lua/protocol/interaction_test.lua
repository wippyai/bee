local test = require("test")
local interaction = require("interaction")
local function spec(): {version: integer, request_id: string, id: string, instance_id: string, kind: string,
    title: string, message: string, accept: string, initial: string}
    return {version = 1, request_id = "request", id = "view", instance_id = "instance", kind = "confirm",
        title = "Close terminal?", message = "Running commands will stop.", accept = "Close", initial = ""}
end
local function define_tests()
    test.describe("Interaction boundary", function()
        test.it("decodes bounded confirmations and rejects ambiguous or malformed input", function()
            test.not_nil(interaction.spec(spec()))
            local value = spec(); value.version = 2
            test.is_nil(interaction.spec(value))
            value = spec(); value.kind = "password"
            test.is_nil(interaction.spec(value))
            value = spec(); value.title = "\27[31m"
            test.is_nil(interaction.spec(value))
            value = spec(); value.message = string.rep("x", 513)
            test.is_nil(interaction.spec(value))
            value = spec(); value.initial = "unexpected"
            test.is_nil(interaction.spec(value))
            value.kind = "text"
            test.not_nil(interaction.spec(value))
            value.initial = string.rep("x", 257)
            test.is_nil(interaction.spec(value))
        end)
        test.it("bounds snapshots and rejects holes or duplicate view dialogs", function()
            test.not_nil(interaction.snapshot({version = 1, items = {}}))
            test.not_nil(interaction.snapshot({version = 1, items = {spec()}}))
            test.is_nil(interaction.snapshot({version = 1, items = {[2] = spec()}}))
            test.is_nil(interaction.snapshot({version = 1, items = {spec(), spec()}}))
            test.is_nil(interaction.snapshot({version = 1, items = {[17] = spec()}}))
        end)
        test.it("requires a definite response and never treats cancellation as an answer", function()
            test.not_nil(interaction.response({version = 1, request_id = "r", id = "v", instance_id = "i", action = "cancel"}))
            test.is_nil(interaction.response({version = 1, request_id = "r", id = "v", instance_id = "i", action = "cancel", value = "yes"}))
            test.is_nil(interaction.response({version = 1, request_id = "r", id = "v", instance_id = "i", action = "maybe"}))
            test.is_nil(interaction.response({version = 1, request_id = "", id = "v", instance_id = "i", action = "accept"}))
            test.is_nil(interaction.response({version = 1, request_id = "r", id = "v", instance_id = "i", action = "accept", value = "\n"}))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
