-- MIT. Native placement acceptance for instruction builders.
local test = require("test")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local json = require("json")
local canonical = require("canonical")
local service = require("service")
local store = require("store")
local homes = require("homes")
local hash = require("hash")
local time = require("time")
local exec = require("exec")
local quote = require("quote")
local configuration_protocol = require("configuration_protocol")

local OWNER = "bee.test.instruction_builder"
local DIGEST = string.rep("b", 64)
local ROOT = "bee.placement.native:project_fixture"
local POLICY = "bee.placement.native:instruction_builder_policy"
local PROVIDER = "bee.placement.native:fixture_agent_provider"
local BINDING = "bee.placement.native:fixture_agent_binding"
local BUILDER = "bee.placement.native:fixture_builder_build"
local ACTIVATION = "bee:harness_activation"
local MODE = "bee.placement.native:resource_mode"
local ROOTS = "bee.placement.native:admitted_roots"
local TEST_MARKER = "ctx_marker_unique_42"
local FAILING_BUILDER_SOURCE = [[
local M = {}
function M.build(_: unknown): string
    error("builder deliberately fails after commit")
end
return M
]]

local counter = 0
type RegistryState = {activation: {[string]: unknown}, roots: {[string]: unknown}, mode: {[string]: unknown}, builder: {[string]: unknown}}

local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-ib-" .. tostring(counter) .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000))
end

-- A caller is bound to the workspace it acts in, as host-issued principals are.
local function caller(actor: string, workspace_id: unknown)
    local policies: {security.Policy} = {}
    for index, name in ipairs({"bee.placement.native:client_test_policy", "bee:resource_manage_policy", "bee:resource_grant_policy", "bee:credential_manage_policy", "bee:credential_issue_policy", "bee.placement.native:builder_test_caller_policy"}) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return funcs.new():with_actor(principals.actor(actor, workspace_id)):with_scope(security.new_scope(policies)):with_context({["instruction_builder_test_marker"] = TEST_MARKER})
end

