local test = require("test")
local handler = require("handler")
local native_command = require("native_command")
local function define_tests()
    test.describe("Application command handlers", function()
        test.it("copies bounded command metadata and rejects ambiguous or reserved aliases", function()
            local source = {{name = "sample", arguments = {"native"}, fullscreen = true}}
            local handlers = handler.decode(source)
            if not handlers then error("Valid handler rejected") end
            source[1].arguments[1] = "changed"
            test.eq(handlers[1].arguments[1], "native")
            test.is_true(handlers[1].fullscreen)
            test.is_nil(handler.decode({{name = "same"}, {name = "same"}}))
            test.is_nil(handler.decode({[2] = {name = "hole"}}))
            for _, name in ipairs({"", "bad:name", "with space", "update", "runtime", "run"}) do
                test.is_nil(handler.decode({{name = name}}))
            end
            test.is_nil(handler.decode({{name = "sample", fullscreen = "yes"}}))
        end)
        test.it("encodes native arguments without shell expansion", function()
            test.eq(native_command.encode({}), "/bin/bash -i")
            test.eq(native_command.encode({"tool", "two words", "", "a'b", "$HOME;$(id)"}),
                "'tool' 'two words' '' 'a'\\''b' '$HOME;$(id)'")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
