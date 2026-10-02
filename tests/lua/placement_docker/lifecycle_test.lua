-- SPDX-License-Identifier: MIT
local test = require("test")
local funcs = require("funcs")
local registry = require("registry")
local security = require("security")
local process = require("process")
local channel = require("channel")
local time = require("time")
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
local homes = require("homes")
local OWNER = "bee.test.docker"
local PROFILE = "bee.placement.docker.tests:profile"
local POLICY = "bee.placement.native:test_launch_policy_without_provider"
local ROOT = "bee.placement.native:project_fixture"
local function call(method: string, value: unknown, owner: string?): service.Reply
    local grant = assert(security.policy("bee.placement.docker.tests:client_policy"))
    local client = assert(funcs.new():with_actor(principals.actor(owner or OWNER, "workspace-1")):with_scope(security.new_scope({grant})))
    local reply, err = client:call("bee.placement.docker.binding:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    return principals.reply(reply)
end
local function value(reply: service.Reply): types.Attempt
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return assert(placement_decode.attempt(reply.value))
end
local function running(id: string): types.Attempt
    local started = value(call("start", {attempt_id = id}))
    if started.execution_state ~= "starting" then return started end
    local deadline = time.after("30s")
    while true do
        local status = call("status", {attempt_id = id})
        assert(status.ok)
        local observed = assert(placement_decode.status(status.value))
        if observed.attempt.execution_state ~= "starting" then return observed.attempt end
        local poll = time.after("50ms")
        local selected = channel.select({poll:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel == poll, "Docker start never left its accepted starting state")
    end
    error("Docker start did not finish")
end
local function configure()
    local changes = registry.snapshot():changes()
    local mode = assert(registry.get("bee.placement.native.env:placement_resource_mode"))
    mode.data.mode = "host_configured"; changes:update(mode)
    local roots = assert(registry.get("bee.placement.native.env:placement_admitted_roots"))
    roots.data.roots = {{root_ref = ROOT, access = "write"}}; changes:update(roots)
    local policy = assert(registry.get(POLICY))
    policy.data.placement_profiles = {PROFILE}; changes:update(policy)
    local activation = assert(registry.get("bee.harness.launch:harness_activation"))
    local bindings = principals.strings(activation.data.bindings)
    activation.data.bindings = bindings
    bindings[#bindings + 1] = "bee.placement.native:fixture_agent_binding"; changes:update(activation)
    assert(changes:apply())
end
local function request(id: string): types.LaunchRequest
    local profile = assert(profiles.resolve(registry.snapshot(), PROFILE))
    local raw = {idempotency_key = id, owner_id = OWNER, owner_incarnation = 1, action_id = id, attempt_id = id,
        binding_ref = "bee.placement.native:fixture_agent_binding", policy_ref = POLICY, profile_id = "batch",
        binding_digest = string.rep("a", 64), profile_digest = string.rep("a", 64),
        placement_binding_ref = spec.BINDING, placement_binding_digest = assert(placement_resolver.resolve(registry.snapshot(), spec.BINDING)).binding_digest, placement_profile_ref = PROFILE, placement_profile_digest = profile.digest,
        launch = {executable = "/bin/sh", argv = {"-c", "printf running; sleep 60"}, environment = {},
            working_directory_ref = "project", readiness = "none"},
        resources = {{name = "project", grant_ref = "grant-1", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = {}, required_cleanup = "contained_tree", required_exit_observation = "independent",
        timeouts = {start_ms = 10000, stop_grace_ms = 500, drain_ms = 1000, retain_ms = 1000}}
    return assert(request_codec.decode(raw))
end
local function creator()
    local events = assert(process.events())
    events:receive()
end
local function observed_container(id: string, state: string, code: integer?): (service.Loaded, service.Daemon, string, () -> boolean)
    value(call("prepare", request(id)))
    local key = assert(homes.attempt_key(OWNER, id))
    local home = assert(homes.create_attempt(key))
    local home_source = assert(homes.os_path(home .. "/home"))
    assert(service.change(id, {execution = "starting", evidence = {kind = "child.creating", detail = "containers/create dispatched"}}).ok)
    local loaded = assert(service.load({attempt_id = id}, true))
    local ownership = assert(service.ownership())
    local ref = string.rep("b", 64)
    local image = "sha256:" .. string.rep("c", 64)
    local labels = spec.labels(ownership, id)
    local exists = true
    local client: service.Daemon = {
        list_containers = function(_self: unknown, filters: {[string]: {string}}): (unknown, string?)
            test.eq(#filters.label, 4)
            if not exists then return {}, nil end
            return {{Id = ref, State = state, Labels = labels}}, nil
        end,
        inspect_container = function(_self: unknown, queried: string): (unknown, string?)
            test.eq(queried, ref)
            if not exists then return nil, "HTTP 404: no such container" end
            return {Id = ref, Image = image, Config = {Image = loaded.spec.image, Labels = labels, Env = {"BEE_ATTEMPT_ID=" .. id}},
                Mounts = {{Type = "bind", Source = home_source, Destination = spec.HOME, RW = true}}, State = {Status = state, ExitCode = code}}, nil
        end,
        inspect_image = function(_self: unknown, _image: string): (unknown, string?) return {Id = image}, nil end,
        stop_container = function(_self: unknown, _ref: string, _seconds: number?): (boolean?, string?) return nil, "unexpected stop" end,
        remove_container = function(_self: unknown, removed: string, force: boolean?): (boolean?, string?)
            test.eq(removed, ref)
            test.eq(force, false)
            exists = false
            return true, nil
        end,
    }
    return loaded, client, key, function(): boolean return exists end
end
local function boundary()
    test.describe("Docker failed-start boundary", function()
        configure()
        test.it("reports cancellation before create without inventing a container exit", function()
            local id = "docker-cancelled-before-create"
            value(call("prepare", request(id)))
            local stopped = value(call("stop", {attempt_id = id}))
            test.eq(stopped.execution_state, "uncertain")
            test.eq(stopped.cleanup_state, "complete")
            test.eq(stopped.start_failure, "containers/create: cancelled before Docker runner claim; no container dispatched")
            test.is_nil(stopped.exit)
            test.is_nil(stopped.exit_source)
        end)
        test.it("cancels an owned Created container without reporting an exit", function()
            local loaded, client, key, exists = observed_container("docker-cancel-created", "created", nil)
            local cancelled = service.stop_loaded(loaded, {mode = "forced"}, client)
            test.is_true(cancelled.ok)
            local attempt = assert(placement_decode.attempt(cancelled.value))
            test.eq(attempt.execution_state, "uncertain")
            test.eq(attempt.cleanup_state, "complete")
            test.eq(attempt.start_failure, "containers/start: cancelled before an observed container start")
            test.is_nil(attempt.exit)
            test.is_nil(attempt.exit_source)
            test.is_false(exists())
            test.is_nil(homes.remove_attempt(key))
        end)
        test.it("reserves exited for an observed container exit with its actual code", function()
            local loaded, client, key = observed_container("docker-observed-exit", "exited", 42)
            local reconciled = service.reconcile_loaded(loaded, client)
            test.is_true(reconciled.ok)
            local attempt = assert(placement_decode.attempt(reconciled.value))
            test.eq(attempt.execution_state, "exited")
            test.eq(attempt.exit_source, "reconcile")
            test.eq(attempt.exit and attempt.exit.code, 42)
            test.is_nil(attempt.start_failure)
            local refreshed = assert(service.load({attempt_id = loaded.attempt.attempt_id}, true))
            local cleaned = service.cleanup_loaded(refreshed, client)
            if not cleaned.ok then error(tostring(cleaned.error and cleaned.error.message)) end
            test.eq(assert(placement_decode.attempt(cleaned.value)).cleanup_state, "complete")
            test.is_nil(homes.remove_attempt(key))
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
            test.eq(attempt.execution_state, "uncertain")
            test.is_nil(attempt.exit)
            local recorded = materialization.fail_start(db, id, assert(reason), true)
            test.is_true(recorded.ok)
            test.eq(assert(recorded.attempt).start_failure, reason)
            assert(store.transition(db, id, {cleanup = "complete", evidence = {kind = "test.cleanup", detail = "materialization refused before scratch creation"}}).ok)
            db:release()
        end)
        for index, cause in ipairs({
            'failed to create container: Post "http://docker/v1.45/containers/create": context deadline exceeded',
            'containers/create: HTTP 500: daemon create refused',
        }) do
            test.it("preserves failed create cause " .. tostring(index) .. " in status and session failure", function()
                local id = "docker-failed-" .. tostring(index)
                value(call("prepare", request(id)))
                local db = assert(store.open())
                assert(store.transition(db, id, {execution = "starting", evidence = {kind = "child.creating", detail = "containers/create dispatched"}}).ok)
                local recorded = materialization.fail_start(db, id, cause, true)
                test.is_true(recorded.ok)
                local attempt = assert(store.attempt(db, id))
                db:release()
                test.eq(attempt.execution_state, "uncertain")
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
                db = assert(store.open())
                assert(store.transition(db, id, {execution = "exited", fields = {exit_source = "runner"},
                    evidence = {kind = "test.legacy_mask", detail = "legacy start refusal was stored as exited without an exit"}}).ok)
                local legacy = assert(store.attempt(db, id))
                db:release()
                test.eq(legacy.execution_state, "uncertain")
                test.eq(legacy.start_failure, cause)
                test.is_nil(legacy.exit_source)
            end)
        end
        test.it("removes all and only label-owned Created containers after a failed or abandoned create", function()
            local ownership: spec.Ownership = {node_id = "node-1", state_id = "state-1"}
            local containers: {[string]: {[string]: unknown}} = {}
            local function container(letter: string, node: string, state: string, attempt: string): string
                local id = string.rep(letter, 64)
                containers[id] = {Id = id, Labels = spec.labels({node_id = node, state_id = state}, attempt), State = "created"}
                return id
            end
            local owned = container("a", "node-1", "state-1", "attempt-1")
            local duplicate = container("b", "node-1", "state-1", "attempt-1")
            local foreign_node = container("c", "node-2", "state-1", "attempt-1")
            local foreign_state = container("d", "node-1", "state-2", "attempt-1")
            local foreign_attempt = container("e", "node-1", "state-1", "attempt-2")
            local unlabelled = string.rep("f", 64)
            containers[unlabelled] = {Id = unlabelled, State = "created"}
            local removed: {string} = {}
            local client: service.Daemon = {
                list_containers = function(_self: unknown, filters: {[string]: {string}}): (unknown, string?)
                    test.not_nil(filters.label)
                    test.eq(#filters.label, 4)
                    local values: {unknown} = {}
                    for _, item in pairs(containers) do values[#values + 1] = item end
                    return values, nil
                end,
                inspect_container = function(_self: unknown, id: string): (unknown, string?)
                    local item = containers[id]
                    if not item then return nil, "HTTP 404: no such container" end
                    return {Id = id, Config = {Labels = item.Labels}, State = {Status = item.State}}, nil
                end,
                inspect_image = function(_self: unknown, _image: string): (unknown, string?) return nil, "unexpected image inspection" end,
                stop_container = function(_self: unknown, _id: string, _seconds: number?): (boolean?, string?) return nil, "unexpected stop" end,
                remove_container = function(_self: unknown, id: string, force: boolean?): (boolean?, string?)
                    test.eq(force, false)
                    removed[#removed + 1] = id
                    containers[id] = nil
                    return true, nil
                end,
            }
            local ok, err = service.remove_abandoned(ownership, "attempt-1", client)
            test.is_true(ok)
            test.is_nil(err)
            test.eq(#removed, 2)
            test.is_nil(containers[owned])
            test.is_nil(containers[duplicate])
            for _, id in ipairs({foreign_node, foreign_state, foreign_attempt, unlabelled}) do test.not_nil(containers[id]) end
            containers[owned] = {Id = owned, Labels = spec.labels(ownership, "attempt-1"), State = "running"}
            ok, err = service.remove_abandoned(ownership, "attempt-1", client)
            test.is_false(ok)
            test.eq(err, "owned container may have run; exit observation is required")
            test.eq(#removed, 2)
            containers[owned] = {Id = owned, Labels = spec.labels(ownership, "attempt-1"), State = "created"}
            client.remove_container = function(_self: unknown, _id: string, _force: boolean?): (boolean?, string?)
                return nil, "daemon refused removal"
            end
            ok, err = service.remove_abandoned(ownership, "attempt-1", client)
            test.is_false(ok)
            test.eq(err, "containers/remove: daemon refused removal")
            test.not_nil(containers[owned])
        end)
        test.it("recovers a late Created container after failed-start cleanup was already complete", function()
            local id = "docker-recovery-late"
            value(call("prepare", request(id)))
            local key = assert(homes.attempt_key(OWNER, id))
            assert(homes.create_attempt(key))
            local ownership = assert(service.ownership())
            local db = assert(store.open())
            assert(store.transition(db, id, {execution = "starting", evidence = {kind = "child.creating", detail = "containers/create dispatched"}}).ok)
            assert(materialization.fail_start(db, id, "containers/create: context deadline exceeded", true).ok)
            assert(store.transition(db, id, {cleanup = "complete", evidence = {kind = "test.cleanup", detail = "container absent at the first cleanup observation"}}).ok)
            db:release()
            local ref = string.rep("a", 64)
            local exists = true
            local client: service.Daemon = {
                list_containers = function(_self: unknown, filters: {[string]: {string}}): (unknown, string?)
                    test.not_nil(filters.label)
                    if not exists then return {}, nil end
                    return {{Id = ref, State = "created", Labels = spec.labels(ownership, id)}}, nil
                end,
                inspect_container = function(_self: unknown, _ref: string): (unknown, string?)
                    if not exists then return nil, "HTTP 404: no such container" end
                    return {Id = ref, Config = {Labels = spec.labels(ownership, id)}, State = {Status = "created"}}, nil
                end,
                inspect_image = function(_self: unknown, _image: string): (unknown, string?) return nil, "unexpected image inspection" end,
                stop_container = function(_self: unknown, _ref: string, _seconds: number?): (boolean?, string?) return nil, "unexpected stop" end,
                remove_container = function(_self: unknown, removed: string, force: boolean?): (boolean?, string?)
                    test.eq(removed, ref)
                    test.eq(force, false)
                    exists = false
                    return true, nil
                end,
            }
            local swept = service.sweep(client)
            if not swept.ok then error(tostring(swept.error and swept.error.message)) end
            test.is_true(swept.ok)
            test.is_false(exists)
            local reloaded = assert(service.load({attempt_id = id}, true))
            test.eq(reloaded.attempt.execution_state, "uncertain")
            test.eq(reloaded.attempt.start_failure, "containers/create: context deadline exceeded")
            test.is_nil(reloaded.attempt.exit)
            test.is_nil(homes.remove_attempt(key))
        end)
    end)
end
local function run()
    test.describe("Real Docker placement lifecycle", function()
        configure()
        test.it("keeps a live runner's creation phase when no container exists yet", function()
            local id = "docker-creating-" .. tostring(process.pid()):gsub("[^A-Za-z0-9-]", "-")
            value(call("prepare", request(id)))
            local creator = assert(process.spawn("bee.placement.docker.tests:creator", "bee:workers"))
            assert(service.change(id, {execution = "starting", fields = {runner_pid = tostring(creator)},
                evidence = {kind = "test.creating", detail = "live creator before daemon dispatch"}}).ok)
            local result = call("reconcile", {attempt_id = id})
            process.terminate(creator)
            test.is_true(result.ok)
            test.eq((result.value).execution_state, "starting")
            assert(service.change(id, {execution = "exited", fields = {exit_source = "runner"},
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
            if not ok then error(tostring(failure)) end
        end)
        test.it("delivers quoted initial input and EOF to a real Docker child", function()
            local id = "docker-stdin-" .. tostring(process.pid()):gsub("[^A-Za-z0-9-]", "-")
            local selected = request(id)
            selected.launch.argv = {"-c", "cat; printf '\\nEOF_OK'"}
            selected.launch.stdin = "literal 'quotes' $(no-substitution)\n"
            selected.launch.stdin_eof = true
            local output = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            value(call("prepare", selected))
            value(call("attach", {attempt_id = id, recipient = process.pid(), generation = 1}))
            local ok, failure = pcall(function()
                running(id)
                local deadline = time.after("20s")
                local stdout = ""
                local eof = 0
                while eof < 2 do
                    local received = channel.select({output:case_receive(), deadline:case_receive()})
                    assert(received.ok and received.channel == output, "Docker stdin EOF did not complete")
                    local message = received.value
                    local data = message:payload():data()
                    assert(type(data) == "table" and data.attempt_id == id and data.generation == 1)
                    if data.stream == "stdout" and type(data.data) == "string" then stdout = stdout .. data.data end
                    if data.eof then eof = eof + 1 end
                    process.send(message:from(), protocol.TOPIC_ACK, {generation = 1, consumed_through = data.sequence})
                end
                test.eq(stdout, selected.launch.stdin .. "\nEOF_OK")
            end)
            call("stop", {attempt_id = id, mode = "forced"})
            call("cleanup", {attempt_id = id})
            process.unlisten(output)
            if not ok then error(tostring(failure)) end
        end)
        test.it("gives an argv-based batch provider immediate EOF for empty input", function()
            local id = "docker-empty-stdin-" .. tostring(process.pid()):gsub("[^A-Za-z0-9-]", "-")
            local selected = request(id)
            selected.launch.argv = {"-c", "cat; printf EMPTY_EOF_OK"}
            selected.launch.stdin = ""
            selected.launch.stdin_eof = true
            local output = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            value(call("prepare", selected))
            value(call("attach", {attempt_id = id, recipient = process.pid(), generation = 1}))
            local ok, failure = pcall(function()
                running(id)
                local deadline = time.after("20s")
                local stdout = ""
                local eof = 0
                while eof < 2 do
                    local received = channel.select({output:case_receive(), deadline:case_receive()})
                    assert(received.ok and received.channel == output, "empty Docker input did not reach EOF")
                    local message = received.value
                    local data = message:payload():data()
                    assert(type(data) == "table" and data.attempt_id == id and data.generation == 1)
                    if data.stream == "stdout" and type(data.data) == "string" then stdout = stdout .. data.data end
                    if data.eof then eof = eof + 1 end
                    process.send(message:from(), protocol.TOPIC_ACK, {generation = 1, consumed_through = data.sequence})
                end
                test.eq(stdout, "EMPTY_EOF_OK")
            end)
            call("stop", {attempt_id = id, mode = "forced"})
            call("cleanup", {attempt_id = id})
            process.unlisten(output)
            if not ok then error(tostring(failure)) end
        end)
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
return {run = test.run_cases(run), boundary = test.run_cases(boundary), creator = creator}
