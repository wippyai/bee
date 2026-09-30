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
local spec = require("spec")
local placement_resolver = require("placement_resolver")
local service = require("service")
local OWNER = "bee.test.docker"
local PROFILE = "bee.placement.docker.tests:profile"
local POLICY = "bee.placement.native:test_launch_policy_without_provider"
local ROOT = "bee.placement.native:project_fixture"
local function call(method: string, value: unknown, owner: string?): service.Reply
    local grant = assert(security.policy("bee.placement.docker.tests:client_policy"))
    local client = assert(funcs.new():with_actor(principals.actor(owner or OWNER, "workspace-1")):with_scope(security.new_scope({grant})))
    local reply, err = client:call("bee.placement.docker.binding:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    return reply :: service.Reply
end
local function value(reply: service.Reply): types.Attempt
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value :: types.Attempt
end
local function running(id: string): types.Attempt
    local started = value(call("start", {attempt_id = id}))
    if started.execution_state ~= "starting" then return started end
    local deadline = time.after("30s")
    while true do
        local status = call("status", {attempt_id = id})
        assert(status.ok)
        local observed = status.value :: {attempt: types.Attempt}
        if observed.attempt.execution_state ~= "starting" then return observed.attempt end
        local poll = time.after("50ms")
        local selected = channel.select({poll:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel == poll, "Docker start never left its accepted starting state")
    end
    error("Docker start did not finish")
end
local function configure()
    local changes = registry.snapshot():changes()
    local mode = assert(registry.get("bee.placement.native:placement_resource_mode"))
    mode.data.mode = "host_configured"; changes:update(mode)
    local roots = assert(registry.get("bee.placement.native:placement_admitted_roots"))
    roots.data.roots = {{root_ref = ROOT, access = "write"}}; changes:update(roots)
    local policy = assert(registry.get(POLICY))
    policy.data.placement_profiles = {PROFILE}; changes:update(policy)
    local activation = assert(registry.get("bee.harness:harness_activation"))
    local bindings = activation.data.bindings :: {string}
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
            test.eq((result.value :: types.Attempt).execution_state, "starting")
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
                local page = raw.value :: {evidence: {{kind: string}}}
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
            local report = reply.value :: {image_readiness: {present: boolean, runtime_present: boolean}}
            test.is_true(report.image_readiness.present)
            test.is_false(report.image_readiness.runtime_present)
        end)
    end)
end
return {run = test.run_cases(run), creator = creator}