local function call(actor: string, method: string, value: unknown): service.Reply
    local reply, err = caller(actor, principals.workspace(value)):call("bee.placement.native:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    return reply :: service.Reply
end

local function admit_root()
    local mode = registry.get(MODE)
    if not mode then error("resource mode entry") end
    mode.data = {mode = "host_configured"}
    local modes = registry.snapshot():changes()
    modes:update(mode)
    local mode_ok, mode_error = modes:apply()
    if not mode_ok then error(tostring(mode_error)) end
    local entry = registry.get(ROOTS)
    if not entry then error("admitted roots entry") end
    local data = entry.data :: {[string]: unknown}
    local roots = data.roots :: {{[string]: unknown}}
    for _, root in ipairs(roots) do
        if root.root_ref == ROOT then return end
    end
    roots[#roots + 1] = {root_ref = ROOT, access = "write"}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("admit root: " .. tostring(err)) end
end

local function clone_object(value: unknown): {[string]: unknown}
    local encoded, encode_error = json.encode(value)
    if not encoded then error(tostring(encode_error or "encode registry state")) end
    local copied, decode_error = json.decode(encoded)
    if type(copied) ~= "table" then error(tostring(decode_error or "decode registry state")) end
    return copied :: {[string]: unknown}
end

local function registry_state(): RegistryState
    local activation = registry.get(ACTIVATION)
    local roots = registry.get(ROOTS)
    local mode = registry.get(MODE)
    local builder = registry.get(BUILDER)
    if not activation or not roots or not mode or not builder then error("registry state entries") end
    return {activation = clone_object(activation.data), roots = clone_object(roots.data), mode = clone_object(mode.data), builder = clone_object(builder.data)}
end

local function restore_registry_state(state: RegistryState)
    local activation = registry.get(ACTIVATION)
    local roots = registry.get(ROOTS)
    local mode = registry.get(MODE)
    local builder = registry.get(BUILDER)
    if not activation or not roots or not mode or not builder then error("registry state entries disappeared") end
    mode.data = clone_object(state.mode)
    activation.data = clone_object(state.activation)
    roots.data = clone_object(state.roots)
    builder.data = clone_object(state.builder)
    local changes = registry.snapshot():changes()
    changes:update(mode)
    changes:update(activation)
    changes:update(roots)
    changes:update(builder)
    local applied, err = changes:apply()
    if not applied then error("restore registry state: " .. tostring(err)) end
end

local function set_activation(enabled: boolean)
    local entry = registry.get(ACTIVATION)
    if not entry then error("activation entry") end
    local data = entry.data :: {[string]: unknown}
    local current = data.bindings :: {unknown}
    local bindings: {string} = {}
    for _, item in ipairs(current) do
        local binding = tostring(item)
        if binding ~= BINDING then bindings[#bindings + 1] = binding end
    end
    if enabled then bindings[#bindings + 1] = BINDING end
    data.bindings = bindings
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("set activation: " .. tostring(err)) end
end

local function apply_changes(changes: registry.Changes, label: string)
    local applied, apply_error = changes:apply()
    if not applied then error(label .. ": " .. tostring(apply_error)) end
end

local function measure_policy_digest(policy_ref: string): string
    local policy_entry = registry.get(policy_ref)
    if not policy_entry then error("policy entry not found: " .. policy_ref) end
    local data = policy_entry.data :: {[string]: unknown}
    local provider = registry.get(PROVIDER)
    if not provider then error("provider entry") end
    local request_input = {
        provider_ref = PROVIDER,
        provider = provider,
        instructions = data.instructions,
        instruction_builder = data.instruction_builder,
        fixture = true,
    }
    local digest, digest_error = configuration_protocol.digest(request_input, "bee.placement.native:fixture_agent_configure")
    if not digest then error(tostring(digest_error)) end
    return digest
end

local function launch_request(attempt_id: string, configuration_digest: string?): {[string]: unknown}
    local digest = configuration_digest or measure_policy_digest(POLICY)
    return {
        idempotency_key = fresh("key"),
        owner_id = OWNER,
        owner_incarnation = 1,
        action_id = fresh("action"),
        attempt_id = attempt_id,
        binding_ref = BINDING,
        policy_ref = POLICY,
        profile_id = "batch",
        binding_digest = DIGEST,
        profile_digest = DIGEST,
        launch = {
            executable = "sh",
            argv = {"-c", "test -s \"$HOME/.fixture-agent/provider.json\" && test -s \"$HOME/.fixture-agent/instructions.txt\""},
            environment = {},
            working_directory_ref = "project",
            readiness = "none",
        },
        configuration_digest = digest,
        resources = {{name = "project", grant_ref = "grant-1", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = {},
        required_cleanup = "direct_process",
        required_exit_observation = "eof_gated",
        timeouts = {start_ms = 10000, stop_grace_ms = 500},
    }
end

local function shell(command: string): string
    local executor, executor_error = exec.get("bee.placement.native:executor")
    if not executor then error("executor: " .. tostring(executor_error)) end
    local proc, proc_error = executor:exec(command)
    if not proc then executor:release(); error("exec: " .. tostring(proc_error)) end
    local stdout, stdout_error = proc:stdout_stream()
    if not stdout then proc:wait(); executor:release(); error("stdout: " .. tostring(stdout_error)) end
    local started, start_error = proc:start()
    if not started then stdout:close(); proc:wait(); executor:release(); error("start: " .. tostring(start_error)) end
    local output = ""
    while true do
        local chunk: unknown = stdout:read(4096)
        if type(chunk) ~= "string" or chunk == "" then break end
        output = output .. (chunk :: string)
    end
    proc:wait()
    stdout:close()
    executor:release()
    return output
end

local function run_command(argv: {string}): string
    return shell(quote.line(argv))
end

local function wait_for_exit(attempt_id: string)
    local deadline = time.now():unix_nano() + 5000 * 1000000
    while time.now():unix_nano() < deadline do
        local status = call(OWNER, "status", {attempt_id = attempt_id})
        if status.ok and type(status.value) == "table" and (status.value :: {[string]: unknown}).attempt ~= nil then
            local attempt = (status.value :: {[string]: unknown}).attempt :: {[string]: unknown}
            if attempt.execution_state == "exited" then
                local exit = attempt.exit
                if type(exit) ~= "table" or (exit :: {[string]: unknown}).code ~= 0 then error("child exited unsuccessfully") end
                return
            end
        end
        time.sleep("50ms")
    end
    error("child did not exit")
end

local function cleanup_attempt(attempt_id: string)
    local status = call(OWNER, "status", {attempt_id = attempt_id})
    if status.ok and type(status.value) == "table" then
        local attempt = (status.value :: {[string]: unknown}).attempt
        if type(attempt) == "table" and (attempt :: {[string]: unknown}).execution_state ~= "exited" then
            call(OWNER, "stop", {attempt_id = attempt_id, mode = "forced"})
        end
    end
    local deadline = time.now():unix_nano() + 5000 * 1000000
    while time.now():unix_nano() < deadline do
        local current = call(OWNER, "status", {attempt_id = attempt_id})
        if current.ok and type(current.value) == "table" then
            local attempt = (current.value :: {[string]: unknown}).attempt
            if type(attempt) == "table" and (attempt :: {[string]: unknown}).execution_state == "exited" then break end
        end
        time.sleep("50ms")
    end
    call(OWNER, "cleanup", {attempt_id = attempt_id})
end

local function define_tests()
    test.describe("Native placement instruction builder", function()
        local original = registry_state()
        admit_root()

        test.it("evaluates builder with inherited actor and ctx, verifies store/exec denial, and materializes append", function()
            local prepared_attempt_id: string? = nil
            local body_ok, body_error = pcall(function()
                set_activation(true)
                local request = launch_request(fresh("attempt-1"))
                local prepared_reply = call(OWNER, "prepare", request)
                test.is_true(prepared_reply.ok)
                local prepared_value = prepared_reply.value
                if type(prepared_value) ~= "table" then error("prepare did not return an attempt") end
                local prepared = prepared_value :: {[string]: unknown}
                prepared_attempt_id = prepared.attempt_id :: string
                test.eq(prepared.execution_state, "intended")

                -- Start child attempt
                local started_reply = call(OWNER, "start", {attempt_id = prepared_attempt_id})
                test.is_true(started_reply.ok)
                local started = started_reply.value :: {[string]: unknown}
                test.eq(started.execution_state, "running")

                -- Inspect generated instructions file in child home
                local key, key_error = homes.attempt_key(OWNER, prepared_attempt_id)
                if not key then error(tostring(key_error or "attempt home key")) end
                local path, path_error = homes.os_path("/attempts/" .. key .. "/home/.fixture-agent/instructions.txt")
                if not path then error(tostring(path_error or "instructions path")) end
                local content = run_command({"cat", path})
                test.is_true(content:find("Base static instructions.", 1, true) ~= nil)
                test.is_true(content:find("Dynamic guidance: actor=" .. OWNER, 1, true) ~= nil)
                test.is_true(content:find("marker=" .. TEST_MARKER, 1, true) ~= nil)
                test.is_true(content:find("sentinel=placement-sentinel-4e5f6a", 1, true) ~= nil)
                test.is_true(content:find("tag=integration", 1, true) ~= nil)

                wait_for_exit(prepared_attempt_id)
                local cleaned = call(OWNER, "cleanup", {attempt_id = prepared_attempt_id})
                test.is_true(cleaned.ok)
                prepared_attempt_id = nil
            end)
            if prepared_attempt_id then cleanup_attempt(prepared_attempt_id) end
            if not body_ok then error(tostring(body_error)) end
        end)

        test.it("replays committed placement intent with its frozen delivery", function()
            local prepared_attempt_id: string? = nil
            local body_ok, body_error = pcall(function()
                set_activation(true)
                local request = launch_request(fresh("attempt-replay"))
                local prepared_reply = call(OWNER, "prepare", request)
                test.is_true(prepared_reply.ok)
                local prepared_value = prepared_reply.value
                if type(prepared_value) ~= "table" then error("prepare did not return an attempt") end
                local prepared = prepared_value :: {[string]: unknown}
                prepared_attempt_id = prepared.attempt_id :: string

                local db = store.open()
                if not db then error("open placement store for frozen delivery") end
                local initial_row, initial_row_error = store.row(db, prepared_attempt_id)
                if not initial_row then db:release(); error(tostring(initial_row_error or "read committed attempt")) end
                local initial_request, initial_request_error = store.request(initial_row)
                if not initial_request or not initial_request.delivery then db:release(); error(tostring(initial_request_error or "read frozen delivery")) end
                local initial_delivery, initial_delivery_error = canonical.encode(initial_request.delivery)
                db:release()
                if not initial_delivery then error(tostring(initial_delivery_error or "encode frozen delivery")) end

                -- Change the registered implementation. A direct call proves the replacement is live.
                local builder_entry = registry.get(BUILDER)
                if not builder_entry then error("builder entry missing") end
                local builder_data = clone_object(builder_entry.data)
                builder_data.source = FAILING_BUILDER_SOURCE
                builder_entry.data = builder_data
                local builder_changes = registry.snapshot():changes()
                builder_changes:update(builder_entry)
                apply_changes(builder_changes, "replace registered builder")
                local direct_value, direct_error = caller(OWNER):call(BUILDER, {tag = "integration"})
                test.is_nil(direct_value)
                test.is_true(direct_error ~= nil and tostring(direct_error):find("builder deliberately fails after commit", 1, true) ~= nil)

                -- Identical prepare replays without calling the replaced builder.
                local replay_reply = call(OWNER, "prepare", request)
                test.is_true(replay_reply.ok)
                local replayed = replay_reply.value :: {[string]: unknown}
                test.eq(replayed.attempt_id, prepared.attempt_id)

                local replay_db = store.open()
                if not replay_db then error("open placement store after replay") end
                local replay_row, replay_row_error = store.row(replay_db, prepared_attempt_id)
                if not replay_row then replay_db:release(); error(tostring(replay_row_error or "read replayed attempt")) end
                local replay_request, replay_request_error = store.request(replay_row)
                if not replay_request or not replay_request.delivery then replay_db:release(); error(tostring(replay_request_error or "read replayed delivery")) end
                local replay_delivery, replay_delivery_error = canonical.encode(replay_request.delivery)
                replay_db:release()
                if not replay_delivery then error(tostring(replay_delivery_error or "encode replayed delivery")) end
                test.eq(replay_delivery, initial_delivery)

                cleanup_attempt(prepared_attempt_id)
                prepared_attempt_id = nil
            end)
            if prepared_attempt_id then cleanup_attempt(prepared_attempt_id) end
            if not body_ok then error(tostring(body_error)) end
        end)

        test.it("refuses launch when builder selection changes or digest is omitted", function()
            local body_ok, body_error = pcall(function()
                set_activation(true)
                local host_policy = registry.get(POLICY)
                if not host_policy then error("policy entry missing") end
                local saved_policy_data = clone_object(host_policy.data)

                -- 1. Create plan digest with original selection
                local original_digest = measure_policy_digest(POLICY)
                local request = launch_request(fresh("attempt-conflict"), original_digest)

                -- 2. Modify builder selection (change args) in policy
                local modified_data = clone_object(saved_policy_data)
                modified_data.instruction_builder = {
                    func_id = "bee.placement.native:fixture_builder_build",
                    args = {tag = "changed_selection"},
                }
                host_policy.data = modified_data
                local edits = registry.snapshot():changes()
                edits:update(host_policy)
                apply_changes(edits, "apply changed builder selection")

                -- Prepare with stale plan digest should fail with CONFLICT
                local conflict_reply = call(OWNER, "prepare", request)
                test.is_false(conflict_reply.ok)
                test.eq(conflict_reply.error and conflict_reply.error.code, "CONFLICT")

                -- Verify no attempt was recorded in store
                local db, db_error = store.open()
                if not db then error(tostring(db_error or "open placement store")) end
                local recorded = store.attempt(db, request.attempt_id :: string)
                db:release()
                test.is_nil(recorded)

                -- Restore policy
                host_policy.data = saved_policy_data
                local restore = registry.snapshot():changes()
                restore:update(host_policy)
                apply_changes(restore, "restore builder selection")

                -- 3. Launch without configuration_digest must fail with DENIED
                local no_digest_req = launch_request(fresh("attempt-no-digest"), original_digest)
                no_digest_req.configuration_digest = nil
                local denied_reply = call(OWNER, "prepare", no_digest_req)
                test.is_false(denied_reply.ok)
                test.eq(denied_reply.error and denied_reply.error.code, "DENIED")

                local db2 = assert(store.open())
                local recorded2 = store.attempt(db2, no_digest_req.attempt_id :: string)
                db2:release()
                test.is_nil(recorded2)
            end)
            if not body_ok then error(tostring(body_error)) end
        end)

        test.it("refuses launch before intent when builder fails or returns malformed output", function()
            local body_ok, body_error = pcall(function()
                set_activation(true)
                local host_policy = registry.get(POLICY)
                if not host_policy then error("policy entry missing") end
                local saved_policy_data = clone_object(host_policy.data)

                local function test_refusal_before_intent(builder_func: string, builder_args: {[string]: unknown}?)
                    local modified_data = clone_object(saved_policy_data)
                    modified_data.instruction_builder = {
                        func_id = builder_func,
                        args = builder_args or {},
                    }
                    host_policy.data = modified_data
                    local edits = registry.snapshot():changes()
                    edits:update(host_policy)
                    apply_changes(edits, "apply failing builder")

                    local digest = measure_policy_digest(POLICY)
                    local attempt_id = fresh("attempt-fail")
                    local request = launch_request(attempt_id, digest)
                    local reply = call(OWNER, "prepare", request)
                    test.is_false(reply.ok)
                    test.eq(reply.error and reply.error.code, "DENIED")

                    local db, db_error = store.open()
                    if not db then error(tostring(db_error or "open placement store")) end
                    local recorded = store.attempt(db, attempt_id)
                    db:release()
                    test.is_nil(recorded)
                end

                -- Builder errors
                test_refusal_before_intent("bee.driver:fixture_builder_error")

                -- Builder returns table instead of string
                test_refusal_before_intent("bee.driver:fixture_builder_bad_output")

                -- Builder returns control characters
                test_refusal_before_intent("bee.driver:fixture_builder_control_chars")

                -- Builder returns oversized output (> 4096 bytes)
                test_refusal_before_intent("bee.driver:fixture_builder_oversized")

                -- Restore original policy
                host_policy.data = saved_policy_data
                local restore = registry.snapshot():changes()
                restore:update(host_policy)
                apply_changes(restore, "restore failing builder")
            end)
            restore_registry_state(original)
            if not body_ok then error(tostring(body_error)) end
        end)
    end)
end

return test.run_cases(define_tests)
