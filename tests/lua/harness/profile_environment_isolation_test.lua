-- MIT. Named launch definitions may share one driver profile while selecting
-- different host policies. This fixture proof starts both definitions before
-- either is awaited; each real child silently checks its own policy-only
-- environment and broker projection before replaying the standard JSONL run.
local test = require("test")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local env = require("env")
local time = require("time")
local json = require("json")
local admission = require("admission")

local ACTOR = "bee.test.profile_environment"
local ROOT = "bee.harness.catalog:project_fixture"
local SOURCE = "bee.harness.catalog:launch_sentinel_key"
local ALPHA = "bee.harness.catalog:profile_alpha_definition"
local BETA = "bee.harness.catalog:profile_beta_definition"
local ALPHA_POLICY = "bee.harness.catalog:profile_alpha_policy"
local BETA_POLICY = "bee.harness.catalog:profile_beta_policy"
local counter = 0

local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end

local scope_names = {"bee.harness.catalog:launch_client_policy", "bee.harness.catalog:carrier_client_policy", "bee.security.threads:thread_create_policy", "bee.security.threads:thread_observe_policy",
    "bee.security.threads:thread_lifecycle_policy", "bee.security.threads:thread_carrier_policy", "bee.security.harness:carrier_policy", "bee.harness.catalog:carrier_spawn_policy", "bee.security.resources:resource_manage_policy",
    "bee.security.resources:resource_grant_policy", "bee.security.credentials:credential_manage_policy", "bee.security.credentials:credential_issue_policy", "bee.security.harness:launch_spawn_policy"}
