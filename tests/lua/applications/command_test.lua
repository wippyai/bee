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
        test.it("routes every harness alias through the managed Agent window and refuses raw bypass arguments", function()
            local expected = {
                agy = "bee.driver.agy:default_window",
                claude = "bee.driver.claude:default_window",
                codex = "bee.driver.codex:default_window",
                grok = "bee.driver.grok:default_window",
            }
            for name, definition_ref in pairs(expected) do
                local launch, err = handler.resolve(name, {})
                if not launch then error(tostring(err)) end
                test.eq(launch.definition_id, "bee.harness.window:app")
                test.eq(#launch.arguments, 1)
                test.eq(launch.arguments[1], definition_ref)
                test.is_true(launch.fullscreen)
                local bypass, bypass_error = handler.resolve(name, {"--dangerously-skip-permissions"})
                test.is_nil(bypass)
                test.eq(bypass_error, "Managed Bee command does not accept raw arguments: " .. name)
            end
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
