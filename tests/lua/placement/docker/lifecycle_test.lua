-- SPDX-License-Identifier: MIT
local test = require("test")
local funcs = require("funcs")
local registry = require("registry")
local security = require("security")
local process = require("process")
local channel = require("channel")
local cdc = require("cdc")
local completion = require("completion")
local protocol = require("protocol")
local principals = require("principals")
local profiles = require("profiles")
local request_codec = require("request_codec")
local store = require("store")
local types = require("types")
local placement_decode = require("placement_decode")
local spec = require("spec")
local placement_resolver = require("placement_resolver")
local service = require("service")
local materialization = require("materialization")
local prestart = require("prestart")
local bounds = require("bounds")
local profile_home = require("profile_home")
local daemon = require("daemon")
local OWNER = "bee.test.docker"
local PROFILE = "bee.tests.placement.docker:profile"
local REFUSED_PROFILE = "bee.tests.placement.docker:refused_profile"
local POLICY = "bee.tests.placement.native:test_launch_policy_without_provider"
local ROOT = "bee.tests.placement.native:project_fixture"
local function call(method: string, value: unknown, owner: string?, context: {[string]: unknown}?): service.Reply
    local grant = assert(security.policy("bee.tests.placement.docker:client_policy"))
    local client = assert(funcs.new():with_actor(principals.actor(owner or OWNER, "workspace-1")):with_scope(security.new_scope({grant})))
    if context then client = client:with_context(context) end
    local reply, err = client:call("bee.placement.docker.binding:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    return principals.reply(reply)
end
local function value(reply: service.Reply): types.Attempt
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return assert(placement_decode.attempt(reply.value))
end
local function placement_call(method: string, input: unknown): service.Reply
    return call(method, input)
end
local function running(id: string, allow_failure: boolean?): types.Attempt
    local watch = completion.listen()
    local ok, result = pcall(function(): types.Attempt
        completion.attach(watch, placement_call, id)
        local accepted = value(call("start", {attempt_id = id}))
        test.eq(accepted.execution_state, "starting")
        return completion.started(watch, placement_call, id, allow_failure ~= true)
    end)
    completion.close(watch)
    if not ok then error(tostring(result)) end
    return result
end
local function configure()
    local changes = registry.snapshot():changes()
    local mode = assert(registry.get("bee.placement.native.env:placement_resource_mode"))
    mode.data.mode = "host_configured"; changes:update(mode)
    local roots = assert(registry.get("bee.placement.native.env:placement_admitted_roots"))
    roots.data.roots = {{root_ref = ROOT, access = "write"}}; changes:update(roots)
    local policy = assert(registry.get(POLICY))
    policy.data.placement_profiles = {PROFILE, REFUSED_PROFILE}; changes:update(policy)
    -- The fixture's executor stands in for the one image preparation creates,
    -- so it runs as the user the host-user profile resolves to on this node.
    local executor = assert(registry.get("bee.tests.placement.docker:executor"))
    executor.data.user = assert(spec.user("host")); changes:update(executor)
    local activation = assert(registry.get("bee.harness.launch:harness_activation"))
    local bindings = principals.strings(activation.data.bindings)
    activation.data.bindings = bindings
    local admitted = false
    for _, binding in ipairs(bindings) do
        if binding == "bee.tests.placement.native:fixture_agent_binding" then admitted = true end
    end
    if not admitted then bindings[#bindings + 1] = "bee.tests.placement.native:fixture_agent_binding" end
    changes:update(activation)
    assert(changes:apply())
end
local function request(id: string, profile_ref: string?): types.LaunchRequest
    local ref = profile_ref or PROFILE
    local profile = assert(profiles.resolve(registry.snapshot(), ref))
    local raw = {idempotency_key = id, owner_id = OWNER, owner_incarnation = 1, action_id = id, attempt_id = id,
        binding_ref = "bee.tests.placement.native:fixture_agent_binding", policy_ref = POLICY, profile_id = "batch",
        binding_digest = string.rep("a", 64), profile_digest = string.rep("a", 64),
        placement_binding_ref = spec.BINDING, placement_binding_digest = assert(placement_resolver.resolve(registry.snapshot(), spec.BINDING)).binding_digest, placement_profile_ref = ref, placement_profile_digest = profile.digest,
        launch = {executable = "/bin/sh", argv = {"-c", "printf running; sleep 60"}, environment = {},
            working_directory_ref = "project", readiness = "none"},
        resources = {{name = "project", grant_ref = "grant-1", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = {}, required_cleanup = "contained_tree", required_exit_observation = "independent",
        timeouts = {stop_grace_ms = 500, drain_ms = 1000, retain_ms = 1000}}
    return assert(request_codec.decode(raw))
end
local function creator()
    local events = assert(process.events())
    events:receive()
end
local function boundary()
    test.describe("Docker failed-start reporting", function()
        configure()
        test.it("reports cancellation before create without inventing an exit", function()
            local id = "docker-cancelled-before-create"
            value(call("prepare", request(id)))
            local stopped = value(call("stop", {attempt_id = id}))
            test.eq(stopped.execution_state, "exited")
            test.eq(stopped.cleanup_state, "complete")
            test.is_true(stopped.start_cancelled)
            test.is_nil(stopped.start_failure)
            test.is_nil(stopped.exit)
            test.is_nil(stopped.exit_source)
        end)
        test.it("keeps materialization refusal separate from container exit", function()
            local id = "docker-materialization-refused"
            value(call("prepare", request(id)))
            local loaded = assert(service.load({attempt_id = id}, true))
            loaded.request.environment.HOME = "/unadmitted-home"
            local db = assert(store.open())
            assert(store.transition(db, id, {execution = "starting", fields = {runner_pid = process.pid()},
                evidence = {kind = "runner.started", detail = "fixture owns materialization"}}).ok)
            local prepared, reason = materialization.prepare(db, loaded.request, id, 0, nil, nil, spec.HOME)
            test.is_nil(prepared)
            test.not_nil(reason)
            local attempt = assert(store.attempt(db, id))
            test.eq(attempt.execution_state, "start_failed")
            test.is_nil(attempt.exit)
            local recorded = materialization.fail_start(db, id, assert(reason), true)
            test.is_true(recorded.ok)
            test.eq(assert(recorded.attempt).start_failure, reason)
            assert(store.transition(db, id, {cleanup = "complete", evidence = {kind = "test.cleanup", detail = "materialization refused before scratch creation"}}).ok)
            db:release()
        end)
        test.it("rejects a retained startup refusal before waiting for Docker output", function()
            local id = "docker-output-start-refused"
            value(call("prepare", request(id)))
            local cause = "containers/create: HTTP 500: exact fixture refusal"
            local db = assert(store.open())
            assert(store.transition(db, id, {execution = "starting", evidence = {kind = "child.creating", detail = "fixture create"}}).ok)
            assert(materialization.fail_start(db, id, cause, true).ok)
            db:release()
            for _, observe in ipairs({
                function(watch: completion.Watch) completion.started(watch, placement_call, id, true) end,
                function(watch: completion.Watch) completion.wait(watch, placement_call, id, true,
                    function(_output: protocol.Output) error("failed launch produced output") end) end,
            }) do
                local watch = completion.listen()
                local ok, reason = pcall(function() observe(watch) end)
                completion.close(watch)
                test.is_false(ok)
                test.is_true(tostring(reason):find(cause, 1, true) ~= nil, tostring(reason))
            end
        end)
        for index, cause in ipairs({
            'failed to create container: Post "http://docker/v1.45/containers/create": context deadline exceeded',
            'containers/create: HTTP 500: daemon create refused',
            'failed to start container: unable to find user 99999999999999999999: no matching entries in passwd file',
        }) do
            test.it("preserves failed launch cause " .. tostring(index) .. " in status and session failure", function()
                local id = "docker-failed-" .. tostring(index)
                value(call("prepare", request(id)))
                local db = assert(store.open())
                assert(store.transition(db, id, {execution = "starting", evidence = {kind = "child.creating", detail = "executor startup dispatched"}}).ok)
                local recorded = materialization.fail_start(db, id, cause, true)
                test.is_true(recorded.ok)
                local attempt = assert(store.attempt(db, id))
                db:release()
                test.eq(attempt.execution_state, "start_failed")
                test.eq(attempt.start_failure, cause)
                test.is_nil(attempt.exit)
                test.is_nil(attempt.exit_source)
                local decoded = assert(placement_decode.attempt(attempt))
                test.eq(decoded.start_failure, cause)
                local inspected = prestart.inspect(function(_target: string, _value: unknown): (unknown, unknown?)
                    return {ok = true, value = {attempt = attempt, liveness = {observed = false, at = store.now(), detail = cause}}}, nil
                end, "fixture:status", nil, id, "failed", "launch failed")
                test.eq(inspected.outcome, "failed")
                test.eq(inspected.reason, "launch failed; failed start: " .. cause)
                local page = call("evidence", {attempt_id = id, limit = 64})
                test.is_true(page.ok)
                local evidence = assert(bounds.array(assert(bounds.object(page.value)).evidence, 64))
                local final = assert(bounds.object(evidence[#evidence]))
                test.eq(final.kind, "child.start_failed")
                test.eq(final.detail, cause)
            end)
        end
    end)
end
local function run()
    test.describe("Real Docker placement lifecycle", function()
        configure()
        test.it("retains the real daemon start refusal as a failed launch", function()
            local id = "docker-start-refused-" .. tostring(process.pid()):gsub("[^A-Za-z0-9-]", "-")
            value(call("prepare", request(id, REFUSED_PROFILE)))
            local reply: service.Reply = {ok = true, value = running(id, true)}
            test.is_true(reply.ok)
            local status = assert(placement_decode.status(call("status", {attempt_id = id}).value))
            local attempt = status.attempt
            test.eq(attempt.execution_state, "start_failed")
            local reason = assert(attempt.start_failure)
            test.is_true(reason:find("failed to start container", 1, true) ~= nil,
                "expected a daemon start refusal; retained failure: " .. reason)
            test.is_true(reason:find("user", 1, true) ~= nil,
                "expected the invalid user refusal; retained failure: " .. reason)
            test.eq(value(reply).start_failure, reason)
            test.is_nil(attempt.exit)
            test.is_nil(attempt.exit_source)
            test.eq(status.attempt.start_failure, reason)
            local inspected = prestart.inspect(function(_target: string, _value: unknown): (unknown, unknown?)
                return {ok = true, value = status}, nil
            end, "fixture:status", nil, id, "failed", "launch failed")
            test.eq(inspected.outcome, "failed")
            test.eq(inspected.reason, "launch failed; failed start: " .. reason)
            local page = call("evidence", {attempt_id = id, limit = 64})
            test.is_true(page.ok)
            local evidence = assert(bounds.array(assert(bounds.object(page.value)).evidence, 64))
            local found = false
            for _, item in ipairs(evidence) do
                local event = assert(bounds.object(item))
                if event.kind == "child.start_failed" then test.eq(event.detail, reason); found = true end
            end
            test.is_true(found)
        end)
        test.it("keeps a live runner's creation phase when no container exists yet", function()
            local id = "docker-creating-" .. tostring(process.pid()):gsub("[^A-Za-z0-9-]", "-")
            value(call("prepare", request(id)))
            local creator = assert(process.spawn("bee.tests.placement.docker:creator", "bee:workers"))
            assert(service.change(id, {execution = "starting", fields = {runner_pid = tostring(creator)},
                evidence = {kind = "test.creating", detail = "live creator before daemon dispatch"}}).ok)
            local result = call("reconcile", {attempt_id = id})
            local exits = assert(process.events())
            assert(process.monitor(tostring(creator)))
            assert(process.terminate(creator))
            while true do
                local event = assert((exits:receive()))
                if event.kind == process.event.EXIT and tostring(event.from) == tostring(creator) then break end
            end
            process.unmonitor(tostring(creator))
            test.is_true(result.ok)
            test.eq((result.value).execution_state, "starting")
            assert(service.change(id, {execution = "exited", cleanup = "complete", fields = {exit_source = "runner"},
                evidence = {kind = "test.finished", detail = "fixture has no dispatched container"}}).ok)
        end)
        test.it("retains one environment-identified realization, fences foreign stop and proves cancellation before removal", function()
            local id = "docker-" .. tostring(process.pid()):gsub("[^A-Za-z0-9-]", "-")
            local prepared = value(call("prepare", request(id)))
            test.eq(prepared.execution_state, "intended")
            local started = running(id)
            test.eq(started.execution_state, "running")
            local ok, failure = pcall(function()
                test.is_false(call("stop", {attempt_id = id}, "bee.other").ok)
                local repeated = value(call("start", {attempt_id = id}))
                test.eq(repeated.attempt_id, id)
                local reconciled = value(call("reconcile", {attempt_id = id}))
                test.eq(reconciled.execution_state, "running")
                assert(service.change(id, {execution = "uncertain", evidence = {kind = "test.owner_lost", detail = "simulate unknown dispatch observation"}}).ok)
                local stopped = value(call("stop", {attempt_id = id, mode = "forced"}))
                test.eq(stopped.execution_state, "exited")
                test.not_nil(stopped.exit and stopped.exit.code)
                local cleaned = value(call("cleanup", {attempt_id = id}))
                test.eq(cleaned.cleanup_state, "complete")
                test.eq(cleaned.exit_source, "reconcile")
                test.eq(cleaned.exit and cleaned.exit.code, stopped.exit and stopped.exit.code)
                local raw = call("evidence", {attempt_id = id, limit = 64})
                test.is_true(raw.ok)
                local page = raw.value
                local stopped_at, verified_at, removed_at = 0, 0, 0
                for i, item in ipairs(page.evidence) do
                    if item.kind == "docker.stopped" then stopped_at = i end
                    if item.kind == "docker.exit_verified" then verified_at = i end
                    if item.kind == "docker.removed" then removed_at = i end
                end
                test.is_true(stopped_at > 0 and verified_at > stopped_at and removed_at > verified_at)
            end)
            call("stop", {attempt_id = id, mode = "forced"})
            call("cleanup", {attempt_id = id})
            completion.join(started.runner)
            if not ok then error(tostring(failure)) end
        end)
    end)
end
local function input_tests()
    test.describe("Docker placement stdin", function()
        configure()
        for index, input in ipairs({"literal 'quotes' $(no-substitution)\n", ""}) do
            local title = index == 1 and "delivers quoted initial input and EOF to a real Docker child"
                or "gives an argv-based batch provider immediate EOF for empty input"
            test.it(title, function()
                local id = "docker-stdin-" .. tostring(index) .. "-" .. tostring(process.pid()):gsub("[^A-Za-z0-9-]", "-")
                local selected = request(id)
                local expected = index == 1 and "\nEOF_OK" or "EMPTY_EOF_OK"
                selected.launch.argv = {"-c", index == 1 and "cat; printf '\\nEOF_OK'" or "cat; printf EMPTY_EOF_OK"}
                selected.launch.stdin = input
                selected.launch.stdin_eof = true
                local watch = completion.listen()
                local ok, failure = pcall(function()
                    value(call("prepare", selected))
                    completion.attach(watch, placement_call, id)
                    value(call("start", {attempt_id = id}))
                    local stdout = ""
                    completion.wait(watch, placement_call, id, true, function(output: protocol.Output)
                        if output.stream == "stdout" then stdout = stdout .. (output.data or "") end
                    end)
                    test.eq(stdout, input .. expected)
                end)
                local cleaned, cleanup_error = pcall(function() completion.cleanup(placement_call, id) end)
                completion.close(watch)
                if not ok then error(tostring(failure)) end
                if not cleaned then error(tostring(cleanup_error)) end
            end)
        end
    end)
end
local function cleanup_tests()
    test.describe("Docker cleanup ownership", function()
        configure()
        test.it("joins concurrent cleanup callers, preserves failure, and removes once on the next request", function()
            local id = "docker-cleanup-" .. tostring(process.pid()):gsub("[^A-Za-z0-9-]", "-")
            local selected = request(id)
            selected.launch.argv = {"-c", "printf DONE"}
            selected.launch.stdin, selected.launch.stdin_eof = "", true
            local held = assert(process.listen("bee.test.docker.cleanup", {message = true}))
            local snapshots = assert(process.listen("bee.test.docker.cleanup.snapshot", {message = true}))
            local outcomes = assert(process.listen("bee.test.docker.cleanup.outcome", {message = true}))
            assert(process.registry.register("bee.test.docker.cleanup"))
            assert(process.registry.register("bee.test.docker.cleanup.outcome"))
            local changes = assert(cdc.stream("bee:changes", {tables = {"bee_placement_evidence"}, ops = {"insert"}}))
            local source = assert(changes:channel())
            local watch = completion.listen()
            local owner: string? = nil
            local release_topic = "bee.test.docker.cleanup.release"
            local ok, failure = pcall(function()
                value(call("prepare", selected))
                completion.attach(watch, placement_call, id)
                value(call("start", {attempt_id = id}))
                completion.wait(watch, placement_call, id, true, nil)
                owner = tostring(assert((held:receive())):from())
                local finished = channel.new(2) :: channel.Channel<service.Reply>
                coroutine.spawn(function() finished:send(call("cleanup", {attempt_id = id}, nil,
                    {["bee.test.docker.cleanup.snapshot"] = tostring(process.pid())})) end)
                coroutine.spawn(function() finished:send(call("cleanup", {attempt_id = id})) end)
                local snapshot = assert((snapshots:receive()))
                while true do
                    local db = assert(store.open())
                    local rows = assert(db:query("SELECT COUNT(*) AS count FROM bee_placement_evidence WHERE attempt_id = ? AND kind = 'docker.cleanup_requested'", {id}))
                    db:release()
                    if rows[1].count == 2 then break end
                    assert((source:receive()))
                end
                process.registry.unregister("bee.test.docker.cleanup")
                assert(process.send(assert(owner), "bee.test.docker.cleanup.release", {fail = true}))
                release_topic = "bee.test.docker.cleanup.continue"
                local outcome = assert((outcomes:receive()))
                test.eq(tostring(outcome:from()), owner)
                assert(process.send(tostring(snapshot:from()), "bee.test.docker.cleanup.resume", {}))
                for _ = 1, 2 do
                    local failed = assert((finished:receive()))
                    test.eq(failed.ok, false)
                    test.eq(failed.error and failed.error.code, "UNAVAILABLE")
                    test.eq(failed.error and failed.error.message, "fixture cleanup refusal")
                end
                process.registry.unregister("bee.test.docker.cleanup.outcome")
                assert(process.send(tostring(outcome:from()), "bee.test.docker.cleanup.continue", {}))
                owner = nil
                test.eq(value(call("cleanup", {attempt_id = id})).cleanup_state, "complete")
                local db = assert(store.open())
                local rows = assert(db:query("SELECT COUNT(*) AS count FROM bee_placement_evidence WHERE attempt_id = ? AND kind = 'docker.removed'", {id}))
                db:release()
                test.eq(rows[1].count, 1)
            end)
            process.registry.unregister("bee.test.docker.cleanup")
            process.registry.unregister("bee.test.docker.cleanup.outcome")
            if owner then process.send(owner, release_topic, {}) end
            changes:close(); process.unlisten(held); process.unlisten(snapshots); process.unlisten(outcomes); completion.close(watch)
            if not ok then error(tostring(failure)) end
        end)
    end)
end
local function readiness_tests()
    test.describe("Docker placement readiness", function()
        configure()
        test.it("refuses changed profile admission before preparing an image", function()
            local selected = request("docker-stale-profile")
            selected.placement_profile_digest = string.rep("0", 64)
            local reply = call("prepare", selected)
            test.is_false(reply.ok)
            test.eq(reply.error and reply.error.message, "placement profile changed since admission")
        end)
        test.it("reports image and runtime readiness without starting a container", function()
            local reply = call("capabilities", {placement_profile_ref = PROFILE, runtime_name = "claude"})
            test.is_true(reply.ok)
            local report = reply.value
            test.is_true(report.image_readiness.present)
            test.is_false(report.image_readiness.runtime_present)
        end)
    end)
end
local function home_tests()
    test.describe("Saved Docker profile homes", function()
        configure()
        test.it("persists across launches, isolates profiles, excludes launch secrets, resets and deletes", function()
            local workspace = "saved-profile-workspace"
            local client = funcs.new():with_actor(security.new_actor("dockerhome-person")):with_scope(security.new_scope({
                assert(security.policy("bee.tests.harness.profiles:test_call")), assert(security.policy("bee.tests.harness.profiles:test_read")),
                assert(security.policy("bee.tests.harness.profiles:test_write"))}))
            local function profile_call(operation: string, id: string, revision: integer): {[string]: unknown}
                local input: {[string]: unknown} = {operation = operation, workspace_id = workspace, profile_id = id,
                    expected_revision = revision, idempotency_key = id .. ":" .. operation .. ":" .. tostring(revision)}
                if operation == "put" then input.profile = {schema_revision = "bee.agent-profile@3", name = "Docker home fixture",
                    definition_ref = "bee.driver.codex.profiles:research_batch", driver_binding_ref = "bee.driver.codex.binding:binding",
                    provider = {}, bee = {mcp = {}}, placement = {kind = "docker", profile_ref = "bee.placement.docker.profiles:coding"}} end
                local raw, err = client:call("bee.harness.binding:call", input)
                test.is_nil(err)
                local reply = assert(bounds.object(raw))
                test.is_true(reply.ok == true, tostring(reply.message or (bounds.object(reply.error) or {}).message))
                return assert(bounds.object(reply.value))
            end
            local prefix = "dockerhome-" .. tostring(process.pid()):gsub("[^A-Za-z0-9-]", "-")
            local alpha, beta = prefix .. "-a", prefix .. "-b"
            local first, second = profile_call("put", alpha, 0), profile_call("put", beta, 0)
            local source = "bee.tests.credentials:codex_login_fixture"
            local sources = assert(registry.get("bee.credentials.env:credential_sources"))
            local rows = principals.objects(sources.data.sources)
            rows[#rows + 1] = {ref = source, workspace_id = workspace, audience = OWNER, provider = "codex", projection_kinds = {"file"}, path = ".codex/auth.json", write_back = true}
            sources.data.sources = rows
            local changes = registry.snapshot():changes()
            changes:update(sources)
            local format = assert(registry.get("bee.driver.codex.credentials:credential_format"))
            format.data.file.initialize = {{path = ".codex/state.json", content = '{"theme":"light"}'}}
            changes:update(format)
            for _, ref in ipairs({"bee.credentials.security:credential_file_policy", "bee.credentials.security:credential_file_write_policy"}) do
                local entry = assert(registry.get(ref))
                entry.data.policy.resources = {source}
                changes:update(entry)
            end
            assert(changes:apply())
            local seeded, seed_error = daemon.command({"/bin/sh", "-c", [[mkdir -p .wippy/codex-login-fixture/.codex; printf '%s' '{"fixture":"fixture-broker-token"}' > .wippy/codex-login-fixture/.codex/auth.json]]})
            test.is_nil(seed_error); test.not_nil(seeded)
            local credential_client = funcs.new():with_actor(principals.actor(OWNER, workspace)):with_scope(security.new_scope({
                assert(security.policy("bee.tests.placement.native:client_test_policy")),
                assert(security.policy("bee.credentials.security:credential_manage_policy")), assert(security.policy("bee.credentials.security:credential_issue_policy"))}))
            local function credential(method: string, input: {[string]: unknown}): {[string]: unknown}
                local raw, err = credential_client:call("bee.credentials.binding:" .. method, input)
                test.is_nil(err)
                local reply = principals.reply(raw)
                test.is_true(reply.ok, tostring(reply.error and reply.error.message))
                return assert(bounds.object(reply.value))
            end
            credential("define", {workspace_id = workspace, name = "dockerhome-login", provider = "codex", source = {kind = "fs_directory", ref = source}})
            local index = 0
            local function launch(saved: {[string]: unknown}, script: string): (string, string)
                index = index + 1
                local id = prefix .. "-launch-" .. tostring(index)
                local selected = request(id)
                selected.workspace_id = workspace
                local projection = credential("issue_projection", {workspace_id = workspace, name = "dockerhome-login", audience = OWNER,
                    attempt_id = id, profile_id = "batch", profile_digest = selected.profile_digest, binding_digest = selected.binding_digest,
                    launch_policy_digest = string.rep("a", 64), idempotency_key = id})
                selected.projections = {assert(bounds.id(projection.projection_id))}
                selected.preferences = {options = {}, mcp_tools = {}, authority_grant_id = assert(bounds.id(saved.grant_id))}
                selected.launch.argv = {"-c", "set -eu; grep -q fixture-broker-token \"$HOME/.codex/auth.json\"; " .. script}
                selected.launch.stdin, selected.launch.stdin_eof = "fixture-broker-token", true
                selected.launch.provider_home = {provider = "codex", private = true, variable = "CODEX_HOME", directory = ".codex",
                    files = {{source_path = ".codex/auth.json", path = ".codex/auth.json", kind = "login", optional = true, write_back = true},
                        {path = ".codex/state.json", kind = "state", optional = false, write_back = false}}}
                local db = assert(store.open())
                local name = assert(profile_home.selected(db, selected))
                db:release()
                local watch = completion.listen()
                local output = ""
                local ok, failure = pcall(function()
                    value(call("prepare", selected))
                    local blocked = client:call("bee.harness.binding:call", {operation = "reset_home", workspace_id = workspace,
                        profile_id = saved.profile_id, expected_revision = saved.revision, idempotency_key = id .. ":busy-reset"})
                    local refusal = assert(bounds.object(blocked))
                    test.eq(refusal.ok, false)
                    test.eq(refusal.code, "UNAVAILABLE")
                    completion.attach(watch, placement_call, id)
                    value(call("start", {attempt_id = id}))
                    completion.wait(watch, placement_call, id, true, function(item: protocol.Output)
                        if item.stream == "stdout" then output = output .. (item.data or "") end
                    end)
                end)
                local cleaned, cleanup_error = pcall(function() completion.cleanup(placement_call, id) end)
                completion.close(watch)
                if not ok then error(tostring(failure)) end
                if not cleaned then error(tostring(cleanup_error)) end
                return output, name
            end
            local output, name = launch(first, [[test "$(cat)" = fixture-broker-token; grep -q light "$HOME/.codex/state.json"; printf dark > "$HOME/.codex/state.json"; printf history > "$HOME/history"; mkdir "$HOME/sessions"; printf session > "$HOME/sessions/one"; printf settings > "$HOME/settings"; if printf forbidden > "$HOME/.codex/auth.json" 2>/dev/null; then exit 9; fi; printf FIRST]])
            test.eq(output, "FIRST")
            local again, same = launch(first, [[grep -q dark "$HOME/.codex/state.json"; cat "$HOME/history" "$HOME/sessions/one" "$HOME/settings"]])
            test.eq(again, "historysessionsettings"); test.eq(name, same)
            local isolated, other = launch(second, [[test ! -e "$HOME/history"; test ! -e "$HOME/settings"; printf ISOLATED]])
            test.eq(isolated, "ISOLATED"); test.is_true(name ~= other)
            local image = assert(profiles.resolve(registry.snapshot(), PROFILE)).profile.image_ref
            local checked, check_error = daemon.command({"docker", "--host", "unix:///var/run/docker.sock", "run", "--rm", "--network", "none", "--read-only",
                "--mount", "type=volume,source=" .. name .. ",target=/state,readonly", "--entrypoint", "/bin/sh", assert(image), "-c",
                "test ! -s /state/.codex/auth.json && test ! -s /state/.bee-stdin && ! grep -R -l fixture-broker-token /state && printf CLEAN"})
            test.is_nil(check_error); test.eq(checked, "CLEAN")
            first = profile_call("reset_home", alpha, 1)
            local empty, reset_name = launch(first, [[test ! -e "$HOME/history"; test ! -e "$HOME/sessions"; test ! -e "$HOME/settings"; printf EMPTY]])
            test.eq(empty, "EMPTY"); test.eq(reset_name, name)
            profile_call("remove", alpha, 2)
            local _, _, absent = daemon.request("GET", "/volumes/" .. name)
            test.eq(absent, true)
            profile_call("remove", beta, 1)
            local _, _, other_absent = daemon.request("GET", "/volumes/" .. other)
            test.eq(other_absent, true)
        end)
    end)
end
local function isolated_cases(definition: () -> ())
    local cases = test.run_cases(definition)
    return function(options)
        local originals: {[string]: unknown} = {}
        for _, ref in ipairs({"bee.placement.native.env:placement_resource_mode", "bee.placement.native.env:placement_admitted_roots",
            POLICY, "bee.harness.launch:harness_activation", "bee.tests.placement.docker:executor", "bee.credentials.env:credential_sources",
            "bee.credentials.security:credential_file_policy", "bee.credentials.security:credential_file_write_policy", "bee.driver.codex.credentials:credential_format"}) do
            originals[ref] = assert(registry.get(ref)).data
        end
        local ok, result = pcall(cases, options)
        local changes = assert(registry.snapshot()):changes()
        for ref, data in pairs(originals) do
            local entry = assert(registry.get(ref))
            entry.data = data
            changes:update(entry)
        end
        assert(changes:apply())
        if not ok then error(tostring(result)) end
        return result
    end
end
return {home = isolated_cases(home_tests), run = isolated_cases(run), boundary = isolated_cases(boundary), input = isolated_cases(input_tests), cleanup = isolated_cases(cleanup_tests), readiness = isolated_cases(readiness_tests), creator = creator}
