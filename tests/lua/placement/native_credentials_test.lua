-- MIT. Native placement credentials regressions.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local sql = require("sql")
local process = require("process")
local runner_fixture = require("runner_fixture")
local channel = require("channel")
local time = require("time")
local registry = require("registry")
local json = require("json")
local service = require("service")
local grok_configuration = require("grok_configuration")
local hash = require("hash")
local store = require("store")
local resources = require("resources")
local protocol = require("protocol")
local homes = require("homes")
local quote = require("quote")
local types = require("types")
local native_fixture = require("native_fixture")
type PreparedConfiguration = {environment: {[string]: string}, working_directory: string, arguments: {string}}

local function credentials_tests()
    test.describe("Native placement credentials", function()
        local measured = native_fixture.value(service.capabilities())
        local capability = tostring(measured.capability)
        local observation = tostring(measured.exit_observation)
        test.it("refuses authority in a named Codex configuration copied by login initialization", function()
            local source = "bee.credentials:codex_login_fixture"
            native_fixture.admit_login_source(source, true)
            local root = ".wippy/codex-login-fixture/.codex"
            native_fixture.shell("mkdir -p " .. quote.posix(root))
            native_fixture.shell("printf %s " .. quote.posix('{}') .. " > " .. quote.posix(root .. "/auth.json"))
            native_fixture.shell("printf %s " .. quote.posix('[history]\npersistence="save-all"') .. " > " .. quote.posix(root .. "/config.toml"))
            native_fixture.shell("printf %s " .. quote.posix('[sandbox_workspace_write]\nnetwork_access=true') .. " > " .. quote.posix(root .. "/ds-flash.config.toml"))
            local workspace = native_fixture.fresh("named-config")
            native_fixture.credential_call("define", {workspace_id = workspace, name = "login", provider = "codex", source = {kind = "fs_directory", ref = source}})
            local attempt = native_fixture.fresh("named-config-attempt")
            local projection = native_fixture.credential_call("issue_projection", {workspace_id = workspace, name = "login", audience = native_fixture.OWNER,
                attempt_id = attempt, profile_id = "batch", profile_digest = native_fixture.DIGEST, binding_digest = native_fixture.DIGEST,
                launch_policy_digest = native_fixture.DIGEST, idempotency_key = native_fixture.fresh("projection")})
            local request = native_fixture.launch({"sh", "-c", "exit 0"}, "direct_process")
            request.attempt_id, request.projections = attempt, {projection.projection_id}
            request.binding_ref, request.policy_ref = "bee.driver.codex.binding:binding", native_fixture.NO_PROVIDER_POLICY
            request.configuration_digest = nil
            local launch = assert(bounds.object(request.launch))
            launch.provider_home = {provider = "codex", private = true, variable = "CODEX_HOME", directory = ".codex", files = {
                {source_path = ".codex/auth.json", path = ".codex/auth.json", kind = "login", optional = true, write_back = true},
                {source_path = ".codex/config.toml", path = ".codex/config.toml", kind = "config", optional = true, write_back = false},
                {source_path = ".codex/ds-flash.config.toml", path = ".codex/ds-flash.config.toml", kind = "config", optional = false, write_back = false}}}
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local started = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = attempt}))
            test.not_nil(started.start_failure)
            assert(tostring(started.start_failure):find("sandbox_workspace_write.network_access", 1, true), tostring(started.start_failure))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = attempt}))
        end)
        test.it("injects a custom provider credential only into the child environment", function()
            local workspace, attempt = native_fixture.fresh("custom-key-workspace"), native_fixture.fresh("custom-key-attempt")
            local secret = "custom-child-fixture-value-42b9"
            native_fixture.credential_call("define", {workspace_id = workspace, name = "custom", provider = "local_endpoint",
                source = {kind = "env_variable", ref = "bee.credentials:custom_key"}})
            native_fixture.credential_call("set_value", {workspace_id = workspace, name = "custom", value = secret})
            local projection = native_fixture.credential_call("issue_projection", {workspace_id = workspace, name = "custom",
                audience = native_fixture.OWNER, attempt_id = attempt, profile_id = "batch", profile_digest = native_fixture.DIGEST,
                binding_digest = native_fixture.DIGEST, launch_policy_digest = native_fixture.DIGEST, idempotency_key = native_fixture.fresh("custom-key")})
            local digest = assert(hash.sha256(secret))
            local request = native_fixture.launch({"sh", "-c", 'digest=$(printf %s "$LOCAL_ENDPOINT_API_KEY" | sha256sum); test "${digest%% *}" = ' .. quote.posix(digest)}, "direct_process")
            request.attempt_id, request.projections = attempt, {projection.projection_id}
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = attempt}))
            test.is_true(native_fixture.wait_for(function()
                local status = native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = attempt}))
                return assert(bounds.object(status.attempt)).execution_state == "exited"
            end, 8000))
            local completed = assert(bounds.object(native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = attempt})).attempt))
            test.eq(assert(bounds.object(completed.exit)).code, 0)
            local db = assert(store.open())
            local row = assert(store.row(db, attempt))
            local page = assert(store.evidence(db, attempt, 0, 64))
            db:release()
            test.is_true(not assert(json.encode({row, page})):find(secret, 1, true))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = attempt}))
        end)
        test.it("refuses file credentials before intent without a selected retained home", function()
            local source = "bee.credentials:codex_login_fixture"
            native_fixture.admit_login_source(source)
            local workspace = native_fixture.fresh("ws")
            native_fixture.credential_call("define", {workspace_id = workspace, name = "login", provider = "codex", source = {kind = "fs_directory", ref = source}})
            local attempt_id = native_fixture.fresh("attempt")
            local projection = native_fixture.credential_call("issue_projection", {workspace_id = workspace, name = "login", audience = native_fixture.OWNER, attempt_id = attempt_id, profile_id = "batch",
                profile_digest = native_fixture.DIGEST, binding_digest = native_fixture.DIGEST, launch_policy_digest = native_fixture.DIGEST, idempotency_key = native_fixture.fresh("key")})
            local request = native_fixture.launch({"sh", "-c", "exit 0"}, "direct_process")
            request.attempt_id = attempt_id
            request.projections = {projection.projection_id}
            local refused = native_fixture.call(native_fixture.OWNER, "prepare", request)
            test.is_false(refused.ok)
            test.eq(refused.error.code, "DENIED")
            local absent = native_fixture.call(native_fixture.OWNER, "status", {attempt_id = attempt_id})
            test.is_false(absent.ok)
            test.eq(absent.error.code, "NOT_FOUND")
        end)
        test.it("runs a confined fixture worker with only its projected Codex home and writes its refreshed token back", function()
            local source = "bee.credentials:codex_login_fixture"
            local source_root = ".wippy/codex-login-fixture"
            native_fixture.admit_login_source(source, true)
            local original_login = '{"fixture":"ambient-login"}'
            local refreshed_login = '{"fixture":"ambient-refresh"}'
            test.eq(native_fixture.shell("mkdir -p " .. source_root .. "/.codex && printf %s " .. quote.posix(original_login) .. " > " .. source_root .. "/.codex/auth.json"
                .. " && printf %s " .. quote.posix("profile = \"fixture\"\n") .. " > " .. source_root .. "/.codex/config.toml"
                .. " && printf %s " .. quote.posix("model = \"gpt-5-codex\"\n") .. " > " .. source_root .. "/.codex/ds-flash.config.toml"
                .. " && printf %s " .. quote.posix("must-not-be-projected") .. " > " .. source_root .. "/machine-home-only.txt"), "")
            local workspace = native_fixture.fresh("private-provider-home-workspace")
            native_fixture.credential_call("define", {workspace_id = workspace, name = "codex_ambient", provider = "codex", source = {kind = "fs_directory", ref = source}})
            local attempt_id = native_fixture.fresh("private-provider-home-attempt")
            local projection = native_fixture.credential_call("issue_projection", {workspace_id = workspace, name = "codex_ambient", audience = native_fixture.OWNER,
                attempt_id = attempt_id, profile_id = "batch", profile_digest = native_fixture.DIGEST, binding_digest = native_fixture.DIGEST,
                launch_policy_digest = native_fixture.DIGEST, idempotency_key = native_fixture.fresh("private-provider-home-key")})
            local script = 'case "$HOME" in */attempts/*/home) ;; *) exit 41;; esac'
                .. ' && test -s "$CODEX_HOME/auth.json" && test -s "$CODEX_HOME/config.toml"'
                .. ' && test -s "$CODEX_HOME/ds-flash.config.toml" && test ! -e "$HOME/.codex/other-profile.config.toml"'
                .. ' && test ! -e "$HOME/machine-home-only.txt"'
                .. ' && printf projected-fixture-ok && printf %s ' .. quote.posix(refreshed_login) .. ' > "$CODEX_HOME/auth.json"'
            local request = native_fixture.launch({"sh", "-c", script}, "process_group")
            request.attempt_id = attempt_id
            request.projections = {projection.projection_id}
            local declared_launch = assert(bounds.object(request.launch))
            declared_launch.provider_home = {provider = "codex", private = true, variable = "CODEX_HOME", directory = ".codex",
                files = {{source_path = ".codex/auth.json", path = ".codex/auth.json", kind = "login", optional = true, write_back = true},
                    {source_path = ".codex/config.toml", path = ".codex/config.toml", kind = "config", optional = true, write_back = false},
                    {source_path = ".codex/ds-flash.config.toml", path = ".codex/ds-flash.config.toml", kind = "config", optional = false, write_back = false}}}
            local request_resources = principals.objects(request.resources)
            request.resources = request_resources
            request_resources[#request_resources + 1] = {name = "session", grant_ref = "provider-session-grant", root_ref = native_fixture.ROOT,
                subpath = "", access = "write", purpose = "session"}
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = attempt_id, recipient = process.pid(), generation = 1}))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = attempt_id}))
            local output = ""
            local ended: {[string]: boolean} = {}
            local deadline = time.after("10s")
            while not ended.stdout or not ended.stderr do
                local selected = channel.select({outputs:case_receive(), deadline:case_receive()})
                if not selected.ok or selected.channel == deadline then error("fixture provider-home worker did not report success") end
                local data = selected.value:payload():data()
                if data.attempt_id == attempt_id and data.generation == 1 then
                    if type(data.data) == "string" then output = output .. (data.data) end
                    if data.eof then ended[data.stream] = true end
                    process.send(tostring(selected.value:from()), protocol.TOPIC_ACK,
                        {generation = 1, consumed_through = data.sequence})
                end
            end
            process.unlisten(outputs)
            if not output:find("projected-fixture-ok", 1, true) then error("fixture provider-home worker output: " .. output) end
            if not native_fixture.wait_for(function()
                local observed = native_fixture.kinds(attempt_id)
                return native_fixture.has(observed, "credential.write_back") or native_fixture.has(observed, "credential.write_back_failed")
            end, 8000) then error("refreshed fixture login write-back did not settle") end
            test.eq(native_fixture.shell("test \"$(cat " .. quote.posix(source_root .. "/.codex/auth.json") .. ")\" = "
                .. quote.posix(original_login) .. " && printf unchanged"), "unchanged")
            local page = native_fixture.value(native_fixture.call(native_fixture.OWNER, "evidence", {attempt_id = attempt_id, limit = 64}))
            local write_back_refused = false
            for _, item in ipairs(principals.objects(page.evidence)) do
                test.is_nil((tostring(item.detail):find("ambient-refresh", 1, true)))
                if item.kind == "credential.write_back" then error("fixture login unexpectedly wrote back") end
                if item.kind == "credential.write_back_failed" then
                    test.is_true(tostring(item.detail):find("provider login write-back requires runtime no-follow fs", 1, true) ~= nil)
                    write_back_refused = true
                end
            end
            if not write_back_refused then error("fixture token write-back refusal evidence was missing") end
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = attempt_id}))

            test.eq(native_fixture.shell("printf %s " .. quote.posix(original_login) .. " > " .. source_root .. "/.codex/auth.json"), "")
            local unsafe_attempt = native_fixture.fresh("private-provider-descendant")
            local unsafe_projection = native_fixture.credential_call("issue_projection", {workspace_id = workspace, name = "codex_ambient", audience = native_fixture.OWNER,
                attempt_id = unsafe_attempt, profile_id = "batch", profile_digest = native_fixture.DIGEST, binding_digest = native_fixture.DIGEST,
                launch_policy_digest = native_fixture.DIGEST, idempotency_key = native_fixture.fresh("private-provider-descendant-key")})
            local unsafe_request = native_fixture.launch({"sh", "-c", "printf %s " .. quote.posix(refreshed_login)
                .. " > \"$CODEX_HOME/auth.json\"; (sleep 2) >/dev/null 2>&1 &"}, "direct_process")
            unsafe_request.attempt_id = unsafe_attempt
            unsafe_request.projections = {unsafe_projection.projection_id}
            (assert(bounds.object(unsafe_request.timeouts))).retain_ms = 100
            (assert(bounds.object(unsafe_request.launch))).provider_home = declared_launch.provider_home
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", unsafe_request))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = unsafe_attempt}))
            if not native_fixture.wait_for(function()
                local observed = native_fixture.kinds(unsafe_attempt)
                return native_fixture.has(observed, "credential.write_back") or native_fixture.has(observed, "credential.write_back_failed")
            end, 8000) then error("descendant write-back refusal did not settle: " .. table.concat(native_fixture.kinds(unsafe_attempt), ",")) end
            test.is_true(native_fixture.has(native_fixture.kinds(unsafe_attempt), "credential.write_back_failed"))
            test.eq(native_fixture.shell("test \"$(cat " .. quote.posix(source_root .. "/.codex/auth.json") .. ")\" = "
                .. quote.posix(original_login) .. " && printf unchanged"), "unchanged")
            time.sleep("2200ms")
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = unsafe_attempt}))
        end)
        test.it("starts with an absent optional machine login and permits private CLI sign-in", function()
            local source = "bee.credentials:codex_login_fixture"
            native_fixture.admit_login_source(source)
            test.eq(native_fixture.shell("mkdir -p .wippy/codex-login-fixture && rm -f .wippy/codex-login-fixture/auth.json"), "")
            local workspace = native_fixture.fresh("optional-login-workspace")
            native_fixture.credential_call("define", {workspace_id = workspace, name = "login", provider = "codex",
                source = {kind = "fs_directory", ref = source}, optional = true})
            local session_ref = native_fixture.fresh("optional-login-session")
            local request = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "optional-login")
            local attempt_id = request.attempt_id
            local projection = native_fixture.credential_call("issue_projection", {workspace_id = workspace, name = "login", audience = native_fixture.OWNER,
                attempt_id = attempt_id, profile_id = "batch", profile_digest = native_fixture.DIGEST, binding_digest = native_fixture.DIGEST,
                launch_policy_digest = native_fixture.DIGEST, idempotency_key = native_fixture.fresh("optional-login-key")})
            request.projections = {projection.projection_id}
            local launch_value = assert(bounds.object(request.launch))
            launch_value.argv = {"-c", 'test ! -e "$HOME/.codex/auth.json" && printf private-login > "$HOME/.codex/auth.json"'}
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = attempt_id}))
            if not native_fixture.wait_for(function()
                return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = attempt_id})).attempt).execution_state == "exited"
            end, 8000) then error("optional login probe did not exit") end
            local exited = (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = attempt_id})).attempt).exit
            if not exited then error("optional login probe has no exit receipt") end
            test.eq(exited.code, 0)
            local session_key = assert(homes.session_key(native_fixture.OWNER, session_ref))
            local session_path = assert(homes.ensure_session(session_key))
            local home = assert(homes.os_path(session_path .. "/home"))
            test.eq(native_fixture.shell("cat " .. home .. "/.codex/auth.json"), "private-login")
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = attempt_id}))
        end)
        test.it("delivers one retained Codex login before provider configuration and preserves a refreshed login", function()
            local source = "bee.credentials:codex_login_fixture"
            native_fixture.admit_login_source(source)
            test.eq(native_fixture.shell("mkdir -p .wippy/codex-login-fixture && printf '{\"fixture\":\"login\"}' > .wippy/codex-login-fixture/auth.json"), "")
            local workspace = native_fixture.fresh("login-workspace")
            native_fixture.credential_call("define", {workspace_id = workspace, name = "login", provider = "codex", source = {kind = "fs_directory", ref = source}})
            local session_ref = native_fixture.fresh("login-session")
            local function issue(attempt_id: string): {[string]: unknown}
                return native_fixture.credential_call("issue_projection", {workspace_id = workspace, name = "login", audience = native_fixture.OWNER, attempt_id = attempt_id, profile_id = "batch",
                    profile_digest = native_fixture.DIGEST, binding_digest = native_fixture.DIGEST, launch_policy_digest = native_fixture.DIGEST, idempotency_key = native_fixture.fresh("login-key")})
            end
            local first_request = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "first-login")
            local first_id = first_request.attempt_id
            local first_launch = assert(bounds.object(first_request.launch))
            -- Execute env directly. A shell can remove invalid names such as
            -- auth.json before its env builtin observes them.
            first_launch.executable = "/usr/bin/env"
            first_launch.argv = {}
            first_request.projections = {issue(first_id).projection_id}
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", first_request))
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = first_id, recipient = process.pid(), generation = 1}))
            local started = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = first_id}))
            local child_environment = ""
            local ended: {[string]: boolean} = {}
            local deadline = time.after("10s")
            while not ended.stdout or not ended.stderr do
                local selected = channel.select({outputs:case_receive(), deadline:case_receive()})
                if not selected.ok or selected.channel == deadline then
                    process.unlisten(outputs)
                    error("did not receive the complete raw child environment")
                end
                local data = selected.value:payload():data()
                if tostring(selected.value:from()) == started.runner and data.attempt_id == first_id and data.generation == 1 then
                    test.is_false(data.truncated == true)
                    if data.data then child_environment = child_environment .. tostring(data.data) end
                    if data.eof then ended[data.stream] = true end
                    process.send(tostring(selected.value:from()), protocol.TOPIC_ACK, {generation = 1, consumed_through = data.sequence})
                end
            end
            process.unlisten(outputs)
            if not native_fixture.wait_for(function()
                return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = first_id})).attempt).execution_state == "exited"
            end, 8000) then error("first retained login launch did not exit") end
            local first_exit = (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = first_id})).attempt).exit
            if not first_exit then error("environment probe has no exit receipt") end
            test.eq(first_exit.code, 0)
            test.not_nil((child_environment:find("PROBE_VALUE=probe-42\n", 1, true)))
            test.is_nil((child_environment:find('{"fixture":"login"}', 1, true)))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = first_id}))
            local session_key = assert(homes.session_key(native_fixture.OWNER, session_ref))
            local session_path = assert(homes.ensure_session(session_key))
            local home = assert(homes.os_path(session_path .. "/home"))
            test.eq(native_fixture.shell("test -f " .. home .. "/.codex/auth.json && test -f " .. home .. "/.codex/config.toml"), "")
            test.eq(native_fixture.shell("printf '{\"fixture\":\"refreshed\"}' > " .. home .. "/.codex/auth.json"), "")
            local second_request = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "second-login")
            local second_id = second_request.attempt_id
            second_request.projections = {issue(second_id).projection_id}
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", second_request))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = second_id}))
            if not native_fixture.wait_for(function()
                return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = second_id})).attempt).execution_state == "exited"
            end, 8000) then error("second retained login launch did not exit") end
            test.eq(native_fixture.shell("cat " .. home .. "/.codex/auth.json"), '{"fixture":"refreshed"}')
            local page = native_fixture.value(native_fixture.call(native_fixture.OWNER, "evidence", {attempt_id = second_id, limit = 64}))
            for _, item in ipairs(principals.objects(page.evidence)) do
                test.is_nil((tostring(item.detail):find("refreshed", 1, true)))
            end
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = second_id}))
            local changed_request = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "changed-login")
            local changed_id = changed_request.attempt_id
            native_fixture.credential_call("define", {workspace_id = workspace, name = "login", provider = "codex", source = {kind = "fs_directory", ref = source}})
            changed_request.projections = {issue(changed_id).projection_id}
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", changed_request))
            local refused = native_fixture.call(native_fixture.OWNER, "start", {attempt_id = changed_id})
            test.is_true(refused.ok)
            test.eq(native_fixture.attempt_of(refused).execution_state, "start_failed")
            test.is_true(native_fixture.has(native_fixture.kinds(changed_id), "credential.refused"))
            test.is_nil((native_fixture.shell("cat " .. home .. "/marker"):find("changed-login", 1, true)))
        end)
        test.it("composes Grok configuration only from the current admitted initializer", function()
            local source = "bee.credentials:codex_login_fixture"
            local source_root = ".wippy/codex-login-fixture"
            native_fixture.admit_grok_login_source(source)

            local function projection(attempt_id: string): ({[string]: unknown}, {[string]: unknown}, string)
                local workspace = native_fixture.fresh("grok-composition-workspace")
                local definition = native_fixture.credential_call("define", {workspace_id = workspace, name = "login", provider = "grok",
                    source = {kind = "fs_directory", ref = source}, optional = true})
                local issued = native_fixture.credential_call("issue_projection", {workspace_id = workspace, name = "login", audience = native_fixture.OWNER,
                    attempt_id = attempt_id, profile_id = "window", profile_digest = native_fixture.DIGEST, binding_digest = native_fixture.DIGEST,
                    launch_policy_digest = native_fixture.DIGEST, idempotency_key = native_fixture.fresh("grok-composition-projection")})
                return definition, issued, workspace
            end
            local function session_path(session_ref: string): (string, string)
                local key, key_error = homes.session_key(native_fixture.OWNER, session_ref)
                if not key then error(tostring(key_error or "Grok composition session key")) end
                local path, path_error = homes.ensure_session(key)
                if not path then error(tostring(path_error or "Grok composition session path")) end
                local os_home, os_error = homes.os_path(path .. "/home")
                if not os_home then error(tostring(os_error or "Grok composition OS home")) end
                return path, os_home
            end
            local function preseed(session_ref: string, definition: {[string]: unknown}, initialize: {unknown})
                local path = session_path(session_ref)
                if type(definition.definition_id) ~= "string" or type(definition.revision) ~= "number" then
                    error("Grok credential definition has invalid identity")
                end
                local target, seed_error = homes.retain_login(path, {provider = "grok",
                    definition_id = definition.definition_id, definition_revision = math.floor(definition.revision),
                    optional = true, format = {schema_revision = "bee.credential-format@1", file = {
                        path = ".grok/auth.json", content_format = "json", initialize = initialize}}}, nil, {})
                if not target then error(tostring(seed_error or "preseed Grok retained identity")) end
                local db, db_error = store.open()
                if not db then error(tostring(db_error or "open placement store for retained base binding")) end
                for _, raw in ipairs(initialize) do
                    local item = assert(bounds.object(raw))
                    local item_path, content = item.path, item.content
                    if type(item_path) ~= "string" or type(content) ~= "string" then error("invalid preseed initializer") end
                    local digest, digest_error = hash.sha256(content)
                    if not digest then error(tostring(digest_error or "digest preseed initializer")) end
                    local bind_error = store.bind_session_file(db, native_fixture.OWNER, session_ref, item_path, digest)
                    if bind_error then error(bind_error) end
                end
                db:release()
            end
            local function evidence_has_no_start_or_publication(db, attempt_id: string)
                local page, page_error = store.evidence(db, attempt_id, 0, 64)
                if not page then error(tostring(page_error or "read Grok composition evidence")) end
                for _, item in ipairs(page.evidence) do
                    test.is_true(item.kind ~= "child.started")
                    test.is_true(item.kind ~= "configuration.materialized")
                end
            end
            local function retire(db, attempt_id: string)
                local retired = store.transition(db, attempt_id, {execution = "exited",
                    fields = {runner_pid = sql.NULL, exit_source = "runner"},
                    evidence = {kind = "child.not_started", detail = "composition acceptance did not create a child"}})
                if not retired.ok then error(tostring(retired.message or "retire Grok composition attempt")) end
            end
            -- A hosted runner claims and prepares; a sweep inside its window
            -- finds it present and leaves the attempt starting.
            local function prepare(request: types.LaunchRequest, binding_failure: string?): (PreparedConfiguration?, string?, sql.DB)
                local db, db_error = store.open()
                if not db then error(tostring(db_error or "open placement store")) end
                native_fixture.intend_materialization(db, request)
                local runner = runner_fixture.claim("bee.placement.native:materialization_runner_process", request, 0, nil, binding_failure)
                test.is_true(service.sweep().ok)
                test.eq(assert(store.attempt(db, request.attempt_id)).execution_state, "starting")
                local outcome = runner_fixture.prepare(runner)
                runner_fixture.release(runner)
                return outcome.prepared, outcome.error, db
            end

            -- The external digest binding commits before any setup file or
            -- ready marker. A failed binding therefore leaves a retryable empty
            -- retained home instead of a permanently unbound ready session.
            test.eq(native_fixture.shell("mkdir -p " .. source_root .. "/.grok && printf 'crash_safe = true\\n' > " .. source_root .. "/.grok/config.toml"), "")
            local binding_attempt, binding_session = native_fixture.fresh("grok-binding-attempt"), native_fixture.fresh("grok-binding-session")
            local _, binding_projection = projection(binding_attempt)
            if type(binding_projection.projection_id) ~= "string" then error("invalid fixture binding_projection.projection_id") end
            local binding_request = native_fixture.grok_composition_request(binding_attempt, binding_session,
                binding_projection.projection_id, grok_configuration.BASE_PATH)
            local binding_prepared, binding_error, binding_db = prepare(binding_request, "injected retained configuration binding failure")
            if binding_prepared then error("Grok configuration survived a failed external binding") end
            test.eq(binding_error, "injected retained configuration binding failure")
            local _, binding_home = session_path(binding_session)
            test.eq(native_fixture.shell("test ! -e " .. quote.posix(binding_home .. "/.bee-retained-login-ready.json")
                .. " && test ! -e " .. quote.posix(binding_home .. "/.grok/.bee-global-config.toml") .. " && printf absent"), "absent")
            evidence_has_no_start_or_publication(binding_db, binding_attempt)
            retire(binding_db, binding_attempt)
            binding_db:release()
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = binding_attempt}))

            -- A retained file that exists beside the admitted base is not an
            -- authority source. Only the initializer path can be composed.
            test.eq(native_fixture.shell("mkdir -p " .. source_root .. "/.grok && rm -f " .. source_root .. "/auth.json " .. source_root .. "/.grok/config.toml"), "")
            local arbitrary_attempt, arbitrary_session = native_fixture.fresh("grok-arbitrary-attempt"), native_fixture.fresh("grok-arbitrary-session")
            local arbitrary_definition, arbitrary_projection = projection(arbitrary_attempt)
            preseed(arbitrary_session, arbitrary_definition, {{path = ".grok/.bee-global-config.toml", content = "", on_missing_login = true}})
            local _, arbitrary_home = session_path(arbitrary_session)
            test.eq(native_fixture.shell("printf 'untrusted = true\\n' > " .. quote.posix(arbitrary_home .. "/.grok/arbitrary.toml")), "")
            if type(arbitrary_projection.projection_id) ~= "string" then error("invalid fixture arbitrary_projection.projection_id") end
            local arbitrary_request = native_fixture.grok_composition_request(arbitrary_attempt, arbitrary_session,
                arbitrary_projection.projection_id, ".grok/arbitrary.toml")
            local arbitrary_prepared, arbitrary_error, arbitrary_db = prepare(arbitrary_request)
            if arbitrary_prepared then error("arbitrary retained Grok base was accepted") end
            test.eq(arbitrary_error, "Bee needs permission to use this profile's configuration file. Open Agents, choose Setup, then approve the request in Needs you.")
            evidence_has_no_start_or_publication(arbitrary_db, arbitrary_attempt)
            test.eq(native_fixture.shell("test ! -e " .. quote.posix(arbitrary_home .. "/.grok/config.toml") .. " && printf absent"), "absent")
            retire(arbitrary_db, arbitrary_attempt)
            arbitrary_db:release()
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = arbitrary_attempt}))

            -- A retained identity cannot turn a missing admitted base into an
            -- implicit empty document. Replay skips seeding and must refuse.
            local missing_attempt, missing_session = native_fixture.fresh("grok-missing-attempt"), native_fixture.fresh("grok-missing-session")
            local missing_definition, missing_projection = projection(missing_attempt)
            preseed(missing_session, missing_definition, {})
            local _, missing_home = session_path(missing_session)
            if type(missing_projection.projection_id) ~= "string" then error("invalid fixture missing_projection.projection_id") end
            local missing_request = native_fixture.grok_composition_request(missing_attempt, missing_session,
                missing_projection.projection_id, grok_configuration.BASE_PATH)
            local missing_prepared, missing_error, missing_db = prepare(missing_request)
            if missing_prepared then error("missing admitted Grok base was accepted") end
            test.eq(missing_error, "retained configuration binding is missing")
            evidence_has_no_start_or_publication(missing_db, missing_attempt)
            test.eq(native_fixture.shell("test ! -e " .. quote.posix(missing_home .. "/.grok/config.toml") .. " && printf absent"), "absent")
            retire(missing_db, missing_attempt)
            missing_db:release()
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = missing_attempt}))

            -- Structural insertion refuses a semantic Bee subtree already in
            -- the user's source, before publishing the final configuration.
            for _, collision in ipairs({
                "[mcp_servers.bee]\nurl = \"http://existing.invalid\"\n",
                "[mcp_servers]\nbee = { url = \"http://existing.invalid\" }\n",
                "mcp_servers.bee = { url = \"http://existing.invalid\" }\n",
                "[\"mcp_servers\".\"bee\"]\nurl = \"http://existing.invalid\"\n",
                "[mcp_servers.'bee']\nurl = \"http://existing.invalid\"\n",
            }) do
                test.eq(native_fixture.shell("printf %s " .. quote.posix(collision) .. " > " .. source_root .. "/.grok/config.toml"), "")
                local collision_attempt, collision_session = native_fixture.fresh("grok-collision-attempt"), native_fixture.fresh("grok-collision-session")
                local _, collision_projection = projection(collision_attempt)
                if type(collision_projection.projection_id) ~= "string" then error("invalid fixture collision_projection.projection_id") end
                local collision_request = native_fixture.grok_composition_request(collision_attempt, collision_session,
                    collision_projection.projection_id, grok_configuration.BASE_PATH)
                local collision_prepared, collision_error, collision_db = prepare(collision_request)
                if collision_prepared then error("colliding Grok MCP subtree was accepted") end
                test.is_true(tostring(collision_error):find("mcp_servers.bee", 1, true) ~= nil)
                test.is_true(tostring(collision_error):find("has no admitted mapping", 1, true) ~= nil)
                evidence_has_no_start_or_publication(collision_db, collision_attempt)
                local _, collision_home = session_path(collision_session)
                test.eq(native_fixture.shell("test ! -e " .. quote.posix(collision_home .. "/.grok/config.toml") .. " && printf absent"), "absent")
                retire(collision_db, collision_attempt)
                collision_db:release()
                native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = collision_attempt}))
            end

            -- An absent admitted source is an explicit empty base. It composes
            -- once, publishes once and preserves exactly one MCP allow pair.
            test.eq(native_fixture.shell("rm -f " .. source_root .. "/.grok/config.toml"), "")
            local empty_attempt, empty_session = native_fixture.fresh("grok-empty-attempt"), native_fixture.fresh("grok-empty-session")
            local _, empty_projection, empty_workspace = projection(empty_attempt)
            if type(empty_projection.projection_id) ~= "string" then error("invalid fixture empty_projection.projection_id") end
            local empty_request = native_fixture.grok_composition_request(empty_attempt, empty_session,
                empty_projection.projection_id, grok_configuration.BASE_PATH)
            local empty_prepared, empty_error, empty_db = prepare(empty_request)
            if not empty_prepared then error(tostring(empty_error or "compose admitted empty Grok base")) end
            test.eq(#empty_prepared.arguments, 2)
            test.eq(empty_prepared.arguments[1], "--allow")
            test.eq(empty_prepared.arguments[2], "MCPTool(bee__*)")
            local _, empty_home = session_path(empty_session)
            local final = native_fixture.shell("cat " .. quote.posix(empty_home .. "/.grok/config.toml"))
            local sections = 0
            for _ in final:gmatch("%[mcp_servers%.bee%]") do sections = sections + 1 end
            test.eq(sections, 1)
            test.is_true(final:find("http://127.0.0.1:4312/mcp/grok-placement", 1, true) ~= nil)
            retire(empty_db, empty_attempt)
            empty_db:release()
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = empty_attempt}))

            -- A later attempt may reuse only the exact bytes first admitted for
            -- this session. Provider-writable retained state is never authority
            -- to replace a composition base.
            test.eq(native_fixture.shell("printf 'changed = true\\n' > " .. quote.posix(empty_home .. "/.grok/.bee-global-config.toml")), "")
            local changed_attempt = native_fixture.fresh("grok-changed-base-attempt")
            local changed_projection = native_fixture.credential_call("issue_projection", {workspace_id = empty_workspace, name = "login", audience = native_fixture.OWNER,
                attempt_id = changed_attempt, profile_id = "window", profile_digest = native_fixture.DIGEST, binding_digest = native_fixture.DIGEST,
                launch_policy_digest = native_fixture.DIGEST, idempotency_key = native_fixture.fresh("grok-composition-projection")})
            if type(changed_projection.projection_id) ~= "string" then error("invalid fixture changed_projection.projection_id") end
            local changed_request = native_fixture.grok_composition_request(changed_attempt, empty_session,
                changed_projection.projection_id, grok_configuration.BASE_PATH)
            local changed_prepared, changed_error, changed_db = prepare(changed_request)
            if changed_prepared then error("changed retained Grok base was accepted") end
            test.eq(changed_error, "configuration base differs from admitted content. Open Agents and choose Setup to approve the current configuration file.")
            evidence_has_no_start_or_publication(changed_db, changed_attempt)
            retire(changed_db, changed_attempt)
            changed_db:release()
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = changed_attempt}))
        end)
        test.it("fences a retained login reply after the attempt is stopped during credential materialization", function()
            local source = "bee.credentials:codex_login_fixture"
            native_fixture.admit_login_source(source)
            local source_root = ".wippy/codex-login-fixture"
            test.eq(native_fixture.shell("mkdir -p " .. source_root .. " && rm -f " .. source_root .. "/auth.json && mkfifo " .. source_root .. "/auth.json"), "")
            local workspace = native_fixture.fresh("materialization-fence-workspace")
            native_fixture.credential_call("define", {workspace_id = workspace, name = "login", provider = "codex", source = {kind = "fs_directory", ref = source}})
            local session_ref = native_fixture.fresh("materialization-fence-session")
            local request = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "must-not-run")
            request.required_cleanup = "process_group"
            request.required_exit_observation = "independent"
            local attempt_id = request.attempt_id
            local projection = native_fixture.credential_call("issue_projection", {workspace_id = workspace, name = "login", audience = native_fixture.OWNER,
                attempt_id = attempt_id, profile_id = "batch", profile_digest = native_fixture.DIGEST, binding_digest = native_fixture.DIGEST,
                launch_policy_digest = native_fixture.DIGEST, idempotency_key = native_fixture.fresh("materialization-fence-key")})
            request.projections = {projection.projection_id}
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))

            -- The fixture writer's FIFO open returns only after the real
            -- broker has opened its reader; it then stops the runner before
            -- releasing a valid file projection reply.
            local fixture, fixture_error = native_fixture.caller(native_fixture.OWNER):async("bee.placement.native:fixture_stop_materialization", {
                source_ref = source, attempt_id = attempt_id, content = '{"fixture":"fenced"}'})
            if not fixture then error(tostring(fixture_error or "start materialization fence fixture")) end
            local start, start_error = native_fixture.caller(native_fixture.OWNER):async("bee.placement.native.binding:start", {attempt_id = attempt_id})
            if not start then error(tostring(start_error or "start fenced attempt")) end
            local fixture_reply = assert(bounds.object(native_fixture.await(fixture)))
            if fixture_reply.ok ~= true then error("materialization fence fixture failed: " .. tostring(fixture_reply.error)) end
            if fixture_reply.written ~= true then error("materialization fence fixture did not write") end
            test.eq(fixture_reply.stop_state, "stopping")
            local started = principals.reply(native_fixture.await(start))
            -- Both asynchronous calls have returned, so remove the source
            -- FIFO before any assertion can abort the test and strand it.
            test.eq(native_fixture.shell("rm -f " .. source_root .. "/auth.json"), "")
            test.is_true(started.ok)
            test.eq(native_fixture.attempt_of(started).execution_state, "starting")
            assert(native_fixture.wait_for(function() return native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = attempt_id})).attempt.execution_state == "exited" end, 3000))

            local stopped = native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = attempt_id})).attempt
            test.eq(stopped.execution_state, "exited")
            test.is_nil(stopped.exit_source)
            test.is_true(stopped.start_cancelled)
            local session_key = assert(homes.session_key(native_fixture.OWNER, session_ref))
            local session_path = assert(homes.ensure_session(session_key))
            local home = assert(homes.os_path(session_path .. "/home"))
            test.eq(native_fixture.shell("test ! -e " .. quote.posix(home .. "/.codex/auth.json") .. " && test ! -e " .. quote.posix(home .. "/.codex/config.toml") .. " && printf absent"), "absent")
            local page = native_fixture.value(native_fixture.call(native_fixture.OWNER, "evidence", {attempt_id = attempt_id, limit = 64}))
            local evidence_count = 0
            for _, item in ipairs(principals.objects(page.evidence)) do
                evidence_count = evidence_count + 1
                test.is_false(item.kind == "credential.materialized")
                test.is_false(item.kind == "configuration.materialized")
                test.is_false(item.kind == "credential.refused")
            end
            local receipt_db = assert(store.open())
            local counts = assert(receipt_db:query([[SELECT evidence_count,
                (SELECT COUNT(*) FROM bee_placement_evidence e WHERE e.attempt_id = a.attempt_id) AS actual_count
                FROM bee_placement_attempts a WHERE attempt_id = ?]], {attempt_id}))
            receipt_db:release()
            test.eq(counts[1].evidence_count, counts[1].actual_count)
            test.is_true(evidence_count > 0)

            -- A partial native identity must not be mistaken for an empty
            -- execution scope, even with a genuine pre-creation receipt.
            local db = store.open()
            if not db then error("store") end
            local _, corrupt_error = db:execute("UPDATE bee_placement_attempts SET pgid = 99999999 WHERE attempt_id = ?", {attempt_id})
            db:release()
            if corrupt_error then error(tostring(corrupt_error)) end
            local contradictory = native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = attempt_id})
            test.is_false(contradictory.ok)
            test.eq(contradictory.error and contradictory.error.code, "CONFLICT")
            db = store.open()
            if not db then error("store") end
            local _, restore_error = db:execute("UPDATE bee_placement_attempts SET pgid = NULL WHERE attempt_id = ?", {attempt_id})
            db:release()
            if restore_error then error(tostring(restore_error)) end
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = attempt_id}))
            local successor = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "successor-admitted")
            successor.required_cleanup = "process_group"
            successor.required_exit_observation = "independent"
            local successor_attempt = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", successor))
            test.eq(successor_attempt.execution_state, "intended")
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = successor_attempt.attempt_id}))
            if not native_fixture.wait_for(function()
                return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = successor_attempt.attempt_id})).attempt).execution_state == "exited"
            end, 8000) then error("successor retained launch did not exit") end
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = successor_attempt.attempt_id}))
        end)
        test.it("materializes a credential projection into the child and keeps the secret out of evidence", function()
            native_fixture.admit_credential_source()
            local workspace = native_fixture.fresh("ws")
            native_fixture.credential_call("define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = "bee.placement.native:sentinel_key"}})
            local attempt_id = native_fixture.fresh("attempt")
            local projection = native_fixture.credential_call("issue_projection", {workspace_id = workspace, name = "anthropic", audience = native_fixture.OWNER, attempt_id = attempt_id, profile_id = "batch",
                profile_digest = native_fixture.DIGEST, binding_digest = native_fixture.DIGEST, launch_policy_digest = native_fixture.DIGEST, idempotency_key = native_fixture.fresh("key")})
            local request = native_fixture.launch({"sh", "-c", "echo credential:${#ANTHROPIC_API_KEY}"}, "direct_process")
            request.attempt_id = attempt_id
            request.projections = {projection.projection_id}
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            test.eq(prepared.execution_state, "intended")
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = attempt_id, recipient = process.pid(), generation = 1}))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = attempt_id}))
            local text = ""
            local deadline = time.after("10s")
            while not text:find("credential:", 1, true) do
                local selected = channel.select({outputs:case_receive(), deadline:case_receive()})
                if not selected.ok or selected.channel == deadline then error("no output; received: " .. text) end
                local data = assert(bounds.object(selected.value:payload():data()))
                if data.data then text = text .. tostring(data.data) end
                process.send(tostring(selected.value:from()), protocol.TOPIC_ACK, {generation = 1, consumed_through = math.floor(data.sequence)})
            end
            process.unlisten(outputs)
            test.is_true(text:find("credential:" .. tostring(#native_fixture.SENTINEL), 1, true) ~= nil)
            local page = native_fixture.value(native_fixture.call(native_fixture.OWNER, "evidence", {attempt_id = attempt_id, limit = 64}))
            local kinds_seen: {string} = {}
            for _, item in ipairs(principals.objects(page.evidence)) do
                if tostring(item.detail):find(native_fixture.SENTINEL, 1, true) then error("sentinel leaked into evidence") end
                kinds_seen[#kinds_seen + 1] = tostring(item.kind)
            end
            test.is_true(native_fixture.has(kinds_seen, "credential.materialized"))
            local db = store.open()
            if not db then error("store") end
            local row = store.row(db, assert(bounds.id(attempt_id)))
            db:release()
            if tostring(row and row.request_json):find(native_fixture.SENTINEL, 1, true) then error("sentinel leaked into the stored request") end
            local other_attempt = native_fixture.fresh("attempt")
            local foreign = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            foreign.attempt_id = other_attempt
            foreign.projections = {projection.projection_id}
            local scoped = native_fixture.call(native_fixture.OWNER, "prepare", foreign)
            test.eq(scoped.error and scoped.error.code, "DENIED")
            local revoked_attempt = native_fixture.fresh("attempt")
            local revocable = native_fixture.credential_call("issue_projection", {workspace_id = workspace, name = "anthropic", audience = native_fixture.OWNER, attempt_id = revoked_attempt, profile_id = "batch",
                profile_digest = native_fixture.DIGEST, binding_digest = native_fixture.DIGEST, launch_policy_digest = native_fixture.DIGEST, idempotency_key = native_fixture.fresh("key")})
            local sleeping = native_fixture.launch({"sh", "-c", "sleep 8"}, "direct_process")
            sleeping.attempt_id = revoked_attempt
            sleeping.projections = {revocable.projection_id}
            local exits = assert(process.listen(protocol.TOPIC_EXIT, {message = true}))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", sleeping))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = revoked_attempt, recipient = process.pid(), generation = 1}))
            local started = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = revoked_attempt}))
            test.eq(started.execution_state, "running")
            native_fixture.credential_call("revoke", {projection_id = revocable.projection_id})
            service.wake_supervision("native")
            while true do
                local message = assert((exits:receive()))
                local outcome = assert(bounds.object(message:payload():data()))
                if outcome.attempt_id == revoked_attempt then
                    test.eq(tostring(message:from()), started.runner)
                    test.eq(outcome.generation, 1)
                    break
                end
            end
            process.unlisten(exits)
            local recorded = native_fixture.kinds(revoked_attempt)
            local reconciled = false
            for _, kind in ipairs(recorded) do
                if kind == "credential.revoked" or kind:sub(1, 10) == "reconcile." then reconciled = true end
            end
            test.is_true(reconciled, "the supervised sweeper did not reconcile the attempt")
            test.is_true(native_fixture.has(recorded, "child.exited"))
            if capability == "process_group" then
                test.is_true(native_fixture.has(recorded, "credential.revoked"))
                test.is_false(native_fixture.has(recorded, "grant.revoked"), "credential revocation was also recorded as a resource grant revocation")
                test.is_true(native_fixture.has(recorded, "stop.requested"))
            else
                native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = revoked_attempt, mode = "forced"}))
            end
            local reported = native_fixture.value(service.capabilities())
            local enforcement = assert(bounds.object(reported.revocation_enforcement))
            test.eq(enforcement.mode, "stop_on_reconcile")
            test.eq(enforcement.scheduling_delay_ms, 30000)
            test.eq(enforcement.reconcile_timeout_ms, 5000)
            test.eq(enforcement.sweep_bound, 64)
            local missing_attempt = native_fixture.fresh("attempt")
            local missing = native_fixture.credential_call("issue_projection", {workspace_id = workspace, name = "anthropic", audience = native_fixture.OWNER, attempt_id = missing_attempt, profile_id = "batch",
                profile_digest = native_fixture.DIGEST, binding_digest = native_fixture.DIGEST, launch_policy_digest = native_fixture.DIGEST, idempotency_key = native_fixture.fresh("key")})
            local unrunnable = native_fixture.launch({"/nonexistent/binary/for/bee", "--flag"}, "direct_process")
            unrunnable.attempt_id = missing_attempt
            unrunnable.projections = {missing.projection_id}
            local completions = assert(process.listen(protocol.TOPIC_STARTED, {message = true}))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", unrunnable))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = missing_attempt, recipient = process.pid(), generation = 1}))
            local failed = native_fixture.call(native_fixture.OWNER, "start", {attempt_id = missing_attempt})
            test.is_true(failed.ok)
            test.eq(native_fixture.attempt_of(failed).execution_state, "start_failed")
            if tostring(native_fixture.attempt_of(failed).start_failure):find(native_fixture.SENTINEL, 1, true) then error("sentinel leaked into the start reply") end
            while true do
                local message = assert((completions:receive()))
                local completed = assert(bounds.object(message:payload():data()))
                if completed.attempt_id == missing_attempt then
                    test.eq(completed.generation, 1)
                    break
                end
            end
            process.unlisten(completions)
            local failed_page = native_fixture.value(native_fixture.call(native_fixture.OWNER, "evidence", {attempt_id = missing_attempt, limit = 64}))
            for _, item in ipairs(principals.objects(failed_page.evidence)) do
                if tostring(item.detail):find(native_fixture.SENTINEL, 1, true) then error("sentinel leaked into failure evidence") end
            end
            local failed_kinds = native_fixture.kinds(missing_attempt)
            test.is_true(native_fixture.has(failed_kinds, "child.not_started"), "failed startup has no no-child proof")
            test.is_true(native_fixture.has(failed_kinds, "workdir_preparers.settled"), "failed runner did not settle its preparers")
        end)
        test.it("refuses colliding credential destinations without starting a child or leaking bytes", function()
            native_fixture.admit_credential_source()
            local workspace = native_fixture.fresh("credential-collision")
            for _, name in ipairs({"first", "second"}) do
                native_fixture.credential_call("define", {workspace_id = workspace, name = name, provider = "claude",
                    source = {kind = "env_variable", ref = "bee.placement.native:sentinel_key"}})
            end
            for _, duplicate_projection in ipairs({false, true}) do
                local request = native_fixture.launch({"sh", "-c", "echo child-must-not-run"}, "direct_process")
                local attempt_id = request.attempt_id
                local projections: {string} = {}
                for _, name in ipairs(duplicate_projection and {"first", "second"} or {"first"}) do
                    local projection = native_fixture.credential_call("issue_projection", {workspace_id = workspace, name = name, audience = native_fixture.OWNER,
                        attempt_id = attempt_id, profile_id = "batch", profile_digest = native_fixture.DIGEST, binding_digest = native_fixture.DIGEST,
                        launch_policy_digest = native_fixture.DIGEST, idempotency_key = native_fixture.fresh("projection")})
                    projections[#projections + 1] = projection.projection_id
                end
                request.projections = projections
                if not duplicate_projection then
                    (request.environment).ANTHROPIC_API_KEY = "policy-value"
                end
                native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
                local failed = native_fixture.call(native_fixture.OWNER, "start", {attempt_id = attempt_id})
                test.is_true(failed.ok)
                test.eq(native_fixture.attempt_of(failed).execution_state, "start_failed")
                local message = tostring(native_fixture.attempt_of(failed).start_failure)
                test.is_true(message:find("ANTHROPIC_API_KEY is already assigned", 1, true) ~= nil)
                test.is_nil((message:find(native_fixture.SENTINEL, 1, true)))
                local page = native_fixture.value(native_fixture.call(native_fixture.OWNER, "evidence", {attempt_id = attempt_id, limit = 64}))
                local refused = false
                for _, item in ipairs(principals.objects(page.evidence)) do
                    test.is_true(item.kind ~= "child.started")
                    test.is_nil((tostring(item.detail):find(native_fixture.SENTINEL, 1, true)))
                    if item.kind == "credential.refused" then refused = true end
                end
                test.is_true(refused)
                local db = store.open()
                if not db then error("placement store") end
                local row = store.row(db, assert(bounds.id(attempt_id)))
                db:release()
                test.is_nil((tostring(row and row.request_json):find(native_fixture.SENTINEL, 1, true)))
            end
        end)
    end)
end


return {credentials = native_fixture.suite(credentials_tests)}
