-- MIT. A launch request decodes exactly or not at all; its digest follows
-- its content; the state machines move only along recorded edges.
local test = require("test")
local request = require("request")
local transitions = require("transitions")
local protocol = require("protocol")
local types = require("types")
local DIGEST = string.rep("a", 64)
local function launch(): {[string]: unknown}
    return {idempotency_key = "key-1", owner_id = "bee.owner", owner_incarnation = 3, action_id = "action-1", attempt_id = "attempt-1",
        binding_ref = "bee.driver.claude:binding", policy_ref = "bee.host:launch_policy", profile_id = "session", binding_digest = DIGEST, profile_digest = DIGEST,
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
        test.it("decodes a complete request with defaults and a stable digest", function()
            local decoded, err = request.decode(launch())
            if not decoded then error(tostring(err)) end
            test.eq(decoded.timeouts.start_ms, request.DEFAULT_START_MS)
            test.eq(decoded.timeouts.stop_grace_ms, request.DEFAULT_STOP_GRACE_MS)
            test.eq(decoded.resources[1].subpath, "src/app")
            test.eq(decoded.launch.argv[2], "hello world")
            test.is_nil(decoded.session_ref)
            test.eq(decoded.required_exit_observation, "independent")
            local first = request.digest(decoded)
            local again = request.digest(request.decode(launch()) :: types.LaunchRequest)
            test.eq(first, again)
            test.eq(#(first :: string), 64)
            local changed = launch()
            local inner = changed.launch :: {[string]: unknown}
            inner.argv = {"-p", "other"}
            local other = request.decode(changed)
            test.neq(request.digest(other :: types.LaunchRequest), first)
        end)
        test.it("decodes a gateway projection exactly and refuses a caller-shaped one", function()
            local configuration = {revision = "bee.mcp-config@1", path = ".claude.json", content = "{}\n", digest = DIGEST, provider_ref = "bee:gateway_endpoint"}
            local value = launch()
            value.gateway = {tools = {"thread_wait", "thread_read"}, configuration = configuration, destination = "BEE_GATEWAY_TOKEN"}
            local decoded, err = request.decode(value)
            if not decoded then error(tostring(err)) end
            local gateway = decoded.gateway :: types.Gateway
            test.eq(#gateway.tools, 2)
            test.eq((gateway.configuration :: types.Configuration).path, ".claude.json")
            test.eq(gateway.destination, "BEE_GATEWAY_TOKEN")
            local plain = request.digest(request.decode(launch()) :: types.LaunchRequest)
            test.neq(request.digest(decoded), plain)
            rejects(function(item) item.gateway = {tools = {}, configuration = configuration, destination = "BEE_GATEWAY_TOKEN"} end, "gateway.tools must name 1 to " .. tostring(request.MAX_PROJECTIONS) .. " tools")
            local sectioned = launch()
            sectioned.gateway = {tools = {"thread_read"}, destination = "BEE_GATEWAY_TOKEN"}
            local without_file = request.decode(sectioned)
            if not without_file then error("a gateway without a standalone file decodes") end
            test.is_nil((without_file.gateway :: types.Gateway).configuration)
            rejects(function(item) item.gateway = {tools = {"thread_read"}, configuration = configuration, destination = "token"} end, "gateway.destination must be an environment name")
            rejects(function(item) item.gateway = {tools = {"thread_read"}, configuration = configuration, destination = "BEE_GATEWAY_TOKEN", token = "x"} end, "gateway: unknown field token")
            local elsewhere = {revision = "bee.mcp-config@1", path = ".bee/mcp.json", content = "{}\n", digest = DIGEST, provider_ref = "bee:gateway_endpoint"}
            rejects(function(item) item.gateway = {tools = {"thread_read"}, configuration = elsewhere, destination = "BEE_GATEWAY_TOKEN"} end, "gateway.configuration.path is not a permitted home file")
        end)
        test.it("rejects traversal, unknown fields, missing environment and bad references", function()
            rejects(function(value) (value.resources :: {{[string]: unknown}})[1].subpath = "../etc" end, "resources[1]: subpath has an invalid segment")
            rejects(function(value) (value.resources :: {{[string]: unknown}})[1].subpath = "/abs" end, "resources[1]: subpath must be relative")
            rejects(function(value) value.extra = true end, "unknown field extra")
            rejects(function(value) value.environment = {} end, "launch.environment requires ANTHROPIC_BASE_URL and nothing supplies it")
            rejects(function(value) (value.launch :: {[string]: unknown}).working_directory_ref = "missing" end, "launch.working_directory_ref names no resource")
            rejects(function(value) (value.launch :: {[string]: unknown}).home_ref = "project" end, "launch.home_ref must name a writable session resource")
            rejects(function(value) value.required_cleanup = "everything" end, "required_cleanup must name a cleanup capability")
            rejects(function(value) value.required_exit_observation = "eventually" end, "required_exit_observation must be independent or eof_gated")
            rejects(function(value) value.policy_ref = nil end, "policy_ref is not an identifier")
            rejects(function(value) value.executable = {revision = "bee.executable-measurement@1", kind = "elf", digest = "short"} end, "executable.digest must be a sha256 hex digest")
            rejects(function(value) value.executable = {kind = "elf", digest = DIGEST} end, "executable.revision is not an identifier")
            rejects(function(value) value.executable = {revision = "bee.executable-measurement@1", kind = "launcher", digest = DIGEST} end, "executable.kind must be elf, script or other")
            rejects(function(value)
                local launch_value = value.launch :: {[string]: unknown}
                launch_value.session_end = "signal"
            end, "launch.session_end must be stdin_close")
            rejects(function(value)
                local launch_value = value.launch :: {[string]: unknown}
                launch_value.stdin = "hello\n"
                launch_value.stdin_eof = true
                launch_value.session_end = "stdin_close"
            end, "launch.session_end names a closed stdin")
            rejects(function(value) value.binding_digest = "short" end, "binding_digest must be a sha256 hex digest")
            rejects(function(value) value.owner_incarnation = 0 end, "owner_incarnation must be a positive integer")
            rejects(function(value) value.timeouts = {start_ms = request.MAX_START_MS + 1} end, "timeouts.start_ms must be between 1 and " .. tostring(request.MAX_START_MS))
            rejects(function(value) value.environment_refs = {ANTHROPIC_BASE_URL = "bee:x"} end, "environment and environment_refs both set ANTHROPIC_BASE_URL")
            rejects(function(value) value.environment = {["bad-name"] = "x"} end, "environment names bad-name, not a variable name")
            rejects(function(value)
                local list = value.resources :: {{[string]: unknown}}
                list[2] = {name = "project", grant_ref = "g", root_ref = "app:other", subpath = "", access = "read", purpose = "cache"}
            end, "resources name project twice")
        end)
        test.it("bounds output retention after exit and accepts a runner status reply only from the recorded runner, attempt, generation and probe", function()
            local decoded, err = request.decode(launch())
            if not decoded then error(tostring(err)) end
            test.eq(decoded.timeouts.retain_ms, request.DEFAULT_RETAIN_MS)
            test.eq(decoded.timeouts.drain_ms, request.DEFAULT_DRAIN_MS)
            test.is_nil(decoded.launch.stdin_eof)
            rejects(function(value: {[string]: unknown}) (value.launch :: {[string]: unknown}).stdin_eof = true end, "launch.stdin_eof needs launch.stdin")
            rejects(function(value: {[string]: unknown}) (value.launch :: {[string]: unknown}).stdin_eof = "yes" end, "launch.stdin_eof must be a boolean")
            rejects(function(value: {[string]: unknown}) value.timeouts = {drain_ms = 1} end, "timeouts.drain_ms must be between 100 and " .. tostring(request.MAX_DRAIN_MS))
            rejects(function(value: {[string]: unknown}) value.timeouts = {retain_ms = 5} end, "timeouts.retain_ms must be between 100 and " .. tostring(request.MAX_RETAIN_MS))
            local expected = {runner = "runner-1", attempt_id = "attempt-1", generation = 3, probe = "probe-1"}
            local reply = {attempt_id = "attempt-1", generation = 3, probe = "probe-1", execution = "running", eof_seen = 0, pending_outputs = 0, remembered_writes = 0}
            local accepted = protocol.status_reply_accepted("runner-1", reply, expected)
            test.not_nil(accepted)
            local _, other_sender = protocol.status_reply_accepted("runner-2", reply, expected)
            test.eq(other_sender, "reply from runner-2, not the recorded runner")
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
        end)
        test.it("ranks capabilities and moves states only along recorded edges", function()
            test.is_true(types.satisfies("process_group", "direct_process"))
            test.is_false(types.satisfies("direct_process", "process_group"))
            test.is_true(types.satisfies("contained_tree", "process_group"))
            test.is_true(types.observes("independent", "eof_gated"))
            test.is_true(types.observes("eof_gated", "eof_gated"))
            test.is_false(types.observes("eof_gated", "independent"))
            test.is_true(transitions.execution("intended", "starting"))
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
