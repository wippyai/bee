local test = require("test")
local descriptors = require("descriptors")
local effective = require("effective")
local registry = require("registry")
local bounds = require("bounds")
local function define_tests()
    test.describe("Effective driver option schema", function()
        test.it("declares typed security metadata on every editable option", function()
            for _, entry in ipairs(assert(registry.find({["meta.type"] = descriptors.TYPE}))) do
                local descriptor = assert(descriptors.decode(entry.data))
                for name, raw in pairs(assert(bounds.object(descriptor.options.fields))) do
                    local field = assert(bounds.object(raw))
                    if field.path then
                        test.eq(field.id, name)
                        test.not_nil(bounds.member(field.group, {"model/provider", "behavior", "access/trust", "tools/integrations", "advanced"}))
                        test.not_nil(bounds.member(field.security_class, {"free", "person-only", "host-ceiling"}))
                    end
                end
            end
        end)
        test.it("rejects malformed security metadata, defaults and dependency references", function()
            local entry = assert(registry.get("bee.driver.claude.descriptor:cli"))
            local raw = assert(bounds.object(entry.data))
            local field = assert(bounds.object(assert(bounds.object(assert(bounds.object(raw.options)).fields)).permission_mode))
            field.security_class = "consent-overrides-host"
            test.is_nil(descriptors.decode(raw))
            field.security_class = "host-ceiling"
            field.default = "invented"
            test.is_nil(descriptors.decode(raw))
            field.default = "manual"
            field.dependencies = {"missing"}
            test.is_nil(descriptors.decode(raw))
        end)
        test.it("locks options without installed CLI capability evidence", function()
            local cli = assert(descriptors.load("bee.driver.claude.descriptor:cli"))
            local policy = {profile_restrictions = {["provider.model"] = {kind = "declared"}}}
            local capabilities = {["provider.permission_mode"] = {supported = true}, ["provider.options.folder_trust"] = {supported = true}}
            local compiled = assert(effective.compile(cli, policy, capabilities))
            test.not_nil(compiled.fields.model.locked_reason)
            test.is_nil(effective.compile(cli, policy, capabilities, {model = "sonnet"}))
            test.is_nil(effective.compile(cli, policy, {}))
        end)
        test.it("refuses permission bypass from defaults and explicit values", function()
            local cli = assert(descriptors.load("bee.driver.claude.descriptor:cli"))
            local policy = {profile_restrictions = {["provider.permission_mode"] = {kind = "declared"}}}
            local result, err = effective.compile(cli, policy, nil, {permission_mode = "bypassPermissions"}, "person")
            test.is_nil(result)
            test.not_nil(err)
            result, err = effective.compile(cli, {prepare_options = {permission_mode = "bypassPermissions"}}, nil, {})
            test.is_nil(result)
            test.not_nil(err)
        end)
        test.it("refuses delegated folder trust even with an admitted value", function()
            local cli = assert(descriptors.load("bee.driver.claude.descriptor:cli"))
            local policy = {profile_restrictions = {["provider.options.folder_trust"] = {kind = "declared"}}}
            local person = assert(effective.compile(cli, policy, nil, {folder_trust = "approved-workdir"}, "person"))
            test.eq(person.values.folder_trust, "approved-workdir")
            local delegated, err = effective.compile(cli, policy, nil, {folder_trust = "approved-workdir"}, "delegated")
            test.is_nil(delegated)
            test.not_nil(err)
        end)
        test.it("intersects rights, unions denies and takes minimum limits", function()
            local cli = assert(descriptors.load("bee.driver.claude.descriptor:cli"))
            local fields = assert(bounds.object(cli.options.fields))
            fields.rights = {type = "ids", default = {"read"}}
            fields.denies = {type = "ids", default = {}}
            fields.limit = {value_schema = {type = "integer", minimum = 1}, default = 10}
            local policy = {option_constraints = {rights = {rights = {"read"}}, denies = {denies = {"network"}}, limit = {maximum = 4}}}
            local compiled = assert(effective.compile(cli, policy, nil, {rights = {"read"}, denies = {"write"}, limit = 8}))
            test.eq(compiled.values.limit, 4)
            local denies = assert(bounds.ids(compiled.values.denies, true))
            test.not_nil(bounds.member("network", denies)); test.not_nil(bounds.member("write", denies))
            test.is_nil(effective.compile(cli, policy, nil, {rights = {"read", "write"}}))
            test.is_nil(effective.compile(cli, {option_constraints = {missing = {maximum = 1}}}, nil, {}))
        end)
        test.it("compiles gateway subsets and appended instruction constraints", function()
            local cli = assert(descriptors.load("bee.driver.claude.descriptor:cli"))
            local policy = {gateway_tools = {"read", "write"}, instructions = "Host", profile_instructions = true}
            local selected = assert(effective.decode({mcp_tools = {"read"}, instructions = "Saved"}))
            local compiled = assert(effective.compile(cli, policy, nil, {}, nil, selected))
            test.eq(#compiled.gateway_tools, 1)
            test.eq(compiled.instructions, "Host\n\nSaved")
            selected.mcp_tools = {"outside"}
            test.is_nil(effective.compile(cli, policy, nil, {}, nil, selected))
            selected.mcp_tools = {}
            policy.profile_instructions = false
            test.is_nil(effective.compile(cli, policy, nil, {}, nil, selected))
        end)
        test.it("applies instruction option locks through saved profile admission", function()
            local cli = assert(descriptors.load("bee.driver.claude.descriptor:cli"))
            local policy = {profile_instructions = true, option_constraints = {system_prompt_append = {locked = true, reason = "Host-controlled prompt"}}}
            test.is_nil(effective.apply(policy, {instructions = "Saved instructions"}, cli))
        end)
        test.it("validates constrained limits and reports their effective default source", function()
            local cli = assert(descriptors.load("bee.driver.claude.descriptor:cli"))
            local fields = assert(bounds.object(cli.options.fields))
            fields.limit = {value_schema = {type = "integer", minimum = 1}, default = 10}
            local compiled = assert(effective.compile(cli, {option_constraints = {limit = {maximum = 4}}}))
            test.eq(compiled.fields.limit.default, 4)
            test.eq(compiled.fields.limit.default_source, "host ceiling")
            test.is_nil(effective.compile(cli, {option_constraints = {limit = {maximum = 0}}}))
        end)
        test.it("enforces ceilings on imported config and resume values", function()
            local claude = assert(descriptors.load("bee.driver.claude.descriptor:cli"))
            local policy = {profile_restrictions = {["provider.permission_mode"] = {kind = "declared"}}}
            test.not_nil(effective.check_config(claude, policy, ".claude/settings.json", '{"permissions":{"defaultMode":"bypassPermissions"}}'))
            test.is_nil(effective.check_config(claude, policy, ".claude/settings.json", '{"permissions":{"defaultMode":"manual"}}'))
            local codex = assert(descriptors.load("bee.driver.codex.descriptor:cli"))
            test.not_nil(effective.check_config(codex, {}, ".codex/config.toml", 'sandbox_mode = "danger-full-access"'))
            test.is_nil(effective.check_config(codex, {}, ".codex/config.toml", 'sandbox_mode = "read-only"'))
            local invalid = effective.compile(codex, nil, nil, {sandbox = "danger-full-access", resume_ref = "existing-session"})
            test.is_nil(invalid)
            local env = effective.compile(claude, nil, nil, {env = {CLAUDE_CONFIG_DIR = "/outside"}})
            test.is_nil(env)
        end)
        test.it("uses installed Claude modes and the full Muse effort set", function()
            local claude = assert(descriptors.load("bee.driver.claude.descriptor:cli"))
            local fields = assert(bounds.object(claude.options.fields))
            local permission = assert(bounds.object(fields.permission_mode))
            test.eq(permission.default, "manual")
            for _, value in ipairs({"manual", "acceptEdits", "auto", "dontAsk", "plan", "bypassPermissions"}) do
                local _, err = descriptors.decode_option("permission_mode", permission, value)
                test.is_nil(err)
            end
            local muse = assert(descriptors.load("bee.driver.muse.descriptor:cli"))
            local effort = assert(bounds.object(assert(bounds.object(muse.options.fields)).effort))
            for _, value in ipairs({"none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"}) do
                local _, err = descriptors.decode_option("effort", effort, value)
                test.is_nil(err)
            end
        end)
    end)
end
return test.run_cases(define_tests)
