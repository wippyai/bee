-- MIT. A launch request decodes exactly or not at all; its digest follows
-- its content; the state machines move only along recorded edges.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local request = require("request")
local transitions = require("transitions")
local protocol = require("protocol")
local resource_resolution = require("resource_resolution")
local types = require("types")
local DIGEST = string.rep("a", 64)
local CONFIG_DIGEST = "ca3d163bab055381827226140568f3bef7eaac187cebd76878e0b63e9e442356"
local function launch(): {[string]: unknown}
    return {idempotency_key = "key-1", owner_id = "bee.owner", owner_incarnation = 3, action_id = "action-1", attempt_id = "attempt-1",
        binding_ref = "bee.driver.claude.binding:binding", policy_ref = "bee.host:launch_policy", profile_id = "session", binding_digest = DIGEST, profile_digest = DIGEST,
        launch = {executable = "claude", argv = {"-p", "hello world"}, environment = {"ANTHROPIC_BASE_URL"}, working_directory_ref = "project", readiness = "protocol:system.init"},
        resources = {{name = "project", grant_ref = "grant-1", root_ref = "app:project", subpath = "src/app", access = "write", purpose = "project"}},
        environment = {ANTHROPIC_BASE_URL = "http://127.0.0.1:9"}, required_cleanup = "process_group"}
end
local function rejects(mutate: ({[string]: unknown}) -> (), message: string)
    local value = launch()
    mutate(value)
    local decoded, err = request.decode(value)
    test.is_nil(decoded)
    test.eq(err, message)
