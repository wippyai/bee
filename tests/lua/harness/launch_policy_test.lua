-- MIT. Policy launch behaviour.
local test = require("test")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local admission = require("admission")
local definitions = require("definitions")
local launch_policy = require("launch_policy")
local bounds = require("bounds")
local fixture = require("fixture")
local REQUESTER = fixture.REQUESTER
local DEFINITION = fixture.DEFINITION
local EMPTY_DEFINITION = fixture.EMPTY_DEFINITION
local fresh = fixture.fresh
local workspace_id = fixture.workspace_id
local call = fixture.call
local call_setup = fixture.call_setup
local value = fixture.value
local code = fixture.code
local setup = fixture.setup
local associations = fixture.associations
local function define_tests()
    test.describe("Launch policy", function()
        local workspace = fixture.prepare()
        test.it("rejects an unauthorized caller, private backend calls and unknown definitions", function()
            local plan = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION}))
            local no_setup, no_setup_error = funcs.new():with_actor(security.new_actor("bee.test.setup.denied")):with_scope(security.new_scope({})):call("bee.harness.binding:setup",
                {workspace_id = fresh("setup-denied"), definition_ref = DEFINITION, expected_plan_digest = plan.plan_digest})
            test.is_true(no_setup_error ~= nil or (type(no_setup) == "table" and no_setup.ok == false))
            local call_only = assert(security.policy("bee.tests.harness:setup_call_only_policy"))
            local denied_workspace = fresh("setup-operation-denied")
            local denied, denied_error = funcs.new():with_actor(principals.actor(REQUESTER, denied_workspace)):with_scope(security.new_scope({call_only})):call("bee.harness.binding:setup",
                {workspace_id = denied_workspace, definition_ref = DEFINITION, expected_plan_digest = plan.plan_digest})
            test.is_nil(denied_error)
            test.is_true(type(denied) == "table")
            if type(denied) ~= "table" then error("missing denied setup reply") end
            test.eq(denied.ok, false)
            test.eq(denied.error, "setup is not authorized")
            test.eq(#associations(denied_workspace), 0)
            local policy, policy_error = security.policy("bee.tests.harness:setup_client_policy")
            if policy_error or not policy then error(tostring(policy_error)) end
            local private_workspace = fresh("setup-private")
            local private_reply, private_error = funcs.new():with_actor(principals.actor(REQUESTER, private_workspace)):with_scope(security.new_scope({policy})):call("bee.harness.binding:setup_backend",
                {workspace_id = private_workspace, definition_ref = DEFINITION, expected_plan_digest = plan.plan_digest})
            test.is_true(private_error ~= nil or (type(private_reply) == "table" and private_reply.ok == false))
            local unknown = call_setup({workspace_id = fresh("setup-unknown"), definition_ref = "bee.harness.catalog:missing",
                expected_plan_digest = plan.plan_digest})
            test.is_false((unknown).ok == true)
            local empty = setup(fresh("setup-empty"), EMPTY_DEFINITION)
            test.is_true(empty.ok == true)
            test.eq(#(principals.items(empty.resources)), 0)
        end)
        test.it("decodes an empty window prompt but refuses it for a resolved structured launch", function()
            local request = {request_id = fresh("request"), definition_ref = DEFINITION, workspace_id = fresh("workspace"), brief = ""}
            local decoded, decode_error = admission.decode_request(request)
            if not decoded then error(tostring(decode_error)) end
            test.eq(decoded.brief, "")
            local reply = call("bee.tests.harness.admission:admit", request)
            test.eq(code(reply), "INVALID")
            test.eq(reply.error and reply.error.message, "a structured launch needs a nonempty brief")
        end)
        test.it("accepts only a complete bounded origin view in launch requests", function()
            local base = {request_id = fresh("origin-request"), definition_ref = DEFINITION, workspace_id = fresh("origin-workspace"), brief = ""}
            local valid = {}
            for key, item in pairs(base) do valid[key] = item end
            valid.origin_view = {view_id = "view-origin", instance_id = "instance-origin"}
            local decoded, decode_error = admission.decode_request(valid)
            if not decoded then error(tostring(decode_error)) end
            test.eq(decoded.origin_view and decoded.origin_view.view_id, "view-origin")
            test.eq(decoded.origin_view and decoded.origin_view.instance_id, "instance-origin")

            local malformed = {
                {view_id = "view-origin"},
                {instance_id = "instance-origin"},
                {view_id = "view-origin", instance_id = "instance-origin", extra = true},
                "view-origin",
            }
            for _, origin_view in ipairs(malformed) do
                local request = {}
                for key, item in pairs(base) do request[key] = item end
                request.origin_view = origin_view
                local _, invalid = admission.decode_request(request)
                test.eq(invalid == nil, false)
            end
        end)
        test.it("pins explicit machine-login projections for Docker windows", function()
            for _, provider in ipairs({"claude", "codex", "agy", "muse", "grok", "opencode"}) do
                local ref = "bee.driver." .. provider .. ".profiles:default_window"
                local entry = assert(registry.get(ref))
                local decoded = assert(definitions.decode(ref, entry))
                test.not_nil(decoded.docker_credentials)
                local found = false
                for _, name in ipairs(decoded.docker_credentials or {}) do
                    if name == provider .. "_login" then found = true end
                end
                test.is_true(found)
            end
            local entry = assert(registry.get("bee.driver.claude.profiles:default_window"))
            local changed = {data = {}}
            for name, value in pairs(entry.data) do changed.data[name] = value end
            changed.data.docker_credentials = {false}
            local invalid, err = definitions.decode("bee.driver.claude.profiles:default_window", changed)
            test.is_nil(invalid)
            test.not_nil(err)
        end)
        test.it("ships hidden research routes without harness turn ceilings", function()
            local cases = {
                {definition = "bee.driver.codex.profiles:research_batch", policy = "bee.driver.codex.security:launch_policy_codex_batch",
                    binding = "bee.driver.codex.binding:binding", credential = "codex_login", executable = "bee.driver.codex.env:executable",
                    config = "bee.driver.codex.env:config_home", option = "sandbox", expected = "workspace-write"},
                {definition = "bee.driver.claude.profiles:research_batch", policy = "bee.driver.claude.security:launch_policy_claude_batch",
                    binding = "bee.driver.claude.binding:binding", credential = "claude_api_key", executable = "bee.driver.claude.env:executable",
                    config = "bee.driver.claude.env:config_home", option = "permission_mode", expected = "manual"},
                {definition = "bee.driver.agy.profiles:research_batch", policy = "bee.driver.agy.security:launch_policy_agy_batch",
                    binding = "bee.driver.agy.binding:binding", credential = "agy_login", executable = "bee.driver.agy.env:executable",
                    option = "model", expected = "gemini-3.8-flash", additional_options = {effort = "high"}},
                {definition = "bee.driver.muse.profiles:research_batch", policy = "bee.driver.muse.security:launch_policy_muse_batch",
                    binding = "bee.driver.muse.binding:binding", credential = "muse_login", executable = "bee.driver.muse.env:executable",
                    option = "approval_mode", expected = "on-request"},
                {definition = "bee.driver.opencode.profiles:research_batch", policy = "bee.driver.opencode.security:launch_policy_opencode_batch",
                    binding = "bee.driver.opencode.binding:binding", credential = "opencode_login", executable = "bee.driver.opencode.env:executable", unconfined = true},
                {definition = "bee.driver.grok.profiles:research_batch", policy = "bee.driver.grok.security:launch_policy_grok_batch",
                    binding = "bee.driver.grok.binding:binding", credential = "grok_login", executable = "bee.driver.grok.env:executable",
                    option = "permission_mode", expected = "default", unconfined = true},
            }
            for _, selected in ipairs(cases) do
                local entry = assert(registry.get(selected.definition))
                local decoded, definition_error = definitions.decode(selected.definition, entry)
                if not decoded then error(tostring(definition_error)) end
                test.eq(decoded.binding_ref, selected.binding)
                test.eq(decoded.profile_id, "batch")
                test.eq(decoded.default_mode, "batch")
                test.eq(decoded.thread_policy.kind, "caller")
                test.eq(decoded.allowed_overrides[1], "thread")
                test.eq(decoded.allowed_overrides[2], "workdir")
                test.eq(#decoded.allowed_overrides, 2)
                if selected.credential then test.eq(decoded.credentials[1], selected.credential)
                else test.eq(#decoded.credentials, 0) end
                test.is_false(decoded.presentation.start_menu)
                if selected.unconfined then test.is_true(decoded.unconfined)
                else test.is_false(decoded.unconfined) end
                local policy_entry = assert(registry.get(selected.policy))
                local policy, policy_error = launch_policy.decode(selected.policy, policy_entry,
                    function(ref: string): (string?, string?)
                        if ref == selected.executable then return "/usr/bin/research-agent", nil end
                        if selected.config and ref == selected.config then return "", nil end
                        return nil, "unadmitted environment reference"
                    end)
                if not policy then error(tostring(policy_error)) end
                if selected.option then test.eq(policy.prepare_options[selected.option], selected.expected)
                else test.eq(next(policy.prepare_options or {}), nil) end
                test.is_nil(policy.prepare_options.turn_budget)
                test.is_nil(policy.prepare_options.max_turns)
                test.is_nil(policy.prepare_options.max_steps)
                test.is_nil(policy.prepare_options.print_timeout)
                test.eq(table.concat(policy.allowed_overrides, ","), "thread,workdir")
                for option, expected in pairs(selected.additional_options or {}) do
                    test.eq(policy.prepare_options[option], expected)
                end
                -- Every orchestrator-launched worker runs without host HOME
                -- inheritance and without a prompt-free permission mode: the
                -- person chose no host home for these routes.
                test.is_false(policy.allow_host_home)
                for name, item in pairs(policy.prepare_options) do
                    if type(item) == "string" then
                        test.is_true(item ~= "dontAsk" and item ~= "bypassPermissions" and item ~= "never",
                            selected.policy .. "." .. name .. " admits a prompt-free mode")
                    end
                end
                if selected.binding == "bee.driver.agy.binding:binding" then
                    test.eq(table.concat(policy.gateway_hooks, ","), "PermissionRequest")
                    test.eq(policy.prepare_options.sandbox, true)
                    local has_thread_message = false
                    for _, tool in ipairs(policy.gateway_tools) do if tool == "thread_message" then has_thread_message = true end end
                    test.is_true(has_thread_message)
                end
                local retained_tools = {
                    profile_get = true, profile_list = true, profile_put = true,
                    session_catalog = true, session_open = true, session_run = true, session_send = true,
                    session_await = true, session_join = true, session_get = true, session_list = true,
                    session_cancel = true, session_close = true, thread_read = true, thread_message = true, question = true,
                }
                local seen_tools: {[string]: boolean} = {}
                for _, tool in ipairs(policy.gateway_tools) do
                    test.is_true(retained_tools[tool] == true, selected.policy .. " admits removed tool " .. tool)
                    test.is_false(seen_tools[tool] == true, selected.policy .. " repeats tool " .. tool)
                    seen_tools[tool] = true
                end
                test.eq(#policy.gateway_tools, 16)
                for tool in pairs(retained_tools) do test.is_true(seen_tools[tool] == true, selected.policy .. " omits " .. tool) end
            end
        end)
        test.it("keeps the named Codex profile policy bounded", function()
            -- The named Codex route projects the selected config profile
            -- into its private home while gaining the workspace-write CLI
            -- sandbox.
            local named_entry = assert(registry.get("bee.driver.codex.security:launch_policy_codex_named_batch"))
            local named, named_error = launch_policy.decode("bee.driver.codex.security:launch_policy_codex_named_batch", named_entry,
                function(ref: string): (string?, string?)
                    if ref == "bee.driver.codex.env:executable" then return "/usr/bin/named-agent", nil end
                    if ref == "bee.driver.codex.env:config_home" then return "/work/person/.codex", nil end
                    return nil, "unadmitted environment reference"
                end)
            if not named then error(tostring(named_error)) end
            test.is_false(named.allow_host_home)
            test.eq(named.prepare_options.sandbox, "workspace-write")
        end)
        test.it("ships every driver route with thread and workdir overrides its host policy admits, and no placement override", function()
            local shipped = {
                {"bee.driver.claude.profiles:default_window", "bee.driver.claude.security:launch_policy_claude_window"}, {"bee.driver.claude.profiles:research_batch", "bee.driver.claude.security:launch_policy_claude_batch"},
                {"bee.driver.codex.profiles:default_window", "bee.driver.codex.security:launch_policy_codex_window"}, {"bee.driver.codex.profiles:research_batch", "bee.driver.codex.security:launch_policy_codex_batch"},
                {"bee.driver.codex.profiles:named_batch", "bee.driver.codex.security:launch_policy_codex_named_batch"},
                {"bee.driver.muse.profiles:default_window", "bee.driver.muse.security:launch_policy_muse_window"}, {"bee.driver.muse.profiles:research_batch", "bee.driver.muse.security:launch_policy_muse_batch"},
                {"bee.driver.agy.profiles:default_window", "bee.driver.agy.security:launch_policy_agy_window"}, {"bee.driver.agy.profiles:research_batch", "bee.driver.agy.security:launch_policy_agy_batch"},
                {"bee.driver.grok.profiles:default_window", "bee.driver.grok.security:launch_policy_grok_window"}, {"bee.driver.grok.profiles:research_batch", "bee.driver.grok.security:launch_policy_grok_batch"},
                {"bee.driver.opencode.profiles:default_window", "bee.driver.opencode.security:launch_policy_opencode_window"}, {"bee.driver.opencode.profiles:research_batch", "bee.driver.opencode.security:launch_policy_opencode_batch"},
            }
            for _, pair in ipairs(shipped) do
                local decoded, definition_error = definitions.decode(pair[1], assert(registry.get(pair[1])))
                if not decoded then error(tostring(definition_error)) end
                test.is_true(definitions.allows(decoded, "workdir"), pair[1] .. " allows no workdir override")
                test.is_true(definitions.allows(decoded, "thread"), pair[1] .. " allows no thread override")
                test.is_false(definitions.allows(decoded, "placement"), pair[1] .. " allows a placement override")
                local data = assert(bounds.object(assert(registry.get(pair[2])).data))
                test.eq(table.concat(principals.strings(data.allowed_overrides), ","), "thread,workdir", pair[2] .. " admits other overrides")
            end
        end)
        fixture.restore_host()
    end)
end
return test.run_cases(define_tests)