local function scope(): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(scope_names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end

local function call(target: string, request: unknown): {[string]: unknown}
    local result, err = funcs.new():with_actor(principals.actor(ACTOR, principals.workspace(request))):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    local reply = result :: admission.Reply
    if not reply.ok then error(target .. ": " .. tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value :: {[string]: unknown}
end

local function apply(entry: {[string]: unknown})
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("apply " .. tostring(entry.id) .. ": " .. tostring(err)) end
end

type FixturePaths = {bin: string, streams: string}
local function fixture_paths(): FixturePaths
    local bin, bin_error = env.get("bee.harness.catalog:fixture_bin")
    local streams, streams_error = env.get("bee.harness.catalog:fixture_streams")
    if bin_error or type(bin) ~= "string" or bin == "" or streams_error or type(streams) ~= "string" or streams == "" then
        error("fixture paths are not set for the test runtime")
    end
    return {bin = bin :: string, streams = streams :: string}
end

local function page(thread_id: string): {[string]: unknown}
    return call("bee.threads.service:read_after", {thread_id = thread_id, cursor = 0, limit = 64})
end

local function records(thread_id: string): {string}
    local result_page = page(thread_id)
    local result: {string} = {}
    for index, item in ipairs(result_page.records :: {{[string]: unknown}}) do result[index] = tostring(item.kind) end
    return result
end

local function receipt_outcome(thread_id: string): string
    for _, item in ipairs((page(thread_id).records :: {{[string]: unknown}})) do
        if item.kind == "receipt" then return tostring((item.body :: {[string]: unknown}).outcome) end
    end
    error("profile attempt has no durable receipt")
end

local function count(list: {string}, wanted: string): integer
    local total = 0
    for _, item in ipairs(list) do if item == wanted then total = total + 1 end end
    return total
end

local function await_receipt(thread_id: string, attempt_id: string): {[string]: unknown}
    for _ = 1, 600 do
        local observed, status = pcall(function(): {[string]: unknown}
            return call("bee.placement.native:status", {attempt_id = attempt_id})
        end)
        if observed and count(records(thread_id), "receipt") == 1 then
            local result = status :: {[string]: unknown}
            local attempt = result.attempt :: {[string]: unknown}
            if attempt.execution_state == "exited" then return result end
        end
        time.sleep("50ms")
    end
    error("profile attempt did not retain its receipt")
end

local function profile_policy(entry: {[string]: unknown}, bin: string, stream: string): {[string]: unknown}
    local data = entry.data :: {[string]: unknown}
    local configured: {[string]: unknown} = {}
    for key, item in pairs(data) do configured[key] = item end
    configured.executables = {claude = bin .. "/profile-probe"}
    local environment: {[string]: string} = {}
    for key, item in pairs(data.environment :: {[string]: string}) do environment[key] = item end
    environment.BEE_FIXTURE_STREAM = stream .. "/claude/stream-json-2/plain.jsonl"
    configured.environment = environment
    return configured
end

type Original = {entry: {[string]: unknown}, data: unknown}
local function restore(entries: {Original})
    for _, item in ipairs(entries) do apply(item.entry) end
end

local function define_tests()
    test.describe("Named profile policy environment isolation", function()
        test.it("runs overlapping named definitions for one Claude batch profile with distinct policy environments", function()
            local paths = fixture_paths()
            local original: {Original} = {}
            local policy_alpha = assert(registry.get(ALPHA_POLICY))
            local policy_beta = assert(registry.get(BETA_POLICY))
            local resource_roots = assert(registry.get("bee:resource_roots"))
            local roots = assert(registry.get("bee.placement.native:admitted_roots"))
            local mode = assert(registry.get("bee.placement.native:resource_mode"))
            local sources = assert(registry.get("bee:credential_sources"))
            original = {
                {entry = policy_alpha, data = policy_alpha.data},
                {entry = policy_beta, data = policy_beta.data},
                {entry = resource_roots, data = resource_roots.data},
                {entry = roots, data = roots.data},
                {entry = mode, data = mode.data},
                {entry = sources, data = sources.data},
            }
            local attempts: {string} = {}
            local ok, failure = pcall(function()
                policy_alpha.data = profile_policy(policy_alpha, paths.bin, paths.streams)
                policy_beta.data = profile_policy(policy_beta, paths.bin, paths.streams)
                local resource_data = resource_roots.data :: {[string]: unknown}
                local copied_resources: {{[string]: unknown}} = {}
                local resource_found = false
                for index, item in ipairs(resource_data.roots :: {{[string]: unknown}}) do
                    copied_resources[index] = item
                    if item.root_ref == ROOT then resource_found = true end
                end
                if not resource_found then copied_resources[#copied_resources + 1] = {root_ref = ROOT, access = "write"} end
                resource_roots.data = {roots = copied_resources}
                local roots_data = roots.data :: {[string]: unknown}
                local copied_roots: {{[string]: unknown}} = {}
                local found_root = false
                for index, item in ipairs(roots_data.roots :: {{[string]: unknown}}) do
                    copied_roots[index] = item
                    if item.root_ref == ROOT then found_root = true end
                end
                if not found_root then copied_roots[#copied_roots + 1] = {root_ref = ROOT, access = "write"} end
                roots.data = {roots = copied_roots}
                mode.data = {mode = "granted"}
                local sources_data = sources.data :: {[string]: unknown}
                local copied_sources: {{[string]: unknown}} = {}
                for index, item in ipairs(sources_data.sources :: {{[string]: unknown}}) do copied_sources[index] = item end
                copied_sources[#copied_sources + 1] = {ref = SOURCE, workspace_id = "*", audience = ACTOR, provider = "claude", projection_kinds = {"environment"}}
                sources.data = {sources = copied_sources, formats = sources_data.formats}
                local changes = registry.snapshot():changes()
                changes:update(policy_alpha)
                changes:update(policy_beta)
                changes:update(resource_roots)
                changes:update(roots)
                changes:update(mode)
                changes:update(sources)
                local applied, apply_error = changes:apply()
                if not applied then error("configure profile fixtures: " .. tostring(apply_error)) end

                local alpha_plan = call("bee.harness.launch:resolve", {definition_ref = ALPHA})
                local beta_plan = call("bee.harness.launch:resolve", {definition_ref = BETA})
                test.eq(alpha_plan.binding_ref, beta_plan.binding_ref)
                test.eq(alpha_plan.profile_id, "batch")
                test.eq(beta_plan.profile_id, "batch")
                test.eq(alpha_plan.policy_ref, ALPHA_POLICY)
                test.eq(beta_plan.policy_ref, BETA_POLICY)
                test.neq(alpha_plan.plan_digest, beta_plan.plan_digest)

                local workspace = fresh("profile-workspace")
                call("bee.resources.binding:associate", {workspace_id = workspace, name = "project", root_ref = ROOT, subpath = "", allowed_access = "write"})
                call("bee.credentials.binding:define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = SOURCE}})
                local alpha = call("bee.harness.launch:start", {request_id = fresh("profile-alpha"), definition_ref = ALPHA, workspace_id = workspace, brief = "ping"})
                attempts[#attempts + 1] = tostring(alpha.attempt_id)
                local beta = call("bee.harness.launch:start", {request_id = fresh("profile-beta"), definition_ref = BETA, workspace_id = workspace, brief = "ping"})
                attempts[#attempts + 1] = tostring(beta.attempt_id)
                for _, started in ipairs({alpha, beta}) do
                    local status = await_receipt(tostring(started.thread_id), tostring(started.attempt_id))
                    test.eq((status.attempt :: {[string]: unknown}).execution_state, "exited")
                    test.eq(((status.attempt :: {[string]: unknown}).exit :: {[string]: unknown}).code, 0)
                    local durable = records(tostring(started.thread_id))
                    test.eq(count(durable, "attempt.started"), 1)
                    test.eq(count(durable, "receipt"), 1)
                    test.eq(receipt_outcome(tostring(started.thread_id)), "succeeded")
                    local checkpoint = call("bee.threads.carrier:checkpoint", {thread_id = tostring(started.thread_id), attempt_id = tostring(started.attempt_id)})
                    test.eq(((checkpoint.checkpoint :: {[string]: unknown}).terminal :: {[string]: unknown}).answer, "pong")
                    test.eq((status.attempt :: {[string]: unknown}).attempt_id, started.attempt_id)
                    local thread_json = assert(json.encode(page(tostring(started.thread_id))))
                    local evidence = call("bee.placement.native:evidence", {attempt_id = tostring(started.attempt_id), limit = 64})
                    local evidence_json = assert(json.encode(evidence))
                    test.is_true(not thread_json:find("launch%-sentinel%-2b3c4d", 1, false))
                    test.is_true(not evidence_json:find("launch%-sentinel%-2b3c4d", 1, false))
                    local cleaned = call("bee.placement.native:cleanup", {attempt_id = tostring(started.attempt_id)})
                    test.eq(cleaned.cleanup_state, "complete")
                end
            end)
            -- Cleanup touches only attempts this test created. It also gives a
            -- failed assertion a best-effort exit/cleanup path before fixtures
            -- are restored for the next suite.
            for _, attempt_id in ipairs(attempts) do
                pcall(function() call("bee.placement.native:stop", {attempt_id = attempt_id, mode = "forced"}) end)
                pcall(function() call("bee.placement.native:cleanup", {attempt_id = attempt_id}) end)
            end
            local restored, restore_error = pcall(function()
                for _, item in ipairs(original) do item.entry.data = item.data end
                restore(original)
            end)
            if not restored then error("restore profile fixtures: " .. tostring(restore_error)) end
            if not ok then error(tostring(failure)) end
        end)
    end)
end

return test.run_cases(define_tests)