end
local function define_tests()
    test.describe("Placement requests", function()
        test.it("decodes resource authority replies exactly", function()
            local reply: {[string]: unknown} = {grant_id = "grant-1", workspace_id = "workspace-1", name = "project",
                root_ref = "app:project", root_digest = string.rep("a", 64), directory = "/workspace/project", subpath = "src/app",
                access = "write", purpose = "project", association_id = "association-1", association_revision = 2,
                expires_at = "2025-01-01T00:00:00.000Z", authorization_epoch = 0}
            local decoded, decode_error = resource_resolution.decode(reply)
            if not decoded then error(tostring(decode_error)) end
            test.eq(decoded.grant_id, "grant-1")
            test.eq(decoded.root_ref, "app:project")
            test.eq(decoded.access, "write")
            test.eq(decoded.association_revision, 2)

            local malformed: {[string]: unknown} = {}
            for key, value in pairs(reply) do malformed[key] = value end
            malformed.access = true
            test.is_nil(resource_resolution.decode(malformed))
            malformed.access = "write"
            malformed.extra = "unexpected"
            local _, unknown_error = resource_resolution.decode(malformed)
            test.eq(unknown_error, "resource resolution: unknown field extra")
            malformed.extra = nil
            malformed.association_revision = nil
            local _, missing_error = resource_resolution.decode(malformed)
            test.eq(missing_error, "resource resolution has invalid or missing fields")
        end)
        test.it("decodes bounded login evidence and refuses unsafe paths", function()
            local value = launch()
            local spec = assert(bounds.object(value.launch))
            spec.login = {provider = "claude", command = "claude", files = {
                {variable = "CLAUDE_CONFIG_DIR", default_directory = ".claude", path = ".credentials.json"}}}
            local decoded, err = request.decode(value)
            if not decoded then error(tostring(err)) end
            test.eq(decoded.launch.login and decoded.launch.login.provider, "claude")
            test.eq(decoded.launch.login and decoded.launch.login.files[1].path, ".credentials.json")
            rejects(function(item)
                (assert(bounds.object(item.launch))).login = {provider = "claude", command = "claude", files = {
                    {variable = "HOME", path = "../auth.json"}}}
            end, "launch.login.files[1].path must be a safe relative path")
            rejects(function(item)
                (assert(bounds.object(item.launch))).login = {provider = "claude", command = "claude\nrm", files = {
                    {variable = "HOME", path = "auth.json"}}}
            end, "launch.login.command must be a bounded single line")
            rejects(function(item)
                (assert(bounds.object(item.launch))).login = {provider = "claude", command = "claude", files = {}}
            end, "launch.login.files must contain 1 to 8 paths")
        end)
        test.it("preserves non-file alternatives in window login advisories", function()
            local value = launch()
            local spec = assert(bounds.object(value.launch))
            spec.login = {provider = "fixture", command = "fixture login", files = {},
                any_of = {{kind = "env_present", names = {"FIXTURE_KEY"}}}}
            local decoded, err = request.decode(value)
            if not decoded then error(tostring(err)) end
            local login = assert(decoded.launch.login)
            test.eq(#login.files, 0)
            test.eq(login.any_of and login.any_of[1].kind, "env_present")
            spec.login = {provider = "fixture", command = "fixture login", files = {}, any_of = {}}
            test.is_nil(request.decode(value))
        end)
        test.it("decodes exact provider-home files and bounded private environment roots", function()
            local value = launch()
            local spec = assert(bounds.object(value.launch))
            spec.provider_home = {provider = "opencode", private = true,
                extra_variables = {{variable = "XDG_CONFIG_HOME", directory = ".config"}, {variable = "XDG_DATA_HOME", directory = ".local/share"}},
                files = {{source_path = ".local/share/opencode/auth.json", path = ".local/share/opencode/auth.json", kind = "login", optional = true, write_back = true},
                    {source_path = ".config/opencode/opencode.json", path = ".config/opencode/.bee-global-opencode.json", kind = "config", optional = true, write_back = false}}}
            local decoded, err = request.decode(value)
            if not decoded or not decoded.launch.provider_home then error(tostring(err)) end
            test.eq(decoded.launch.provider_home.provider, "opencode")
            test.eq(decoded.launch.provider_home.private, true)
            test.eq(#(decoded.launch.provider_home.extra_variables or {}), 2)
            test.eq(#decoded.launch.provider_home.files, 2)
            rejects(function(item)
                (assert(bounds.object(item.launch))).provider_home = {provider = "codex", private = true,
                    variable = "CODEX_HOME", directory = ".codex", files = {{source_path = "../auth.json", path = ".codex/auth.json", kind = "login"}}}
            end, "launch.provider_home.files[1].source_path must be a safe relative path")
            rejects(function(item)
                (assert(bounds.object(item.launch))).provider_home = {provider = "codex", private = true,
                    variable = "CODEX_HOME", directory = ".codex", extra_variables = {{variable = "CODEX_HOME", directory = ".codex"}},
                    files = {{source_path = ".codex/auth.json", path = ".codex/auth.json", kind = "login"}}}
            end, "launch.provider_home.extra_variables contains an invalid or duplicate variable")
            rejects(function(item)
                (assert(bounds.object(item.launch))).provider_home = {provider = "codex", private = true,
                    variable = "CODEX_HOME", directory = ".codex", files = {{source_path = ".codex/auth.json", path = ".codex/auth.json", kind = "login",
                        optional = false, write_back = false}, {source_path = ".codex/config.toml", path = ".codex/config.toml", kind = "config", optional = true, write_back = true}}}
            end, "launch.provider_home.files[2].write_back is only valid for login files")
            rejects(function(item)
                local sparse: {[integer]: unknown} = {[1] = {source_path = ".codex/auth.json", path = ".codex/auth.json", kind = "login"},
                    [3] = {source_path = ".codex/config.toml", path = ".codex/config.toml", kind = "config"}}
                (assert(bounds.object(item.launch))).provider_home = {provider = "codex", private = true,
                    variable = "CODEX_HOME", directory = ".codex", files = sparse}
            end, "launch.provider_home.files must be a dense list: list keys must be dense")
            rejects(function(item)
                local keyed: {[string]: unknown} = {primary = {source_path = ".codex/auth.json", path = ".codex/auth.json", kind = "login"}}
                (assert(bounds.object(item.launch))).provider_home = {provider = "codex", private = true,
                    variable = "CODEX_HOME", directory = ".codex", files = keyed}
            end, "launch.provider_home.files must be a dense list: list keys must be dense")
            rejects(function(item)
                local too_many: {unknown} = {}
                for index = 1, request.MAX_REQUIRED_FILES + 1 do
                    too_many[index] = {source_path = ".codex/file" .. tostring(index), path = ".codex/file" .. tostring(index), kind = "config"}
                end
                (assert(bounds.object(item.launch))).provider_home = {provider = "codex", private = true,
                    variable = "CODEX_HOME", directory = ".codex", files = too_many}
            end, "launch.provider_home.files must be a dense list: list exceeds 8 items")
            rejects(function(item)
                local sparse: {[integer]: unknown} = {[2] = {variable = "XDG_CONFIG_HOME", directory = ".config"}}
                (assert(bounds.object(item.launch))).provider_home = {provider = "codex", private = true,
                    variable = "CODEX_HOME", directory = ".codex", extra_variables = sparse,
                    files = {{source_path = ".codex/auth.json", path = ".codex/auth.json", kind = "login"}}}
            end, "launch.provider_home.extra_variables must be a dense list: list keys must be dense")
        end)
        test.it("retains hooks when the admitted MCP tool set is empty", function()
            local raw = launch()
            raw.gateway = {endpoint = "127.0.0.1:4312", tools = {}, destination = "BEE_GATEWAY_TOKEN", hooks = {"SessionStart"}, hook_destination = "BEE_GATEWAY_HOOK_TOKEN"}
            local decoded, err = request.decode(raw)
            if not decoded or not decoded.gateway then error(tostring(err)) end
            test.eq(#decoded.gateway.tools, 0)
            test.eq(decoded.gateway.hooks[1], "SessionStart")
            raw.gateway = {endpoint = "127.0.0.1:4312", tools = {}, destination = "BEE_GATEWAY_TOKEN", hooks = {}}
            local empty = request.decode(raw)
            test.is_nil(empty)
        end)
        test.it("decodes a complete request with defaults and a stable digest", function()
            local decoded, err = request.decode(launch())
            if not decoded then error(tostring(err)) end
            test.eq(decoded.timeouts.stop_grace_ms, request.DEFAULT_STOP_GRACE_MS)
            test.eq(decoded.resources[1].subpath, "src/app")
            test.eq(decoded.launch.argv[2], "hello world")
            test.is_nil(decoded.session_ref)
            test.eq(decoded.required_exit_observation, "independent")
            local first = request.digest(decoded)
            local again = request.digest(assert(request.decode(launch())))
            test.eq(first, again)
            test.eq(#(first), 64)
            local changed = launch()
            local inner = assert(bounds.object(changed.launch))
            inner.argv = {"-p", "other"}
            local other = request.decode(changed)
            test.neq(request.digest(other), first)
        end)
        test.it("decodes a gateway selection exactly and refuses caller delivery", function()
            local value = launch()
            value.gateway = {endpoint = "127.0.0.1:4312", tools = {"thread_wait", "thread_read"}, hooks = {"SessionStart"}, destination = "BEE_GATEWAY_TOKEN", hook_destination = "BEE_GATEWAY_HOOK_TOKEN"}
            local decoded, err = request.decode(value)
            if not decoded then error(tostring(err)) end
            local gateway = decoded.gateway
            test.eq(#gateway.tools, 2)
            test.eq(gateway.endpoint, "127.0.0.1:4312")
            test.eq(gateway.destination, "BEE_GATEWAY_TOKEN")
            test.eq(gateway.hook_destination, "BEE_GATEWAY_HOOK_TOKEN")
            local plain = request.digest(assert(request.decode(launch())))
            test.neq(request.digest(decoded), plain)
            rejects(function(item) item.gateway = {endpoint = "127.0.0.1:4312", tools = {}, hooks = {}, destination = "BEE_GATEWAY_TOKEN"} end, "gateway needs tools or hooks")
            local sectioned = launch()
            sectioned.gateway = {endpoint = "127.0.0.1:4312", tools = {"thread_read"}, hooks = {}, destination = "BEE_GATEWAY_TOKEN"}
            local without_file = request.decode(sectioned)
            if not without_file then error("a gateway without hooks decodes") end
            test.is_nil((without_file.gateway).hook_destination)
            rejects(function(item) item.gateway = {endpoint = "127.0.0.1:4312", tools = {"thread_read"}, hooks = {}, destination = "token"} end, "gateway.destination must be an environment name")
            rejects(function(item) item.gateway = {endpoint = "127.0.0.1:4312", tools = {"thread_read"}, hooks = {}, destination = "BEE_GATEWAY_TOKEN", token = "x"} end, "gateway: unknown field token")
            rejects(function(item) item.gateway = {endpoint = "127.0.0.1:4312", tools = {"thread_read"}, hooks = {"SessionStart"}, destination = "BEE_GATEWAY_TOKEN"} end, "gateway.hooks needs gateway.hook_destination")
            rejects(function(item) item.gateway = {endpoint = "127.0.0.1:4312", tools = {"thread_read"}, hooks = {}, destination = "BEE_GATEWAY_TOKEN", hook_destination = "BEE_GATEWAY_HOOK_TOKEN"} end, "gateway.hook_destination needs admitted hook events")
            rejects(function(item) item.delivery = {arguments = {}, files = {}} end, "unknown field delivery")
            local with_digest = launch()
            with_digest.configuration_digest = CONFIG_DIGEST
            local digest_decoded = request.decode(with_digest)
            if not digest_decoded then error("configuration digest should decode") end
            test.eq(digest_decoded.configuration_digest, CONFIG_DIGEST)
        end)
        test.it("admits the nine-tool default gateway without widening credential or hook lists", function()
            local value = launch()
            value.gateway = {endpoint = "127.0.0.1:4312", tools = {"components", "delivery", "docs", "overlay", "thread_message",
                "thread_notify", "thread_read", "thread_sessions", "thread_wait"}, hooks = {}, destination = "BEE_GATEWAY_TOKEN"}
            local decoded, err = request.decode(value)
            if not decoded or not decoded.gateway then error(tostring(err)) end
            test.eq(#decoded.gateway.tools, 9)
            rejects(function(item)
                item.projections = {"one", "two", "three", "four", "five", "six", "seven", "eight", "nine"}
            end, "projections exceeds 8 items")
            rejects(function(item)
                item.gateway = {endpoint = "127.0.0.1:4312", tools = {"thread_read"},
                    hooks = {"one", "two", "three", "four", "five", "six", "seven", "eight", "nine"},
                    destination = "BEE_GATEWAY_TOKEN", hook_destination = "BEE_GATEWAY_HOOK_TOKEN"}
            end, "gateway.hooks exceeds 8 items")
        end)
        test.it("rejects traversal, unknown fields, missing environment and bad references", function()
            rejects(function(value) (principals.objects(value.resources))[1].subpath = "../etc" end, "resources[1]: subpath has an invalid segment")
            rejects(function(value) (principals.objects(value.resources))[1].subpath = "/abs" end, "resources[1]: subpath must be relative")
            rejects(function(value) value.extra = true end, "unknown field extra")
            rejects(function(value) value.environment = {} end, "launch.environment requires ANTHROPIC_BASE_URL and nothing supplies it")
            rejects(function(value) (assert(bounds.object(value.launch))).working_directory_ref = "missing" end, "launch.working_directory_ref names no resource")
            rejects(function(value) (assert(bounds.object(value.launch))).home_ref = "project" end, "launch.home_ref must name a writable session resource")
            rejects(function(value) value.required_cleanup = "everything" end, "required_cleanup must name a cleanup capability")
            rejects(function(value) value.required_exit_observation = "eventually" end, "required_exit_observation must be independent or eof_gated")
            rejects(function(value) value.policy_ref = nil end, "policy_ref is not an identifier")
            rejects(function(value) value.executable = {revision = "bee.executable-measurement@1", kind = "elf", digest = "short"} end, "executable.digest must be a sha256 hex digest")
            rejects(function(value) value.executable = {kind = "elf", digest = DIGEST} end, "executable.revision is not an identifier")
            rejects(function(value) value.executable = {revision = "bee.executable-measurement@1", kind = "launcher", digest = DIGEST} end, "executable.kind must be elf, script or other")
            rejects(function(value)
                local launch_value = assert(bounds.object(value.launch))
                launch_value.session_end = "signal"
            end, "launch.session_end must be stdin_close")
            rejects(function(value)
                local launch_value = assert(bounds.object(value.launch))
                launch_value.stdin = "hello\n"
                launch_value.stdin_eof = true
                launch_value.session_end = "stdin_close"
            end, "launch.session_end names a closed stdin")
            rejects(function(value) value.binding_digest = "short" end, "binding_digest must be a sha256 hex digest")
            rejects(function(value) value.owner_incarnation = 0 end, "owner_incarnation must be a positive integer")
            rejects(function(value) value.timeouts = {start_ms = 1000} end, "timeouts: unknown field start_ms")
            rejects(function(value) value.environment_refs = {ANTHROPIC_BASE_URL = "bee:x"} end, "environment and environment_refs both set ANTHROPIC_BASE_URL")
            rejects(function(value) value.environment = {["bad-name"] = "x"} end, "environment names bad-name, not a variable name")
            rejects(function(value)
                local list = principals.objects(value.resources)
                value.resources = list
                list[2] = {name = "project", grant_ref = "g", root_ref = "app:other", subpath = "", access = "read", purpose = "cache"}
            end, "resources name project twice")
        end)
        test.it("bounds output retention after exit and accepts a runner status reply only from the recorded runner, attempt, generation and probe", function()
            local decoded, err = request.decode(launch())
            if not decoded then error(tostring(err)) end
            test.eq(decoded.timeouts.retain_ms, request.DEFAULT_RETAIN_MS)
            test.eq(decoded.timeouts.drain_ms, request.DEFAULT_DRAIN_MS)
            test.is_nil(decoded.launch.stdin_eof)
            rejects(function(value: {[string]: unknown}) (assert(bounds.object(value.launch))).stdin_eof = true end, "launch.stdin_eof needs launch.stdin")
            rejects(function(value: {[string]: unknown}) (assert(bounds.object(value.launch))).stdin_eof = "yes" end, "launch.stdin_eof must be a boolean")
            rejects(function(value: {[string]: unknown}) value.timeouts = {drain_ms = 1} end, "timeouts.drain_ms must be between 100 and " .. tostring(request.MAX_DRAIN_MS))
            rejects(function(value: {[string]: unknown}) value.timeouts = {retain_ms = 5} end, "timeouts.retain_ms must be between 100 and " .. tostring(request.MAX_RETAIN_MS))
            local expected = {runner = "runner-1", attempt_id = "attempt-1", generation = 3, probe = "probe-1"}
            local reply = {attempt_id = "attempt-1", generation = 3, probe = "probe-1", execution = "running", eof_seen = 0,
                pending_outputs = 0, remembered_writes = 0, truncated = false}
            local accepted = protocol.status_reply_accepted("runner-1", reply, expected)
            test.not_nil(accepted)
            local _, other_sender = protocol.status_reply_accepted("runner-2", reply, expected)
            test.eq(other_sender, "reply from runner-2, not the recorded runner")
            local starting = {attempt_id = "attempt-1", generation = 3, probe = "probe-1", execution = "starting", eof_seen = 0,
                pending_outputs = 0, remembered_writes = 0, truncated = false}
            local startup = protocol.status_reply_accepted("runner-1", starting, expected)
            test.not_nil(startup)
            test.eq(startup and startup.execution, "starting")
            local _, forged_start = protocol.status_reply_accepted("runner-2", starting, expected)
            test.eq(forged_start, "reply from runner-2, not the recorded runner")
            local foreign = {attempt_id = "attempt-2", generation = 3, probe = "probe-1", execution = "running", eof_seen = 0, pending_outputs = 0, remembered_writes = 0}
            local _, foreign_error = protocol.status_reply_accepted("runner-1", foreign, expected)
            test.eq(foreign_error, "reply names another attempt")
            local stale = {attempt_id = "attempt-1", generation = 2, probe = "probe-1", execution = "running", eof_seen = 0, pending_outputs = 0, remembered_writes = 0}
            local _, stale_error = protocol.status_reply_accepted("runner-1", stale, expected)
            test.eq(stale_error, "reply names generation 2, not 3")
            local replayed = {attempt_id = "attempt-1", generation = 3, probe = "probe-0", execution = "running", eof_seen = 0, pending_outputs = 0, remembered_writes = 0}
            local _, replay_error = protocol.status_reply_accepted("runner-1", replayed, expected)
            test.eq(replay_error, "reply answers another probe")
            local odd = {attempt_id = "attempt-1", generation = 3, probe = "probe-1", execution = "done", eof_seen = 0, pending_outputs = 0, remembered_writes = 0}
            local _, odd_error = protocol.status_reply_accepted("runner-1", odd, expected)
            test.eq(odd_error, "reply reports an unknown execution")
            local wrong_flag = {attempt_id = "attempt-1", generation = 3, probe = "probe-1", execution = "running", eof_seen = 0,
                pending_outputs = 0, remembered_writes = 0, truncated = "no"}
            local _, flag_error = protocol.status_reply_accepted("runner-1", wrong_flag, expected)
            test.eq(flag_error, "reply truncated flag is invalid")
            local unknown = {attempt_id = "attempt-1", generation = 3, probe = "probe-1", execution = "running", eof_seen = 0,
                pending_outputs = 0, remembered_writes = 0, extra = true}
            local _, unknown_error = protocol.status_reply_accepted("runner-1", unknown, expected)
            test.eq(unknown_error, "reply: unknown field extra")
            local fractional = {attempt_id = "attempt-1", generation = 3, probe = "probe-1", execution = "running", eof_seen = 0.5,
                pending_outputs = 0, remembered_writes = 0}
            local _, counter_error = protocol.status_reply_accepted("runner-1", fractional, expected)
            test.eq(counter_error, "reply counters are outside their bounds")
            local stdin_expected = {runner = "runner-1", attempt_id = "attempt-1", generation = 3, probe = "probe-1"}
            local _, stdin_error = protocol.stdin_reply_accepted("runner-1", {attempt_id = "attempt-1", generation = 3,
                probe = "probe-1", closed = false}, stdin_expected)
            test.eq(stdin_error, "refused reply has no reason")
        end)
        test.it("ranks capabilities and moves states only along recorded edges", function()
            test.is_true(types.satisfies("process_group", "direct_process"))
            test.is_false(types.satisfies("direct_process", "process_group"))
            test.is_true(types.satisfies("contained_tree", "process_group"))
            test.is_true(types.observes("independent", "eof_gated"))
            test.is_true(types.observes("eof_gated", "eof_gated"))
            test.is_false(types.observes("eof_gated", "independent"))
            test.is_true(transitions.execution("intended", "starting"))
            test.is_true(transitions.execution("starting", "stopping"))
            test.is_true(transitions.execution("running", "stopping"))
            test.is_false(transitions.execution("exited", "running"))
            test.is_false(transitions.execution("intended", "running"))
            test.is_true(transitions.execution("uncertain", "exited"))
            test.is_true(transitions.cleanup("pending", "complete"))
            test.is_false(transitions.cleanup("complete", "pending"))
            test.is_true(transitions.may_clean("exited"))
            test.is_false(transitions.may_clean("uncertain"))
            test.is_true(transitions.live("stopping"))
            test.is_false(transitions.live("intended"))
        end)
    end)
end
return test.run_cases(define_tests)
