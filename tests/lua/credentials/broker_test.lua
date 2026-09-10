-- MIT. The credential broker with a sentinel secret: definitions stay under
-- the host allowlist, projections bind exactly, only an admitted
-- materializer receives bytes, and the sentinel never appears anywhere but
-- in that one reply.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local time = require("time")
local json = require("json")
local broker = require("broker")
local SENTINEL = "sentinel-secret-7f3a9c"
local SOURCE = "bee.credentials:sentinel_key"
local OTHER_SOURCE = "bee.credentials:other_key"
local BROKEN_SOURCE = "bee.credentials:broken_key"
local MANAGER, USER, OTHER, RUNNER = "bee.test.cred.manager", "bee.test.cred.user", "bee.test.cred.other", "bee.test.cred.runner"
local DIGEST = string.rep("c", 64)
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
local function caller(id: string, grants: {string}): funcs.Executor
    local names: {string} = {"bee.credentials:client_test_policy"}
    for _, grant in ipairs(grants) do names[#names + 1] = grant end
    return funcs.new():with_actor(security.new_actor(id)):with_scope(scope(names))
end
local manager = caller(MANAGER, {"bee:credential_manage_policy"})
local user = caller(USER, {"bee:credential_issue_policy"})
local other = caller(OTHER, {"bee:credential_issue_policy"})
local runner = caller(RUNNER, {"bee:credential_materialize_policy"})
local outsider = caller("bee.test.cred.outsider", {})
local function call(client: funcs.Executor, method: string, value: unknown): broker.Reply
    local reply, err = client:call("bee.credentials:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    return reply :: broker.Reply
end
local function value(reply: broker.Reply): {[string]: unknown}
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value :: {[string]: unknown}
end
local function code(reply: broker.Reply): string
    if reply.ok then error("expected a failure, got success") end
    return reply.error and reply.error.code or ""
end
local function clean(reply: broker.Reply)
    local encoded = json.encode(reply)
    if tostring(encoded):find(SENTINEL, 1, true) then error("sentinel leaked into a reply that must not carry it") end
end
local function admit_sources(workspace: string)
    local entry = registry.get("bee:credential_sources")
    if not entry then error("credential sources entry") end
    local data = entry.data :: {[string]: unknown}
    data.sources = {{ref = SOURCE, workspace_id = "*", audience = USER, provider = "claude", projection_kinds = {"environment"}},
        {ref = OTHER_SOURCE, workspace_id = workspace, audience = "*", provider = "codex", projection_kinds = {"environment"}},
        {ref = BROKEN_SOURCE, workspace_id = workspace, audience = "*", provider = "codex", projection_kinds = {"environment"}}}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("admit sources: " .. tostring(err)) end
end
local function issue(client: funcs.Executor, workspace: string, name: string, attempt: string, extra: {[string]: unknown}?): {[string]: unknown}
    local request: {[string]: unknown} = {workspace_id = workspace, name = name, audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST,
        binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")}
    for key, item in pairs(extra or {}) do request[key] = item end
    return value(call(client, "issue_projection", request))
end
local function define_tests()
    test.describe("Credential broker", function()
        local workspace = fresh("ws")
        admit_sources(workspace)
        test.it("defines credentials only from host-admitted sources, for managers, with digests that carry no bytes", function()
            test.eq(code(call(outsider, "define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = SOURCE}})), "DENIED")
            test.eq(code(call(manager, "define", {workspace_id = workspace, name = "anthropic", provider = "codex", source = {kind = "env_variable", ref = SOURCE}})), "FORBIDDEN")
            test.eq(code(call(manager, "define", {workspace_id = fresh("ws"), name = "openai", provider = "codex", source = {kind = "env_variable", ref = OTHER_SOURCE}})), "FORBIDDEN")
            test.eq(code(call(manager, "define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_file_key", ref = SOURCE}})), "INVALID")
            local defined = value(call(manager, "define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = SOURCE}}))
            test.eq(defined.destination, "ANTHROPIC_API_KEY")
            test.eq(defined.revision, 1)
            test.is_nil(tostring(json.encode(defined)):find(SENTINEL, 1, true))
            local openai = value(call(manager, "define", {workspace_id = workspace, name = "openai", provider = "codex", source = {kind = "env_variable", ref = OTHER_SOURCE}}))
            test.eq(openai.destination, "OPENAI_API_KEY")
            local listed = value(call(manager, "list", {workspace_id = workspace}))
            test.eq(#(listed.definitions :: {unknown}), 2)
            clean(call(manager, "list", {workspace_id = workspace}))
        end)
        test.it("issues projections to the authenticated subject and materializes bytes once for the admitted materializer only", function()
            local attempt = fresh("attempt")
            test.eq(code(call(outsider, "issue_projection", {workspace_id = workspace, name = "anthropic", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")})), "DENIED")
            local projection = issue(user, workspace, "anthropic", attempt)
            test.eq(projection.subject, USER)
            test.eq(projection.destination, "ANTHROPIC_API_KEY")
            test.eq(projection.materializer, "bee.placement.native:binding")
            test.eq(projection.materialization_generation, 0)
            clean(call(user, "issue_projection", {workspace_id = workspace, name = "anthropic", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")}))
            local id = projection.projection_id :: string
            test.eq(code(call(user, "check", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt})), "DENIED")
            test.eq(code(call(user, "materialize", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "g1"})), "DENIED")
            local checked = value(call(runner, "check", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt}))
            test.eq(checked.projection_id, id)
            clean(call(runner, "check", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt}))
            test.eq(code(call(runner, "materialize", {projection_id = id, subject = OTHER, audience = USER, attempt_id = attempt, generation_key = "g1"})), "DENIED")
            test.eq(code(call(runner, "materialize", {projection_id = id, subject = USER, audience = OTHER, attempt_id = attempt, generation_key = "g1"})), "DENIED")
            test.eq(code(call(runner, "materialize", {projection_id = id, subject = USER, audience = USER, attempt_id = "attempt-else", generation_key = "g1"})), "DENIED")
            local materialized = value(call(runner, "materialize", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "g1"}))
            test.eq(materialized.value, SENTINEL)
            test.eq(materialized.destination, "ANTHROPIC_API_KEY")
            test.eq(materialized.encoding, "utf-8")
            test.eq(materialized.generation, 1)
            test.eq(code(call(runner, "materialize", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "g1"})), "CONFLICT")
            local again = value(call(runner, "materialize", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "g2"}))
            test.eq(again.generation, 2)
            local after = value(call(runner, "check", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt}))
            test.eq(after.materialization_generation, 2)
            clean(call(runner, "check", {projection_id = id, subject = USER, audience = USER, attempt_id = attempt}))
            clean(call(manager, "list", {workspace_id = workspace}))
            local replay = value(call(user, "issue_projection", {workspace_id = workspace, name = "anthropic", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = "replay-" .. attempt}))
            local same = value(call(user, "issue_projection", {workspace_id = workspace, name = "anthropic", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = "replay-" .. attempt}))
            test.eq(same.projection_id, replay.projection_id)
            test.eq(code(call(user, "issue_projection", {workspace_id = workspace, name = "anthropic", audience = USER, attempt_id = "attempt-other", profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = "replay-" .. attempt})), "CONFLICT")
        end)
        test.it("refuses values an environment cannot carry without echoing them", function()
            local attempt = fresh("attempt")
            value(call(manager, "define", {workspace_id = workspace, name = "broken", provider = "codex", source = {kind = "env_variable", ref = BROKEN_SOURCE}}))
            local projection = issue(user, workspace, "broken", attempt)
            local refused = call(runner, "materialize", {projection_id = projection.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "g"})
            test.eq(code(refused), "INVALID")
            if tostring(json.encode(refused)):find("secret-9d8e7f", 1, true) then error("broken value leaked into the refusal") end
        end)
        test.it("stops materializing on expiry, revocation, epoch advance and redefinition, and reads the source at each materialization", function()
            local attempt = fresh("attempt")
            local short = issue(user, workspace, "anthropic", attempt, {ttl_ms = 1})
            time.sleep("20ms")
            test.eq(code(call(runner, "materialize", {projection_id = short.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "g"})), "EXPIRED")
            local revocable = issue(user, workspace, "anthropic", attempt)
            test.eq(code(call(other, "revoke", {projection_id = revocable.projection_id})), "DENIED")
            clean(call(user, "revoke", {projection_id = revocable.projection_id}))
            test.eq(code(call(runner, "check", {projection_id = revocable.projection_id, subject = USER, audience = USER, attempt_id = attempt})), "REVOKED")
            local epochal = issue(user, workspace, "anthropic", attempt)
            value(call(runner, "check", {projection_id = epochal.projection_id, subject = USER, audience = USER, attempt_id = attempt}))
            test.eq(code(call(user, "revoke_all", {workspace_id = workspace})), "DENIED")
            value(call(manager, "revoke_all", {workspace_id = workspace}))
            test.eq(code(call(runner, "materialize", {projection_id = epochal.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "g"})), "REVOKED")
            local renewed = issue(user, workspace, "anthropic", attempt)
            test.eq(renewed.authorization_epoch, 1)
            value(call(runner, "check", {projection_id = renewed.projection_id, subject = USER, audience = USER, attempt_id = attempt}))
            local redefined = value(call(manager, "define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = SOURCE}}))
            test.eq(redefined.revision, 2)
            test.eq(code(call(runner, "check", {projection_id = renewed.projection_id, subject = USER, audience = USER, attempt_id = attempt})), "CONFLICT")
            local foreign_audience = code(call(user, "issue_projection", {workspace_id = workspace, name = "anthropic", audience = OTHER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")}))
            test.eq(foreign_audience, "FORBIDDEN")
            local live = issue(user, workspace, "anthropic", attempt)
            value(call(runner, "check", {projection_id = live.projection_id, subject = USER, audience = USER, attempt_id = attempt}))
            local entry = registry.get("bee:credential_sources")
            if not entry then error("sources entry") end
            local data = entry.data :: {[string]: unknown}
            data.sources = {{ref = OTHER_SOURCE, workspace_id = workspace, audience = "*", provider = "codex", projection_kinds = {"environment"}}}
            local changes = registry.snapshot():changes()
            changes:update(entry)
            local applied, apply_error = changes:apply()
            if not applied then error("remove source: " .. tostring(apply_error)) end
            test.eq(code(call(runner, "materialize", {projection_id = live.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "removed"})), "FORBIDDEN")
            admit_sources(workspace)
            local reported = value(call(outsider, "capabilities", {}))
            test.eq(reported.repeat_generation, "refused")
            test.eq(reported.file_projections, false)
            test.eq(reported.provider_revocation, false)
            test.eq(reported.rotation, "next_materialization")
            test.eq(reported.revocation_enforcement, "stop_on_reconcile")
        end)
    end)
end
return test.run_cases(define_tests)
