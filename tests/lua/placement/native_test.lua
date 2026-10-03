-- MIT. Native placement home regressions.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local process = require("process")
local channel = require("channel")
local time = require("time")
local registry = require("registry")
local exec = require("exec")
local service = require("service")
local identity = require("identity")
local claude_launch = require("claude_launch")
local json = require("json")
local store = require("store")
local materialization = require("materialization")
local resources = require("resources")
local request_codec = require("request_codec")
local protocol = require("protocol")
local output_buffer = require("output_buffer")
local homes = require("homes")
local quote = require("quote")
local types = require("types")
local native_fixture = require("native_fixture")

local function home_tests()
    test.describe("Native placement homes and admission", function()
        local measured = native_fixture.value(service.capabilities())
        local capability = tostring(measured.capability)
        local observation = tostring(measured.exit_observation)
        test.it("coalesces short reads within the bounded output chunk and preserves stream bytes", function()
            local buffers = output_buffer.new()
            local source = string.rep("x", output_buffer.MAX_BYTES * 2 + 17)
            local emitted: {string} = {}
            for offset = 1, #source, 97 do
                for _, item in ipairs(output_buffer.append(buffers, "stdout", source:sub(offset, offset + 96))) do
                    emitted[#emitted + 1] = item.data
                end
            end
            local stderr = output_buffer.append(buffers, "stderr", "diagnostic")
            test.eq(#emitted, 2)
            test.eq(#emitted[1], output_buffer.MAX_BYTES)
            test.eq(#emitted[2], output_buffer.MAX_BYTES)
            test.eq(#stderr, 0)
            test.eq(output_buffer.size(buffers), 27)
            local stdout_tail = output_buffer.flush(buffers, "stdout")
            local stderr_tail = output_buffer.flush(buffers, "stderr")
            test.is_true(stdout_tail ~= nil)
            test.is_true(stderr_tail ~= nil)
            emitted[#emitted + 1] = (stdout_tail).data
            test.eq(table.concat(emitted), source)
            test.eq((stderr_tail).data, "diagnostic")
            test.eq(output_buffer.size(buffers), 0)
        end)
        test.it("projects only each driver's declared login and configuration files into fixture attempt homes", function()
            for _, case in ipairs(native_fixture.provider_home_fixtures()) do
                local home_spec = (assert(bounds.object(case.launch.provider_home)))
                test.eq(home_spec.provider, case.provider)
                test.eq(home_spec.private, true)
                local files = principals.objects(home_spec.files)
                local login_path: string? = nil
                local initializers: {{[string]: unknown}} = {}
                local expected: {[string]: string} = {}
                for _, file in ipairs(files) do
                    local path = file.path
                    assert(type(path) == "string")
                    if file.kind == "login" then
                        login_path = path
                    else
                        local content = file.kind == "state" and "fixture-private-state" or "fixture-provider-config\n"
                        local initializer: {[string]: unknown} = {path = path, content = content}
                        if type(file.source_path) == "string" then initializer.source_path = file.source_path end
                        initializers[#initializers + 1] = initializer
                        expected[path] = content
                    end
                end
                if not login_path then error(case.provider .. " driver has no login file") end
                local content_format = (case.provider == "agy" or case.provider == "muse") and "opaque" or "json"
                local format = {schema_revision = "bee.credential-format@1", file = {path = login_path, content_format = content_format, initialize = initializers}}
                local login = content_format == "json" and '{"fixture":"provider-login"}' or "fixture-provider-login"
                local key, key_error = homes.attempt_key(native_fixture.OWNER, native_fixture.fresh("provider-home-fixture"))
                if not key then error(tostring(key_error)) end
                local attempt_home, home_error = homes.create_attempt(key)
                if not attempt_home then error(tostring(home_error)) end
                local projected, project_error = homes.project_attempt_login(attempt_home,
                    {provider = case.provider, definition_id = "bee.test." .. case.provider .. "_login", definition_revision = 1, format = format}, login, {})
                if not projected then error(case.provider .. " fixture projection: " .. tostring(project_error)) end
                test.eq(native_fixture.fixture_home_file(attempt_home, login_path), login)
                for path, expected_bytes in pairs(expected) do
                    test.eq(native_fixture.fixture_home_file(attempt_home, path), expected_bytes)
                end
                local unrelated = assert(homes.os_path(attempt_home .. "/home/machine-home-only.txt"))
                test.eq(native_fixture.shell("test ! -e " .. quote.posix(unrelated) .. " && printf missing"), "missing")
                local remove_error = homes.remove_attempt(key)
                test.is_nil(remove_error)
            end
        end)
        test.it("launches Claude with its private config directory and exact login layout", function()
            local source = "bee.credentials:placement_claude_login_fixture"
            local source_root = ".wippy/placement-claude-login-fixture"
            native_fixture.admit_claude_login_source(source)
            local login = '{"fixture":"private-claude-login"}'
            local settings = '{"model":"fixture"}'
            test.eq(native_fixture.shell("mkdir -p " .. source_root .. "/.claude && printf %s " .. quote.posix(login) .. " > " .. source_root .. "/.claude/.credentials.json"
                .. " && printf %s " .. quote.posix(settings) .. " > " .. source_root .. "/.claude/settings.json"), "")
            local workspace = native_fixture.fresh("claude-private-home-workspace")
            native_fixture.credential_call("define", {workspace_id = workspace, name = "claude_login", provider = "claude", source = {kind = "fs_directory", ref = source}})
            local attempt_id = native_fixture.fresh("claude-private-home-attempt")
            local projection = native_fixture.credential_call("issue_projection", {workspace_id = workspace, name = "claude_login", audience = native_fixture.OWNER,
                attempt_id = attempt_id, profile_id = "batch", profile_digest = native_fixture.DIGEST, binding_digest = native_fixture.DIGEST,
                launch_policy_digest = native_fixture.DIGEST, idempotency_key = native_fixture.fresh("claude-private-home-key")})
            local decoded = assert(claude_launch.decode({profile_id = "batch", brief = "fixture"}))
            local spec = claude_launch.specification(decoded)
            local provider_home = assert(bounds.object(spec.provider_home))
            test.eq(provider_home.provider, "claude")
            test.is_true(provider_home.private == true)
            test.eq(provider_home.variable, "CLAUDE_CONFIG_DIR")
            test.eq(provider_home.directory, ".claude")
            local provider_files = principals.objects(provider_home.files)
            test.eq(#provider_files, 3)
            local login_path = ""
            for _, file in ipairs(provider_files) do
                if file.kind == "login" then
                    test.eq(file.path, ".claude/.credentials.json")
                    login_path = file.path
                    -- This fixture checks the CLI-visible layout; it does not
                    -- exercise refreshing or return synthetic bytes to a host.
                    file.write_back = false
                elseif file.kind == "config" then
                    test.eq(file.path, ".claude/settings.json")
                    test.eq(file.source_path, ".claude/settings.json")
                elseif file.kind == "state" then
                    test.eq(file.path, ".claude.json")
                end
            end
            test.eq(login_path, ".claude/.credentials.json")
            local script = 'set -eu'
                .. ' && case "$HOME" in */attempts/*/home) ;; *) exit 41 ;; esac'
                .. ' && test "$CLAUDE_CONFIG_DIR" = "$HOME/.claude"'
                .. ' && test -n "$PATH"'
                .. ' && test -s "$CLAUDE_CONFIG_DIR/.credentials.json"'
                .. ' && test -s "$CLAUDE_CONFIG_DIR/settings.json"'
                .. ' && test -s "$HOME/.claude.json"'
                .. ' && test ! -e "$CLAUDE_CONFIG_DIR/.claude.json"'
                .. ' && actual="$(find "$HOME" -type f | sed "s|^$HOME/||" | sort)"'
                .. ' && expected="$(printf "%s\\n" .claude.json .claude/.credentials.json .claude/settings.json | sort)"'
                .. ' && test "$actual" = "$expected"'
                .. ' && ! env | cut -d= -f1 | grep -q "^XDG_"'
                .. ' && ! env | cut -d= -f1 | grep -q "^ANTHROPIC_"'
                .. ' && ! env | cut -d= -f1 | grep -q "^CLAUDE_CODE_"'
                .. ' && printf claude-private-home-ok'
            local request = native_fixture.launch({"sh", "-c", script}, "process_group")
            request.attempt_id = attempt_id
            request.projections = {projection.projection_id}
            (assert(bounds.object(request.launch))).provider_home = provider_home
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = attempt_id, recipient = process.pid(), generation = 1}))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = attempt_id}))
            local output = ""
            local ended: {[string]: boolean} = {}
            local deadline = time.after("10s")
            while not ended.stdout or not ended.stderr do
                local selected = channel.select({outputs:case_receive(), deadline:case_receive()})
                if not selected.ok or selected.channel == deadline then error("Claude private-home fixture did not report success") end
                local data = selected.value:payload():data()
                if data.attempt_id == attempt_id and data.generation == 1 then
                    if type(data.data) == "string" then output = output .. (data.data) end
                    if data.eof then ended[data.stream] = true end
                    process.send(tostring(selected.value:from()), protocol.TOPIC_ACK,
                        {generation = 1, consumed_through = data.sequence})
                end
            end
            process.unlisten(outputs)
            test.is_true(output:find("claude-private-home-ok", 1, true) ~= nil)
            test.is_true(native_fixture.wait_for(function()
                return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = attempt_id})).attempt).execution_state == "exited"
            end, 5000), "Claude private-home fixture exit was not recorded")
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = attempt_id}))
        end)
        test.it("refuses provider login write-back until runtime no-follow fs is available and leaves files unchanged", function()
            local key = assert(homes.attempt_key(native_fixture.OWNER, native_fixture.fresh("provider-home-link")))
            local attempt_home = assert(homes.create_attempt(key))
            local home = assert(homes.os_path(attempt_home .. "/home"))
            local format = {schema_revision = "bee.credential-format@1", file = {
                path = ".codex/auth.json", content_format = "json", initialize = {}}}
            local login = '{"fixture":"provider-login"}'
            local projected, project_error = homes.project_attempt_login(attempt_home,
                {provider = "codex", definition_id = "bee.test.codex_link_login", definition_revision = 1, format = format}, login, {})
            if not projected then error(tostring(project_error)) end
            local target = ".codex/auth.json"
            local file_path = assert(homes.os_path(attempt_home .. "/home/" .. target))
            local content, read_error = homes.read_provider_file(attempt_home, target)
            test.is_nil(content)
            test.eq(read_error, "provider login write-back requires runtime no-follow fs")
            test.eq(native_fixture.shell("test \"$(cat " .. quote.posix(file_path) .. ")\" = " .. quote.posix(login) .. " && printf unchanged"), "unchanged")

            test.eq(native_fixture.shell("mv " .. quote.posix(file_path) .. " " .. quote.posix(home .. "/.codex/original-login")
                .. " && ln -s original-login " .. quote.posix(file_path)), "")
            local linked, linked_error = homes.read_provider_file(attempt_home, target)
            test.is_nil(linked)
            test.eq(linked_error, "provider login write-back requires runtime no-follow fs")
            test.eq(native_fixture.shell("test -L " .. quote.posix(file_path) .. " && test \"$(cat " .. quote.posix(home .. "/.codex/original-login")
                .. ")\" = " .. quote.posix(login) .. " && printf unchanged"), "unchanged")

            test.eq(native_fixture.shell("mv " .. quote.posix(home .. "/.codex") .. " " .. quote.posix(home .. "/.codex-target")
                .. " && ln -s .codex-target " .. quote.posix(home .. "/.codex")), "")
            local linked_parent, parent_error = homes.read_provider_file(attempt_home, target)
            test.is_nil(linked_parent)
            test.eq(parent_error, "provider login write-back requires runtime no-follow fs")
            test.eq(native_fixture.shell("test -L " .. quote.posix(home .. "/.codex") .. " && test \"$(cat "
                .. quote.posix(home .. "/.codex-target/original-login") .. ")\" = " .. quote.posix(login) .. " && printf unchanged"), "unchanged")
            test.is_nil(homes.remove_attempt(key))
        end)
        test.it("write roots follow granted subpaths and stay inside their resource root", function()
            local root = assert(resources.directory(native_fixture.ROOT))
            local executor = assert(resources.executor())
            local base = native_fixture.fresh("subpath")
            local parent = assert(root:match("^(.*)/[^/]+$"))
            test.eq(native_fixture.shell("mkdir -p " .. quote.posix(root .. "/" .. base .. "/granted")
                .. " && ln -s " .. quote.posix(parent) .. " " .. quote.posix(root .. "/" .. base .. "/escape")), "")
            local function decoded(subpath: string, access: string): types.LaunchRequest
                local raw = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
                raw.resources = {{name = "project", grant_ref = "grant-1", root_ref = native_fixture.ROOT, subpath = subpath, access = access, purpose = "project"}}
                local request, err = request_codec.decode(raw)
                if not request then error(tostring(err)) end
                return request
            end
            local roots, roots_error = materialization.write_roots(decoded(base .. "/granted", "write"), executor)
            test.is_nil(roots_error)
            test.eq(roots and #roots, 1)
            test.eq(roots and roots[1], root .. "/" .. base .. "/granted")
            local whole, whole_error = materialization.write_roots(decoded("", "write"), executor)
            test.is_nil(whole_error)
            test.eq(whole and #whole, 1)
            test.eq(whole and whole[1], root)
            local read_only, read_error = materialization.write_roots(decoded(base .. "/granted", "read"), executor)
            test.is_nil(read_error)
            test.eq(read_only and #read_only, 0)
            local escaped, escape_error = materialization.write_roots(decoded(base .. "/escape", "write"), executor)
            test.is_nil(escaped)
            test.not_nil(escape_error)
            local missing, missing_error = materialization.write_roots(decoded(base .. "/absent", "write"), executor)
            test.is_nil(missing)
            test.not_nil(missing_error)
            native_fixture.shell("rm -rf " .. quote.posix(root .. "/" .. base))
        end)
        test.it("checks login evidence in the selected provider home without opening files", function()
            local raw = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            raw.profile_id = "window"
            raw.environment_refs = {HOME = "bee:machine_home"}
            local declared = assert(bounds.object(raw.launch))
            declared.login = {provider = "codex", command = "codex login", files = {
                {variable = "CODEX_HOME", default_directory = ".codex", path = "auth.json"}}}
            local decoded, err = request_codec.decode(raw)
            if not decoded then error(tostring(err)) end
            local checked: {string} = {}
            local function exists(path: string): boolean
                checked[#checked + 1] = path
                return path == "/custom/auth.json"
            end
            local missing = materialization.login_notice(decoded, "/owner", exists)
            test.eq(missing and missing.code, "LOGIN_REQUIRED")
            test.eq(missing and missing.provider, "codex")
            test.eq(missing and missing.command, "codex login")
            test.eq(checked[1], "/owner/.codex/auth.json")
            decoded.environment.CODEX_HOME = "/custom"
            test.is_nil(materialization.login_notice(decoded, "/owner", exists))
            test.eq(checked[2], "/custom/auth.json")
            decoded.environment.CODEX_HOME = "/other"
            local other = materialization.login_notice(decoded, "/owner", exists)
            test.eq(other and other.code, "LOGIN_REQUIRED")
            test.eq(checked[3], "/other/auth.json")
            decoded.profile_id = "batch"
            test.is_nil(materialization.login_notice(decoded, "/owner", exists))
            test.eq(#checked, 3)
            decoded.profile_id = "window"
            local projected_request, projected_error = request_codec.decode(raw)
            if not projected_request then error(tostring(projected_error)) end
            test.is_nil(materialization.login_notice(projected_request, "/owner", exists, "/owner/.codex/auth.json"))
            test.eq(#checked, 3)
            -- A retained login projection cannot satisfy a provider whose
            -- own home override points outside the retained home.
            projected_request.environment.CODEX_HOME = "/other"
            local projected_elsewhere = materialization.login_notice(projected_request, "/owner", exists, "/owner/.codex/auth.json")
            test.eq(projected_elsewhere and projected_elsewhere.code, "LOGIN_REQUIRED")
            test.is_nil(materialization.login_notice(projected_request, "/owner", function(path: string): boolean? return nil end))
        end)
        test.it("checks all five provider layouts in the home selected for each window", function()
            local cases = {
                {provider = "codex", variable = "CODEX_HOME", directory = ".codex", path = "auth.json", expected = "/owner/.codex/auth.json"},
                {provider = "claude", variable = "CLAUDE_CONFIG_DIR", directory = ".claude", path = ".credentials.json", expected = "/owner/.claude/.credentials.json"},
                {provider = "agy", variable = "HOME", path = ".gemini/antigravity-cli/antigravity-oauth-token", expected = "/owner/.gemini/antigravity-cli/antigravity-oauth-token"},
                {provider = "grok", variable = "GROK_HOME", directory = ".grok", path = "auth.json", expected = "/owner/.grok/auth.json"},
                {provider = "muse", variable = "HOME", path = ".config/muse/auth.json", expected = "/owner/.config/muse/auth.json"},
            }
            for _, case in ipairs(cases) do
                local raw = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
                raw.profile_id = "window"
                local spec = assert(bounds.object(raw.launch))
                spec.login = {provider = case.provider, command = case.provider, files = {
                    {variable = case.variable, default_directory = case.directory, path = case.path}}}
                local decoded, err = request_codec.decode(raw)
                if not decoded then error(tostring(err)) end
                local checked: string? = nil
                local notice = materialization.login_notice(decoded, "/owner", function(path: string): boolean
                    checked = path
                    return false
                end)
                test.eq(checked, case.expected)
                test.eq(notice and notice.provider, case.provider)
            end
        end)
        test.it("finds login evidence in the host home the carrier selects", function()
            -- A host-home window names HOME by the nested env reference, so the
            -- notice must resolve that same reference; otherwise it inspects the
            -- private attempt home, where the provider never stores evidence.
            local original = registry.get("bee.env:machine_home")
            if not original then error("machine home binding is missing") end
            local changed = registry.get("bee.env:machine_home")
            if not changed then error("machine home binding is missing") end
            changed.data = {storage = "bee.placement.native:sentinel_storage",
                variable = "BEE_TEST_LOGIN_HOME", default = "/", readonly = true}
            local changes = registry.snapshot():changes()
            changes:update(changed)
            local applied, apply_error = changes:apply()
            if not applied then error(tostring(apply_error)) end
            local ok, failure = pcall(function()
                local raw = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
                raw.profile_id = "window"
                raw.environment_refs = {HOME = "bee.env:machine_home"}
                local spec = assert(bounds.object(raw.launch))
                -- etc/hosts exists in the inherited host home and never in the
                -- private attempt home, so only host-home resolution clears it.
                spec.login = {provider = "codex", command = "codex login", files = {{variable = "HOME", path = "etc/hosts"}}}
                local decoded, decode_error = request_codec.decode(raw)
                if not decoded then error(tostring(decode_error)) end
                test.is_nil(materialization.prepare_login_notice(decoded, "/private-attempt-home", nil))
            end)
            local restore = registry.snapshot():changes()
            restore:update(native_fixture.registry_input(original))
            local restored, restore_error = restore:apply()
            if not restored then error(tostring(restore_error)) end
            if not ok then error(tostring(failure)) end
        end)
        test.it("returns a typed login notice from prepare and its replay", function()
            local raw = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            raw.profile_id = "window"
            local spec = assert(bounds.object(raw.launch))
            spec.login = {provider = "codex", command = "codex login", files = {{variable = "HOME", path = ".codex/auth.json"}}}
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", raw))
            test.eq(prepared.notice and prepared.notice.code, "LOGIN_REQUIRED")
            test.eq(prepared.notice and prepared.notice.provider, "codex")
            test.eq(prepared.notice and prepared.notice.command, "codex login")
            local replay = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", raw))
            test.eq(replay.notice and replay.notice.code, "LOGIN_REQUIRED")
            native_fixture.value(native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = prepared.attempt_id}))
        end)
        test.it("treats a concurrently removed attempt tree as cleaned and retains real read errors", function()
            local gone = {readdir = function(_self: unknown, _path: string): (unknown, string) return nil, "removed" end,
                exists = function(_self: unknown, _path: string): boolean return false end}
            test.is_nil(homes.remove_tree((gone), "/attempts/gone"))
            local blocked = {readdir = function(_self: unknown, _path: string): (unknown, string) return nil, "denied" end,
                exists = function(_self: unknown, _path: string): boolean return true end}
            test.eq(homes.remove_tree((blocked), "/attempts/blocked"), "read /attempts/blocked: denied")
            local iterator_state = {}
            local missing_file = {readdir = function(_self: unknown, _path: string)
                    local yielded = false
                    return function(state: unknown)
                        if state ~= iterator_state then error("directory iterator lost its state") end
                        if yielded then return nil end
                        yielded = true
                        return {name = "home", type = "file"}
                    end, iterator_state
                end,
                remove = function(_self: unknown, path: string): (boolean, string?)
                    return path == "/attempts/other", path == "/attempts/other/home" and "removed" or nil
                end,
                exists = function(_self: unknown, _path: string): boolean return false end}
            test.is_nil(homes.remove_tree((missing_file), "/attempts/other"))
        end)
        test.it("decodes Linux execution identity facts", function()
            local facts = assert(identity.decode("linux_start=55016250\nlinux_boot=2d21bc55-a6c4-441f-9d95-f5bc579c4152\npgid= 2425392\n"))
            test.eq(facts.start_ticks, 55016250)
            test.eq(facts.boot_id, "2d21bc55-a6c4-441f-9d95-f5bc579c4152")
            test.eq(facts.pgid, 2425392)
            local gone = assert(identity.decode("linux_start=\nlinux_boot=2d21bc55-a6c4-441f-9d95-f5bc579c4152\npgid=\n"))
            test.is_nil(gone.start_ticks)
            test.eq(gone.boot_id, "2d21bc55-a6c4-441f-9d95-f5bc579c4152")
            test.is_nil(gone.pgid)
        end)
        test.it("decodes macOS execution identity facts", function()
            local facts = assert(identity.decode("darwin_start=Thu Sep 24 11:24:20 2026\ndarwin_boot=5D3B9F4E-2C1A-4B8E-9F10-7A6C3E2D1B00\npgid=38997\n"))
            test.eq(facts.start_ticks, 1790249060)
            test.eq(facts.boot_id, "5D3B9F4E-2C1A-4B8E-9F10-7A6C3E2D1B00")
            test.eq(facts.pgid, 38997)
            test.eq(assert(identity.decode("darwin_start=Tue Feb 29 00:00:00 2028\n")).start_ticks, 1835395200)
            test.eq(assert(identity.decode("darwin_start=Wed Mar  1 23:59:59 2000\n")).start_ticks, 951955199)
            -- Missing facts stay unknown; none is read in another's place.
            local partial = assert(identity.decode("darwin_start=\ndarwin_boot=\npgid=  38997\n"))
            test.is_nil(partial.start_ticks)
            test.is_nil(partial.boot_id)
            test.eq(partial.pgid, 38997)
        end)
        test.it("refuses malformed execution identity facts", function()
            for _, output in ipairs({"38997\n", "darwin_start=Thu Sep 24 2026\n", "darwin_start=Thu Foo 24 11:24:20 2026\n",
                "linux_start=12x\n", "linux_boot=boot id\n", "pgid=-1\n", "exit_code=0\n"}) do
                local facts, decode_error = identity.decode(output)
                test.is_nil(facts)
                test.is_true(type(decode_error) == "string", output)
            end
        end)
        test.it("reports a rejected OS group signal instead of claiming success", function()
            local executor, executor_error = exec.get("bee.placement.native.env:placement_executor")
            if not executor then error(tostring(executor_error)) end
            local child, child_error = executor:exec("sh -c 'echo $$; exec sleep 30'", {process_group = true})
            if not child then executor:release(); error(tostring(child_error)) end
            local output = child:stdout_stream()
            local ok, failure = pcall(function()
                local started, start_error = child:start()
                if not started then error(tostring(start_error)) end
                local pid = tonumber(tostring(output:read(64) or ""))
                if not pid then error("child did not report its PID") end
                local recorded, read_error = identity.read(executor, math.floor(pid))
                if not recorded then error(tostring(read_error)) end
                test.eq(recorded.pgid, math.floor(pid))
                local probed, probe_error = identity.signal_group(recorded, 0)
                test.eq(probed, true, tostring(probe_error))
                -- The kernel/shell rejects this signal. The child stays alive,
                -- so this exercises command refusal after identity validation.
                local signalled, signal_error = identity.signal_group(recorded, 9999)
                test.eq(signalled, false)
                test.is_true(type(signal_error) == "string" and signal_error:find("exit", 1, true) ~= nil)
                test.eq(identity.observe(recorded).alive, true)
            end)
            output:close()
            child:close(true)
            executor:release()
            if not ok then error(tostring(failure)) end
        end)
        test.it("stops an unstarted retained attempt without holding its session or creating a child", function()
            for _, required in ipairs({"direct_process", "process_group"}) do
                if types.satisfies(capability, required) then
                    local session_ref = native_fixture.fresh("stopped-before-start")
                    local request = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "must-not-run")
                    request.required_cleanup = required
                    local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
                    test.eq(native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).private_home, true)
                    local foreign = native_fixture.call("bee.test.other", "stop", {attempt_id = prepared.attempt_id})
                    test.is_false(foreign.ok)
                    local stopped = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = prepared.attempt_id}))
                    test.eq(stopped.execution_state, "exited")
                    test.eq(stopped.cleanup_state, "complete")
                    test.eq(stopped.runner, nil)
                    local replay = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = prepared.attempt_id}))
                    test.eq(replay.evidence_count, stopped.evidence_count)
                    local delayed = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
                    test.eq(delayed.execution_state, "exited")
                    test.eq(delayed.evidence_count, stopped.evidence_count)
                    local db = assert(store.open())
                    local row = assert(store.row(db, prepared.attempt_id))
                    test.eq(row.home_key, nil)
                    test.eq(row.pid, nil)
                    db:release()
                    local successor = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "successor")
                    successor.required_cleanup = required
                    local admitted = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", successor))
                    test.eq(admitted.execution_state, "intended")
                    test.eq(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = admitted.attempt_id})).cleanup_state, "complete")
                end
            end
        end)
        test.it("fences concurrent start and stop without retaining an unstarted session", function()
            for index = 1, 4 do
                local session_ref = native_fixture.fresh("start-stop-race")
                local request = native_fixture.retained_launch(native_fixture.OWNER, session_ref, "race")
                request.required_cleanup = capability
                local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
                local first = index % 2 == 0 and "stop" or "start"
                local second = first == "stop" and "start" or "stop"
                local a, a_error = native_fixture.caller(native_fixture.OWNER):async("bee.placement.native.binding:" .. first, {attempt_id = prepared.attempt_id})
                local b, b_error = native_fixture.caller(native_fixture.OWNER):async("bee.placement.native.binding:" .. second, {attempt_id = prepared.attempt_id})
                if a_error or not a or b_error or not b then error("start/stop race: " .. tostring(a_error or b_error)) end
                local first_reply, second_reply = principals.reply(native_fixture.await(a)), principals.reply(native_fixture.await(b))
                local stop_reply = first == "stop" and first_reply or second_reply
                if not stop_reply.ok then error("stop after concurrent " .. first .. "/" .. second .. " failed: " .. tostring(json.encode(stop_reply))) end
                local exited = native_fixture.wait_for(function()
                    local current = native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt
                    return current.execution_state == "exited"
                end, 8000)
                if not exited then
                    local current = native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt
                    error("concurrent " .. first .. "/" .. second .. " remained " .. current.execution_state .. ": " .. tostring(json.encode({start = first == "start" and first_reply or second_reply, stop = stop_reply})))
                end
                test.eq(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id})).cleanup_state, "complete")
                local successor = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", native_fixture.retained_launch(native_fixture.OWNER, session_ref, "after-race")))
                test.eq(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = successor.attempt_id})).cleanup_state, "complete")
            end
        end)
        test.it("inherits only the host-selected user home while keeping placement files private", function()
            local unapproved = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            unapproved.environment_refs = {HOME = "bee.env:machine_home"}
            local refused = native_fixture.call(native_fixture.OWNER, "prepare", unapproved)
            test.is_false(refused.ok)
            test.eq(refused.error and refused.error.code, "DENIED")
            test.eq(refused.error and refused.error.message, "launch policy does not authorize host HOME")
            local refused_db = assert(store.open())
            test.is_nil(store.row(refused_db, tostring(unapproved.attempt_id)))
            refused_db:release()
            local original = registry.get("bee.env:machine_home")
            if not original then error("machine home binding is missing") end
            local changed = registry.get("bee.env:machine_home")
            if not changed then error("machine home binding is missing") end
            changed.data = {storage = "bee.placement.native:sentinel_storage",
                variable = "BEE_TEST_INHERITED_HOME", default = "/tmp", readonly = true}
            local changes = registry.snapshot():changes()
            changes:update(changed)
            local applied, apply_error = changes:apply()
            if not applied then error(tostring(apply_error)) end
            local ok, err = pcall(function()
                local request = native_fixture.retained_launch(native_fixture.OWNER, native_fixture.fresh("inherited-session"), "unused")
                request.launch.argv = {"-c", 'test "$HOME" = /tmp'}
                request.environment_refs = {HOME = "bee.env:machine_home"}
                local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
                test.eq(native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).private_home, false)
                native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
                test.is_true(native_fixture.wait_for(function()
                    return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt).execution_state == "exited"
                end, 5000))
                local finished = (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt)
                test.eq(finished.exit and finished.exit.code, 0)
                local db = assert(store.open())
                local row = assert(store.row(db, prepared.attempt_id))
                test.is_true(type(row.home_key) == "string" and row.home_key ~= "")
                db:release()
                test.eq(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id})).cleanup_state, "complete")
            end)
            local restore = registry.snapshot():changes()
            restore:update(native_fixture.registry_input(original))
            local restored, restore_error = restore:apply()
            if not restored then error(tostring(restore_error)) end
            if not ok then error(tostring(err)) end
        end)
        test.it("rechecks host HOME authorization before materialization", function()
            local policy_entry = assert(registry.get(native_fixture.POLICY))
            local original_policy = policy_entry.data
            local revoked: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original_policy))) do revoked[key] = item end
            revoked.allow_host_home = false
            local request = native_fixture.retained_launch(native_fixture.OWNER, native_fixture.fresh("revoked-home-session"), "must-not-run")
            request.environment_refs = {HOME = "bee.env:machine_home"}
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local ok, failure = pcall(function()
                policy_entry.data = revoked
                local changes = registry.snapshot():changes()
                changes:update(policy_entry)
                local applied, apply_error = changes:apply()
                if not applied then error(tostring(apply_error)) end
                local refused = native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id})
                test.is_false(refused.ok)
                test.eq(refused.error and refused.error.code, "DENIED")
                test.eq(refused.error and refused.error.message, "launch policy does not authorize host HOME")
                local current = native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt
                test.eq(current.execution_state, "intended")
            end)
            policy_entry.data = original_policy
            local restoration = registry.snapshot():changes()
            restoration:update(policy_entry)
            local restored, restore_error = restoration:apply()
            if not restored then error(tostring(restore_error)) end
            local stopped = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = prepared.attempt_id}))
            test.eq(stopped.cleanup_state, "complete")
            if not ok then error(tostring(failure)) end
        end)
        test.it("refuses native and gateway environment collisions before intent", function()
            for _, kind in ipairs({"home", "home_ref", "gateway", "hook", "shared_token", "gateway_home"}) do
                local request = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
                local environment = request.environment
                if kind == "home" then
                    environment.HOME = "/unselected/home"
                elseif kind == "home_ref" then
                    request.environment_refs = {HOME = "fixture:home"}
                else
                    local gateway: {[string]: unknown} = {endpoint = "127.0.0.1:4312", tools = {"thread_read"}, hooks = {}, destination = "BEE_GATEWAY_TOKEN"}
                    if kind == "gateway" then environment.BEE_GATEWAY_TOKEN = "caller-token" end
                    if kind == "hook" then
                        gateway.hooks = {"SessionStart"}
                        gateway.hook_destination = "BEE_HOOK_TOKEN"
                        request.environment_refs = {BEE_HOOK_TOKEN = "fixture:token"}
                    end
                    if kind == "shared_token" then gateway.hooks = {"SessionStart"}; gateway.hook_destination = "BEE_GATEWAY_TOKEN" end
                    if kind == "gateway_home" then gateway.destination = "HOME" end
                    request.gateway = gateway
                end
                local refused = native_fixture.call(native_fixture.OWNER, "prepare", request)
                test.is_false(refused.ok)
                test.eq(refused.error and refused.error.code, "INVALID")
                local detail = refused.error and refused.error.message or ""
                test.is_true(detail:find("owned", 1, true) ~= nil or detail:find("already assigned", 1, true) ~= nil)
                local absent = native_fixture.call(native_fixture.OWNER, "status", {attempt_id = request.attempt_id})
                test.eq(absent.error and absent.error.code, "NOT_FOUND")
            end
        end)
        test.it("refuses native admission when the host policy selects another placement", function()
            local request = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            request.policy_ref = "bee.placement.native:test_non_native_launch_policy"
            -- Omit any caller placement hint: the host policy still controls
            -- selection, even for a direct call to native prepare.
            local refused = native_fixture.call(native_fixture.OWNER, "prepare", request)
            test.eq(refused.error and refused.error.code, "DENIED")
            local absent = native_fixture.call(native_fixture.OWNER, "status", {attempt_id = request.attempt_id})
            test.eq(absent.error and absent.error.code, "NOT_FOUND")
        end)
        test.it("records intent only for admitted, cleanable launches and replays by key", function()
            local request = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            local first = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            test.eq(first.execution_state, "intended")
            test.eq(first.cleanup_state, "pending")
            test.eq(first.capability, capability)
            test.eq(first.evidence_count, 1)
            local again = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            test.eq(again.attempt_id, first.attempt_id)
            local other = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            other.idempotency_key = request.idempotency_key
            local conflict = native_fixture.call(native_fixture.OWNER, "prepare", other)
            test.is_false(conflict.ok)
            test.eq(conflict.error and conflict.error.code, "CONFLICT")
            -- The attempt id is the durable identity and its uniqueness is not
            -- scoped to the idempotency key, so a request that repeats a
            -- recorded attempt under a fresh key is refused by the identity
            -- rather than the key, and has to say so.
            local repeated = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            repeated.attempt_id = request.attempt_id
            local collided = native_fixture.call(native_fixture.OWNER, "prepare", repeated)
            test.is_false(collided.ok)
            local collision = collided.error
            test.eq(collision and collision.code, "CONFLICT")
            local reported = collision and collision.message or ""
            test.eq(reported:find(request.attempt_id, 1, true) ~= nil, true)
            test.eq(reported:find("already recorded", 1, true) ~= nil, true)
            local foreign = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            local denied = native_fixture.call("bee.test.other", "prepare", foreign)
            test.eq(denied.error and denied.error.code, "FORBIDDEN")
            local elsewhere = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            local grant = (principals.objects(elsewhere.resources))[1]
            grant.root_ref = "bee.placement.native.env:root"
            local refused = native_fixture.call(native_fixture.OWNER, "prepare", elsewhere)
            test.eq(refused.error and refused.error.code, "FORBIDDEN")
            local narrow = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            local narrow_grant = (principals.objects(narrow.resources))[1]
            narrow_grant.root_ref = native_fixture.READONLY
            -- The launch line cannot allow a gateway tool the binding does not admit.
            local allowing = native_fixture.launch({"claude", "-p", "hi", "--allowedTools", "Read,mcp__bee__thread_post"}, "direct_process")
            local wider = native_fixture.call(native_fixture.OWNER, "prepare", allowing)
            test.eq(wider.error and wider.error.code, "DENIED")
            local bare = native_fixture.call(native_fixture.OWNER, "prepare", native_fixture.launch({"claude", "-p", "hi", "--allowed-tools=mcp__bee"}, "direct_process"))
            test.eq(bare.error and bare.error.code, "DENIED")
            local widened = native_fixture.call(native_fixture.OWNER, "prepare", narrow)
            test.eq(widened.error and widened.error.code, "FORBIDDEN")
            narrow_grant.access = "read"
            local narrowed = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", narrow))
            test.eq(narrowed.execution_state, "intended")
            test.eq(measured.resource_authority, "host_configured")
            test.is_false(measured.delegated_resource_grants == true)
            test.is_true(measured.credential_broker == true)
            if observation == "eof_gated" then
                local managed = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
                managed.required_exit_observation = "independent"
                local gated = native_fixture.call(native_fixture.OWNER, "prepare", managed)
                test.eq(gated.error and gated.error.code, "UNSUPPORTED_CAPABILITY")
            end
            local strongest = native_fixture.launch({"sh", "-c", "true"}, "contained_tree")
            local closed = native_fixture.call(native_fixture.OWNER, "prepare", strongest)
            test.eq(closed.error and closed.error.code, "UNSUPPORTED_CAPABILITY")
            local db = store.open()
            if not db then error("store") end
            test.is_nil(store.by_key(db, native_fixture.OWNER, strongest.idempotency_key))
            db:release()
            if capability == "direct_process" then
                local grouped = native_fixture.call(native_fixture.OWNER, "prepare", native_fixture.launch({"sh", "-c", "true"}, "process_group"))
                test.eq(grouped.error and grouped.error.code, "UNSUPPORTED_CAPABILITY")
            end
        end)
    end)
end


return {run = native_fixture.suite(home_tests)}
