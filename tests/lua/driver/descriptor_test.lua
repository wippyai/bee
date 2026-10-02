-- MIT. CLI descriptors are strict, bounded registry data.
local test = require("test")
local principals = require("principals")
local descriptor = require("descriptor")
local resolver = require("resolver")
local registry = require("registry")
local login_evidence = require("login_evidence")
local bounds = require("bounds")
type Object = {[string]: unknown}

local function copy_object(value: Object): Object
    local result: Object = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end

local function define_tests()
    test.describe("External CLI descriptors", function()
        test.it("resolves configuration renderers from the driver's binding child", function()
            local pinned = assert(registry.snapshot())
            for _, provider in ipairs({"claude", "codex", "agy", "grok", "muse", "opencode"}) do
                local namespace = "bee.driver." .. provider .. ".binding"
                local renderer, err, selected = resolver.configure_renderer(pinned, namespace .. ":binding", namespace .. ":configure")
                test.is_nil(err)
                test.eq(renderer, provider)
                test.eq(selected and selected.provider, provider)
                local inferred, inferred_error = resolver.configure_renderer_for_target(pinned, namespace .. ":configure")
                test.is_nil(inferred_error)
                test.eq(inferred, provider)
                test.is_nil(resolver.configure_renderer(pinned, namespace .. ":binding", "bee.driver.other.binding:configure"))
            end
        end)
        test.it("declares permission answer transports for the launch context without provider dispatch", function()
            local expected: {[string]: {string}} = {
                claude = {"stdio", "hook_http"}, codex = {"provider", "hook_mcp"},
                agy = {"provider", "provider"}, grok = {"provider", "provider"},
                muse = {"provider", "provider"}, opencode = {"provider", "provider"}}
            for provider, transports in pairs(expected) do
                local loaded = assert(descriptor.load("bee.driver." .. provider .. ".descriptor:cli"))
                local headless = descriptor.permission_answer(loaded, "first_turn")
                local window = descriptor.permission_answer(loaded, "window")
                test.eq(headless.transport, transports[1])
                test.eq(window.transport, transports[2])
                test.eq(descriptor.permission_answer(loaded, "resume").transport, transports[1])
                if headless.transport == "provider" then test.not_nil(headless.reason) else test.not_nil(headless.adapter_ref) end
            end
        end)
        test.it("decodes bounded any-of login evidence and rejects malformed alternatives", function()
            local loaded = assert(bounds.object(assert(descriptor.load("bee.driver.claude.descriptor:cli"))))
            local changed = copy_object(loaded)
            local valid = {
                {kind = "file_exists", paths = {".fixture/auth.json", ".fixture/config.jsonc"}},
                {kind = "env_present", names = {"FIXTURE_API_KEY"}},
                {kind = "auth_status", argv = {"auth", "status"}, success_exit_code = 0, timeout_ms = 1000},
            }
            changed.login_evidence = {command = "fixture login", any_of = valid}
            test.not_nil(descriptor.decode(changed))
            local invalid: {unknown} = {
                {}, {kind = "file_exists", paths = {}},
                {kind = "file_exists", paths = {"../secret"}},
                {kind = "env_present", names = {"KEY=value"}},
                {kind = "env_present", names = {"KEY"}, value = "secret"},
                {kind = "auth_status", argv = {}, success_exit_code = 0, timeout_ms = 1000},
                {kind = "auth_status", argv = {"auth", "status"}, success_exit_code = 256, timeout_ms = 1000},
                {kind = "auth_status", argv = {"auth", "status"}, success_exit_code = 0, timeout_ms = 30001},
                {kind = "auth_status", argv = {"auth", "status\n"}, success_exit_code = 0, timeout_ms = 1000},
            }
            for _, item in ipairs(invalid) do
                changed.login_evidence = {command = "fixture login", any_of = {item}}
                local decoded, decode_error = descriptor.decode(changed)
                test.is_nil(decoded)
                test.not_nil(decode_error)
            end
            changed.login_evidence = {command = "fixture login", any_of = {}}
            test.is_nil(descriptor.decode(changed))
        end)

        test.it("declares real login sources for all six CLIs", function()
            local cases = {
                {provider = "claude", path = ".claude/.credentials.json", variable = "ANTHROPIC_API_KEY", status = "auth"},
                {provider = "codex", path = ".codex/auth.json", variable = "CODEX_API_KEY", status = "login"},
                {provider = "agy", path = ".gemini/antigravity-cli/antigravity-oauth-token", variable = "GEMINI_API_KEY"},
                {provider = "grok", path = ".grok/auth.json", variable = "XAI_API_KEY"},
                {provider = "muse", path = ".config/muse/auth.json", variable = "META_API_KEY"},
                {provider = "opencode", path = ".config/opencode/opencode.jsonc", variable = "OPENCODE_API_KEY"},
            }
            for _, case in ipairs(cases) do
                local selected = assert(descriptor.load("bee.driver." .. case.provider .. ".descriptor:cli"))
                local paths, names, status = false, false, false
                for _, evidence in ipairs(selected.login_evidence.any_of) do
                    if evidence.kind == "file_exists" then
                        for _, path in ipairs(evidence.paths) do if path == case.path then paths = true end end
                    elseif evidence.kind == "env_present" then
                        for _, name in ipairs(evidence.names) do if name == case.variable then names = true end end
                    else
                        test.eq(evidence.argv[1], case.status)
                        test.eq(evidence.argv[2], "status")
                        test.eq(evidence.success_exit_code, 0)
                        test.eq(evidence.timeout_ms, 3000)
                        status = true
                    end
                end
                test.is_true(paths)
                test.is_true(names)
                test.eq(status, case.status ~= nil)
            end
        end)

        test.it("does not treat Grok configuration alone as a signed-in login", function()
            local selected = assert(descriptor.load("bee.driver.grok.descriptor:cli"))
            local declaration = assert(login_evidence.decode(selected.login_evidence))
            local config_only = login_evidence.probe(declaration, {
                file = function(path, _variable, _directory) return path == ".grok/config.toml", nil end,
                environment = function(_name) return false end,
                status = function(_argv, _timeout) return nil end,
            })
            test.eq(login_evidence.present(declaration, config_only), false)
            local signed_in = login_evidence.probe(declaration, {
                file = function(path, _variable, _directory) return path == ".grok/auth.json", nil end,
                environment = function(_name) return false end,
                status = function(_argv, _timeout) return nil end,
            })
            test.eq(login_evidence.present(declaration, signed_in), true)
        end)
        test.it("probes file alternatives, environment names and bounded status without values", function()
            local declaration = assert(login_evidence.decode({command = "fixture login", any_of = {
                {kind = "file_exists", paths = {".fixture/missing", ".fixture/config.jsonc"}},
                {kind = "env_present", names = {"MISSING_KEY", "FIXTURE_KEY"}},
                {kind = "auth_status", argv = {"auth", "status"}, success_exit_code = 7, timeout_ms = 42},
            }}))
            local checks = login_evidence.probe(declaration, {
                file = function(path, _variable, _directory) return path == ".fixture/config.jsonc", nil end,
                environment = function(name) return name == "FIXTURE_KEY" end,
                status = function(argv, timeout)
                    test.eq(argv[1], "auth")
                    test.eq(argv[2], "status")
                    test.eq(timeout, 42)
                    return 7
                end,
            })
            test.eq(#checks, 3)
            for _, check in ipairs(checks) do test.eq(check.present, true) end
            test.eq(checks[3].exit_code, 7)
            local uncertain = login_evidence.probe(declaration, {
                file = function(_path, _variable, _directory) return false, nil end,
                environment = function(_name) return false end,
                status = function(_argv, _timeout) return nil end,
            })
            test.is_nil(login_evidence.present(declaration, uncertain))
        end)

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
            local claude = assert(bounds.object(assert(descriptor.load("bee.driver.claude.descriptor:cli"))))

            local bad_default = copy_object(claude)
            local options = copy_object(assert(bounds.object(claude.options)))
            local fields = copy_object(assert(bounds.object(options.fields)))
            local permission = copy_object(assert(bounds.object(fields.permission_mode)))
            permission.default = "bypassPermissions"
            fields.permission_mode = permission
            options.fields = fields
            bad_default.options = options
            local decoded, decode_error = descriptor.decode(bad_default)
            test.is_nil(decoded)
            test.not_nil(decode_error)

            local undeclared_field = copy_object(claude)
            local templates = copy_object(assert(bounds.object(claude.argv_templates)))
            local window = copy_object(assert(bounds.object(templates.window)))
            local argv: {unknown} = {}
            for _, item in ipairs(principals.items(window.argv)) do argv[#argv + 1] = item end
            argv[#argv + 1] = {field = "not_declared"}
            window.argv = argv
            templates.window = window
            undeclared_field.argv_templates = templates
            decoded, decode_error = descriptor.decode(undeclared_field)
            test.is_nil(decoded)
            test.not_nil(decode_error)

            local cyclic_flag = copy_object(claude)
            local flags = copy_object(assert(bounds.object(claude.flags)))
            local permission: Object = {field = "permission_mode", argv = {{option = "permission"}}}
            flags.permission = permission
            cyclic_flag.flags = flags
            decoded, decode_error = descriptor.decode(cyclic_flag)
            test.is_nil(decoded)
            test.not_nil(decode_error)

            local legacy_budget = copy_object(claude)
            local options_source = bounds.object(claude.options)
            if not options_source then error("Claude options are malformed") end
            local options = copy_object(options_source)
            local fields_source = bounds.object(options.fields)
            if not fields_source then error("Claude option fields are malformed") end
            local fields = copy_object(fields_source)
            fields.turn_budget = {type = "budget", max = 128}
            options.fields = fields
            legacy_budget.options = options
            decoded, decode_error = descriptor.decode(legacy_budget)
            test.is_nil(decoded)
            test.not_nil(decode_error)
        end)

        test.it("rejects inert option metadata and reserved request fields", function()
            local claude = assert(bounds.object(assert(descriptor.load("bee.driver.claude.descriptor:cli"))))
            local inert_metadata = copy_object(claude)
            local options = copy_object(assert(bounds.object(claude.options)))
            local fields = copy_object(assert(bounds.object(options.fields)))
            local permission = copy_object(assert(bounds.object(fields.permission_mode)))
            permission.constant = "MAX_TURNS"
            fields.permission_mode = permission
            options.fields = fields
            inert_metadata.options = options
            local decoded, decode_error = descriptor.decode(inert_metadata)
            test.is_nil(decoded)
            test.not_nil(decode_error)

            local reserved_field = copy_object(claude)
            options = copy_object(assert(bounds.object(claude.options)))
            fields = copy_object(assert(bounds.object(options.fields)))
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
