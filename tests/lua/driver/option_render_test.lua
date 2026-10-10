-- SPDX-License-Identifier: MIT
local test = require("test")
local render = require("render")
local descriptor = require("descriptor")
local configuration = require("configuration")
local materializer = require("materializer")
local bounds = require("bounds")
local json = require("json")
local toml = require("toml")
local hash = require("hash")
local registry = require("registry")
local universal = require("universal")
type Object = {[string]: unknown}
local function field(format: string, path: {string}, merge: string): Object
    return {render = {{kind = "config", contexts = {"first_turn"}, file = "provider/config." .. format,
        format = format, path = path, merge = merge, value = {field = "provider.options.settings"}}}}
end
local function define_tests()
    test.describe("Descriptor option delivery", function()
        test.it("renders installed custom-provider schemas with environment references only", function()
            local endpoint = "https://models.example.test/v1"
            local opencode = assert(descriptor.load("bee.driver.opencode.descriptor:cli"))
            local fields = assert(bounds.object(opencode.options.fields))
            local provider = {npm = "@ai-sdk/openai-compatible", name = "Local", options = {baseURL = endpoint, apiKey = "{env:OPENAI_API_KEY}"},
                models = {gemma = {name = "gemma", tool_call = true}}}
            local checked = assert(descriptor.decode_option("providers", fields.providers, {local_model = provider}))
            local files = assert(render.files(fields, {providers = checked, enabled_providers = {"local_model"}}, "window", {}))
            local content = assert(bounds.object(json.decode(files[1].content)))
            local providers = assert(bounds.object(content.provider))
            local options = assert(bounds.object(assert(bounds.object(providers.local_model)).options))
            test.eq(options.baseURL, endpoint)
            test.eq(options.apiKey, "{env:OPENAI_API_KEY}")
            provider.options.apiKey = "fixture-raw-key"
            test.is_nil(descriptor.decode_option("providers", fields.providers, {local_model = provider}))
            local codex = assert(descriptor.load("bee.driver.codex.descriptor:cli"))
            fields = assert(bounds.object(codex.options.fields))
            local values = {model_provider = "local_model", model_providers = {local_model = {name = "Local", base_url = endpoint,
                env_key = "OPENAI_API_KEY", wire_api = "responses"}}}
            test.not_nil(descriptor.decode_option("model_providers", fields.model_providers, values.model_providers))
            files = assert(render.files(fields, values, "window", {}))
            content = assert(bounds.object(toml.decode(files[1].content)))
            test.eq(content.model_provider, "local_model")
            local selected = assert(bounds.object(assert(bounds.object(content.model_providers)).local_model))
            test.eq(selected.base_url, endpoint)
            test.eq(selected.env_key, "OPENAI_API_KEY")
        end)
        test.it("measures omitted and empty option selections as the same configuration", function()
            local target = "bee.driver.claude.binding:configure"
            test.eq(configuration.digest("bee.driver.claude.binding:binding", {fixture = false, context = "window"}, target),
                (configuration.digest("bee.driver.claude.binding:binding", {fixture = false, context = "window", option_values = {}}, target)))
        end)
        test.it("decodes bounded structured values and rejects undeclared children", function()
            local spec: Object = {value_schema = {type = "object", additionalProperties = false, required = {"enabled"},
                properties = {enabled = {type = "boolean"}, limit = {type = "integer", minimum = 1, maximum = 5},
                    tags = {type = "array", maxItems = 2, items = {type = "string", maxLength = 8}}}}}
            local value = assert(descriptor.decode_option("settings", spec, {enabled = false, limit = 3, tags = {"x"}}))
            test.eq(assert(bounds.object(value)).enabled, false)
            for _, raw in ipairs({{limit = 3}, {enabled = false, extra = true}, {enabled = true, limit = 6}, {enabled = true, tags = {"x", "y", "z"}}}) do
                test.is_nil(descriptor.decode_option("settings", spec, raw))
            end
        end)
        test.it("validates bounded provider maps using their declared value schemas", function()
            local spec = {value_schema = {type = "object", maxProperties = 2, additionalProperties = {
                type = "object", additionalProperties = false, required = {"base_url", "env_key"}, properties = {
                    base_url = {type = "string", maxLength = 512}, env_key = {type = "string", enum = {"OPENAI_API_KEY"}}}}}}
            local decoded = assert(descriptor.decode_option("providers", spec,
                {arbitrary = {base_url = "https://models.example.test/v1", env_key = "OPENAI_API_KEY"}}))
            test.not_nil(assert(bounds.object(decoded)).arbitrary)
            for _, raw in ipairs({{arbitrary = {base_url = "https://models.example.test/v1", env_key = "secret-value"}},
                {arbitrary = {base_url = "https://models.example.test/v1", api_key = "secret-value"}},
                {a = {base_url = "url", env_key = "OPENAI_API_KEY"}, b = {base_url = "url", env_key = "OPENAI_API_KEY"}, c = {base_url = "url", env_key = "OPENAI_API_KEY"}}}) do
                test.is_nil(descriptor.decode_option("providers", spec, raw))
            end
        end)
        test.it("renders nested JSON and TOML through the same declaration", function()
            for _, format in ipairs({"json", "toml"}) do
                local files = assert(render.files({settings = field(format, {"agent", "settings"}, "set")},
                    {settings = {enabled = false, limit = 3, tags = {"x", "y"}}}, "first_turn", {}))
                test.eq(#files, 1)
                test.eq(files[1].provider_ref, configuration.OPTIONS_PROVIDER_REF)
                local value = format == "json" and json.decode(files[1].content) or toml.decode(files[1].content)
                local agent = assert(bounds.object(assert(bounds.object(value)).agent))
                test.eq(assert(bounds.object(agent.settings)).enabled, false)
                test.eq(files[1].digest, (hash.sha256(files[1].content)))
                test.eq(#assert(render.files({settings = field(format, {"agent"}, "set")}, {settings = true}, "resume", {})), 0)
            end
        end)
        test.it("composes selected options with retained ambient configuration", function()
            for _, format in ipairs({"json", "toml"}) do
                local empty = assert(hash.sha256(""))
                local path = "provider/config." .. format
                local base: configuration.Configuration = {revision = "test@1", path = path, content = "", digest = empty,
                    provider_ref = configuration.LOGIN_PROVIDER_REF, composition = {kind = "copy", base_path = "provider/base." .. format}}
                local files = assert(render.files({settings = field(format, {"agent", "guidance"}, "append")}, {settings = "new"}, "first_turn", {base}))
                local decoded = assert(configuration.decode_file(files[1]))
                local original = format == "json" and '{"agent":{"guidance":"old"},"retained":true}' or 'retained = true\n[agent]\nguidance = "old"\n'
                local result = assert(materializer.render(decoded, {}, nil, original))
                local document = assert(bounds.object(format == "json" and json.decode(result) or toml.decode(result)))
                test.eq(document.retained, true)
                test.eq(assert(bounds.object(document.agent)).guidance, "old\n\nnew")
            end
        end)
        test.it("renders environment scalars and literal tokens without stringifying structures", function()
            local fields: Object = {mode = {render = {{kind = "env", contexts = {"first_turn"}, name = "PROVIDER_MODE", value = {field = "provider.options.mode"}}}},
                fixed = {render = {{kind = "env", contexts = {"first_turn"}, name = "PROVIDER_FIXED", value = {literal = "stable"}}}}}
            local values = assert(render.environment(fields, {mode = false, fixed = true}, "first_turn"))
            test.eq(values.PROVIDER_FIXED, "stable")
            test.eq(values.PROVIDER_MODE, "false")
            test.is_nil(render.environment(fields, {mode = {secret = "ref"}}, "first_turn"))
        end)
        test.it("fences environment replies to selected declarations and defaults", function()
            local fields: Object = {mode = {default = false, render = {{kind = "env", contexts = {"first_turn"}, name = "PROVIDER_MODE", value = {field = "provider.options.mode"}}}}}
            local function reply(values: Object, environment: Object, context: string): configuration.Delivery?
                return configuration.decode_reply({ok = true, delivery = {arguments = {}, files = {}, environment = environment}},
                    nil, nil, nil, false, values, fields, context)
            end
            test.not_nil(reply({}, {PROVIDER_MODE = "false"}, "first_turn"))
            test.not_nil(reply({mode = true}, {PROVIDER_MODE = "true"}, "first_turn"))
            test.is_nil(reply({mode = true}, {PROVIDER_MODE = "false"}, "first_turn"))
            test.is_nil(reply({}, {PROVIDER_EXTRA = "false"}, "first_turn"))
            test.is_nil(reply({}, {PROVIDER_MODE = "false"}, "resume"))
        end)
        test.it("fences structured replies to selected subtrees and composition operations", function()
            for _, format in ipairs({"json", "toml"}) do
                local declaration = field(format, {"agent", "settings"}, "set")
                local render_spec = assert(bounds.object(assert(bounds.array(declaration.render, 8))[1]))
                render_spec.file = "provider/options.conf"
                local fields: Object = {settings = declaration}
                local values: Object = {settings = {enabled = false}}
                local files = assert(render.files(fields, values, "first_turn", {}))
                local function reply(): configuration.Delivery?
                    return configuration.decode_reply({ok = true, delivery = {arguments = {}, files = files}},
                        nil, nil, nil, false, values, fields, "first_turn")
                end
                test.not_nil(reply())
                files[1].composition = {kind = format == "json" and "json_patch" or "toml_patch", base_path = "provider/base.conf",
                    operations = {{kind = "set", path = {"agent", "settings"}}}}
                test.not_nil(reply())
                files[1].composition = {kind = format == "json" and "json_patch" or "toml_patch", base_path = "provider/base.conf",
                    operations = {{kind = "set", path = {"extra"}}}}
                test.is_nil(reply())
                files[1].composition = nil
                local extra = {agent = {settings = {enabled = false}}, extra = true}
                files[1].content = assert(format == "json" and json.encode(extra) or toml.encode(extra))
                files[1].digest = assert(hash.sha256(files[1].content))
                test.is_nil(reply())
            end
        end)
        test.it("launches and configures newly declared options without changing templates", function()
            local ref = "bee.driver.claude.descriptor:cli"
            local original_digest = assert(configuration.digest("bee.driver.claude.binding:binding", {fixture = false}, "bee.driver.claude.binding:configure"))
            local entry = assert(registry.get(ref))
            local original = assert(json.encode(entry.data))
            local data = assert(bounds.object(entry.data))
            local fields = assert(bounds.object(assert(bounds.object(data.options)).fields))
            fields.extra_mode = {id = "extra_mode", group = "advanced", security_class = "free", path = "provider.options.extra_mode", value_schema = {type = "string", enum = {"careful"}},
                label = "Mode", description = "Fixture mode", section = "advanced", order = 999,
                contexts = {"first_turn"}, support = {help_probe = {argv = {"--help"}, flag = "--extra-mode"}},
                render = {{kind = "argv", contexts = {"first_turn"}, tokens = {"--extra-mode", {field = "provider.options.extra_mode"}}},
                    {kind = "env", contexts = {"first_turn"}, name = "PROVIDER_EXTRA_MODE", value = {field = "provider.options.extra_mode"}}}}
            fields.settings = {id = "settings", group = "advanced", security_class = "free", path = "provider.options.settings", value_schema = {type = "object", additionalProperties = false, properties = {enabled = {type = "boolean"}}, required = {"enabled"}},
                label = "Settings", description = "Fixture settings", section = "advanced", order = 1000,
                contexts = {"first_turn"}, support = {config_schema_ref = "fixture:settings"},
                render = {{kind = "config", contexts = {"first_turn"}, file = "provider/config.json", format = "json", path = {"settings"}, merge = "set", value = {field = "provider.options.settings"}}}}
            local changes = registry.snapshot():changes()
            assert(changes:update(entry)); assert(changes:apply())
            local selected, err = descriptor.load(ref)
            local changed_digest = configuration.digest("bee.driver.claude.binding:binding", {fixture = false}, "bee.driver.claude.binding:configure")
            local launch: unknown
            local reply: Object = {}
            if selected then
                launch = universal.prepare(ref)({profile_id = "batch", brief = "Fixture", extra_mode = "careful", settings = {enabled = false}})
                reply = universal.configure("fixture", {fixture = function(_request: configuration.Request): Object return {ok = true, delivery = {arguments = {}, files = {}}} end}, ref)
                    ({fixture = false, option_values = {extra_mode = "careful", settings = {enabled = false}}})
            end
            entry.data = assert(json.decode(original))
            changes = registry.snapshot():changes(); assert(changes:update(entry)); assert(changes:apply())
            if not selected then error(tostring(err)) end
            test.neq(changed_digest, original_digest)
            local launch_reply = assert(bounds.object(launch))
            test.eq(launch_reply.ok, true)
            local argv = assert(bounds.ids(assert(bounds.object(launch_reply.launch)).argv, true))
            test.not_nil(bounds.member("--extra-mode", argv)); test.eq(argv[#argv], "careful")
            test.eq(reply.ok, true)
            local delivered = assert(configuration.decode_delivery(reply.delivery))
            test.eq(delivered.environment and delivered.environment.PROVIDER_EXTRA_MODE, "careful")
            test.eq(assert(bounds.object(assert(bounds.object(json.decode(delivered.files[1].content))).settings)).enabled, false)
        end)
        test.it("delivers every built-in prompt through descriptor file renders", function()
            for _, provider in ipairs({"claude", "codex", "agy", "grok", "muse", "opencode"}) do
                local selected = assert(descriptor.load("bee.driver." .. provider .. ".descriptor:cli"))
                local prompt = assert(bounds.object(assert(bounds.object(selected.options.fields)).system_prompt_append))
                local files = assert(render.files({system_prompt_append = prompt}, {system_prompt_append = "append marker", system_prompt_files = {"/private/.bee/system-prompt-append.txt"}}, "first_turn", {}))
                test.is_true(#files >= 1)
                local text = false
                for _, file in ipairs(files) do if file.content == "append marker" then text = true end end
                test.is_true(text)
            end
        end)
    end)
end
return test.run_cases(define_tests)
