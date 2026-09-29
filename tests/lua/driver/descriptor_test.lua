-- MIT. CLI descriptors are strict, bounded registry data.
local test = require("test")
local descriptor = require("descriptor")

local function define_tests()
    test.describe("External CLI descriptors", function()
        test.it("loads each harness descriptor and rejects unknown top-level and nested fields", function()
            local entries = {
                {ref = "bee.driver.claude.descriptor:cli", provider = "claude", codec = "claude-stream-json"},
                {ref = "bee.driver.codex.descriptor:cli", provider = "codex", codec = "codex-jsonl"},
                {ref = "bee.driver.opencode.descriptor:cli", provider = "opencode", codec = "opencode-json-events"},
                {ref = "bee.driver.agy.descriptor:cli", provider = "agy", codec = "agy-stream-json"},
                {ref = "bee.driver.grok.descriptor:cli", provider = "grok", codec = "grok-streaming-json"},
                {ref = "bee.driver.muse.descriptor:cli", provider = "muse", codec = "muse-record-jsonl"},
            }
            for _, item in ipairs(entries) do
                local loaded, load_error = descriptor.load(item.ref)
                if not loaded then error(tostring(load_error)) end
                test.eq(loaded.provider, item.provider)
                test.eq(loaded.codec, item.codec)
                test.eq(loaded.configure, item.provider)

                local extra_field = {}
                for key, value in pairs(loaded) do extra_field[key] = value end
                extra_field.unknown_field = true
                local decoded, decode_error = descriptor.decode(extra_field)
                test.is_nil(decoded)
                test.not_nil(decode_error)

                local nested_field = {}
                for key, value in pairs(loaded) do nested_field[key] = value end
                nested_field.version_probe = {argv = {"--version"}, unexpected = true}
                decoded, decode_error = descriptor.decode(nested_field)
                test.is_nil(decoded)
                test.not_nil(decode_error)

                local unknown_codec = {}
                for key, value in pairs(loaded) do unknown_codec[key] = value end
                unknown_codec.codec = "unknown-codec"
                decoded, decode_error = descriptor.decode(unknown_codec)
                test.is_nil(decoded)
                test.not_nil(decode_error)
            end
        end)
    end)
end

return test.run_cases(define_tests)
