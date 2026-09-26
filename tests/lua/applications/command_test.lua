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
        test.it("decodes bounded bee.application_command registry entries and rejects invalid or reserved aliases", function()
            local valid_entry = {
                id = "bee.driver.claude:command",
                data = {
                    name = "claude",
                    definition_id = "bee.harness.window:app",
                    arguments = {"bee.driver.claude:default_window"},
                    fullscreen = true,
                },
            }
            local decoded = handler.decode_command(valid_entry)
            if not decoded then error("Valid command entry rejected") end
            test.eq(decoded.name, "claude")
            test.eq(decoded.definition_id, "bee.harness.window:app")
            test.eq(#decoded.arguments, 1)
            test.eq(decoded.arguments[1], "bee.driver.claude:default_window")
            test.is_true(decoded.fullscreen)

            local flat = handler.decode_command({
                name = "custom",
                definition_id = "bee.test:app",
                arguments = {"arg1", "arg2"},
            })
            if not flat then error("Valid flat command rejected") end
            test.eq(flat.name, "custom")
            test.eq(flat.definition_id, "bee.test:app")
            test.eq(#flat.arguments, 2)
            test.is_false(flat.fullscreen)

            test.is_nil(handler.decode_command("not a table"))
            test.is_nil(handler.decode_command({name = 123, definition_id = "bee.test:app"}))
            test.is_nil(handler.decode_command({name = "valid", definition_id = 456}))
            test.is_nil(handler.decode_command({name = "valid", definition_id = ""}))
            for _, name in ipairs({"", "bad:name", "with space", "Upper", "1starts_num", string.rep("a", 41), "update", "runtime", "run"}) do
                test.is_nil(handler.decode_command({name = name, definition_id = "bee.test:app"}))
            end
            test.is_nil(handler.decode_command({name = "sample", definition_id = "bee.test:app", fullscreen = "yes"}))
            test.is_nil(handler.decode_command({name = "sample", definition_id = "bee.test:app", arguments = "not-table"}))
            test.is_nil(handler.decode_command({name = "sample", definition_id = "bee.test:app", arguments = {string.char(1) .. "control"}}))
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
                muse = "bee.driver.muse:default_window",
                opencode = "bee.driver.opencode:default_window",
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
        test.it("reports helpful package hints for known agent commands and plain errors for unknown commands", function()
            for _, name in ipairs({"claude", "codex", "agy", "grok", "muse", "opencode", "agent"}) do
                test.eq(handler.unknown_error(name), "Unknown Bee command: " .. name .. " (install bee/agents)")
            end
            test.eq(handler.unknown_error("nonexistent"), "Unknown Bee command: nonexistent")

            local launch, err = handler.resolve("nonexistent", {})
            test.is_nil(launch)
            test.eq(err, "Unknown Bee command: nonexistent")

            local bad, bad_err = handler.resolve("bad:name", {})
            test.is_nil(bad)
            test.eq(bad_err, "Invalid Bee command")

            for _, reserved in ipairs({"run", "runtime", "update"}) do
                local res, res_err = handler.resolve(reserved, {})
                test.is_nil(res)
                test.eq(res_err, "Unknown Bee command: " .. reserved)
            end
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
