-- MIT. CLI descriptors are strict, bounded registry data.
local test = require("test")
local descriptor = require("descriptor")
type Object = {[string]: unknown}

local function copy_object(value: Object): Object
    local result: Object = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end

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

        test.it("rejects invalid defaults, undeclared template fields and cyclic flag dependencies", function()
            local claude = assert(descriptor.load("bee.driver.claude.descriptor:cli")) :: Object

            local bad_default = copy_object(claude)
            local options = copy_object(claude.options :: Object)
            local fields = copy_object(options.fields :: Object)
            local permission = copy_object(fields.permission_mode :: Object)
            permission.default = "bypassPermissions"
            fields.permission_mode = permission
            options.fields = fields
            bad_default.options = options
            local decoded, decode_error = descriptor.decode(bad_default)
            test.is_nil(decoded)
            test.not_nil(decode_error)

            local undeclared_field = copy_object(claude)
            local templates = copy_object(claude.argv_templates :: Object)
            local window = copy_object(templates.window :: Object)
            local argv: {unknown} = {}
            for _, item in ipairs(window.argv :: {unknown}) do argv[#argv + 1] = item end
            argv[#argv + 1] = {field = "not_declared"}
            window.argv = argv
            templates.window = window
            undeclared_field.argv_templates = templates
            decoded, decode_error = descriptor.decode(undeclared_field)
            test.is_nil(decoded)
            test.not_nil(decode_error)

            local cyclic_flag = copy_object(claude)
            local flags = copy_object(claude.flags :: Object)
            local turn_budget = copy_object(flags.turn_budget :: Object)
            turn_budget.argv = {{option = "turn_budget"}}
            flags.turn_budget = turn_budget
            cyclic_flag.flags = flags
            decoded, decode_error = descriptor.decode(cyclic_flag)
            test.is_nil(decoded)
            test.not_nil(decode_error)
        end)

        test.it("rejects inert option metadata and reserved request fields", function()
            local claude = assert(descriptor.load("bee.driver.claude.descriptor:cli")) :: Object
            local inert_metadata = copy_object(claude)
            local options = copy_object(claude.options :: Object)
            local fields = copy_object(options.fields :: Object)
            local permission = copy_object(fields.permission_mode :: Object)
            permission.constant = "MAX_TURNS"
            fields.permission_mode = permission
            options.fields = fields
            inert_metadata.options = options
            local decoded, decode_error = descriptor.decode(inert_metadata)
            test.is_nil(decoded)
            test.not_nil(decode_error)

            local reserved_field = copy_object(claude)
            options = copy_object(claude.options :: Object)
            fields = copy_object(options.fields :: Object)
            fields.profile_id = {type = "id"}
            options.fields = fields
            reserved_field.options = options
            decoded, decode_error = descriptor.decode(reserved_field)
            test.is_nil(decoded)
            test.not_nil(decode_error)
        end)
    end)
end

return test.run_cases(define_tests)
