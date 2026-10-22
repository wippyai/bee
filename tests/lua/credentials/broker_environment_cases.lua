-- MIT. Focused broker test cases.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local registry = require("registry")
local json = require("json")
local credential_protocol = require("credential_protocol")
local store = require("store")
local support = require("support")
local OTHER = support.OTHER
local USER = support.USER
local SENTINEL = support.SENTINEL
local SOURCE = support.SOURCE
local MISSING_SOURCE = support.MISSING_SOURCE
local OTHER_SOURCE = support.OTHER_SOURCE
local BROKEN_SOURCE = support.BROKEN_SOURCE
local DIGEST = support.DIGEST
local fresh = support.fresh
local caller = support.caller
local bound = support.bound
local with_clock = support.with_clock
local advance = support.advance
local manager = support.manager
local user = support.user
local other = support.other
local runner = support.runner
local outsider = support.outsider
local call = support.call
local async_call = support.async_call
local await_call = support.await_call
local value = support.value
local code = support.code
local clean = support.clean
local admit_sources = support.admit_sources
local issue = support.issue
local M = {}
function M.define(workspace: string, shipped_sources: registry.Entry)
    test.it("defines credentials only from host-admitted sources, for managers, with digests that carry no bytes", function()
        test.eq(code(call(outsider, "define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = SOURCE}})), "DENIED")
        test.eq(code(call(manager, "define", {workspace_id = workspace, name = "anthropic", provider = "codex", source = {kind = "env_variable", ref = SOURCE}})), "FORBIDDEN")
        test.eq(code(call(manager, "define", {workspace_id = fresh("ws"), name = "openai", provider = "codex", source = {kind = "env_variable", ref = OTHER_SOURCE}})), "FORBIDDEN")
        test.eq(code(call(manager, "define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_file_key", ref = SOURCE}})), "INVALID")
        local defined = value(call(manager, "define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = SOURCE}}))
        test.eq(defined.destination, "ANTHROPIC_API_KEY")
        test.eq(defined.revision, 1)
        test.eq(defined.optional, false)
        test.is_nil((tostring(json.encode(defined)):find(SENTINEL, 1, true)))
        local openai = value(call(manager, "define", {workspace_id = workspace, name = "openai", provider = "codex", source = {kind = "env_variable", ref = OTHER_SOURCE}}))
        test.eq(openai.destination, "OPENAI_API_KEY")
        local listed = value(call(manager, "list", {workspace_id = workspace}))
        test.eq(#(principals.items(listed.definitions)), 2)
        clean(call(manager, "list", {workspace_id = workspace}))
    end)
    test.it("first-use credential creation and stale updates preserve the existing definition and projection", function()
        local name = fresh("login")
        local request = {workspace_id = workspace, name = name, provider = "claude", source = {kind = "env_variable", ref = SOURCE}, expected_revision = 0}
        local created = value(call(manager, "define", request))
        test.eq(created.revision, 1)
        local attempt = fresh("attempt")
        local projection = issue(user, workspace, name, attempt)
        test.eq(code(call(manager, "define", request)), "CONFLICT")
        local checked = value(call(runner, "check", {projection_id = projection.projection_id, subject = USER, audience = USER, attempt_id = attempt}))
        test.eq(checked.projection_id, projection.projection_id)
        request.expected_revision = 1
        local replaced = value(call(manager, "define", request))
        test.eq(replaced.revision, 2)
        test.eq(code(call(manager, "define", request)), "CONFLICT")
        request.expected_revision = -1
        test.eq(code(call(manager, "define", request)), "INVALID")
        request.expected_revision = 0.5
        test.eq(code(call(manager, "define", request)), "INVALID")
        local optional_name = fresh("optional-env")
        local optional = value(call(manager, "define", {workspace_id = workspace, name = optional_name, provider = "claude", source = {kind = "env_variable", ref = MISSING_SOURCE}, optional = true}))
        test.eq(optional.optional, true)
        local optional_attempt = fresh("attempt")
        local optional_projection = issue(user, workspace, optional_name, optional_attempt)
        local absent = value(call(runner, "materialize", {projection_id = optional_projection.projection_id, subject = USER, audience = USER,
            attempt_id = optional_attempt, generation_key = fresh("generation")}))
        test.eq(absent.projection_kind, "environment")
        test.eq(absent.destination, "ANTHROPIC_API_KEY")
        test.eq(absent.optional, true)
        test.eq(absent.present, false)
        test.is_nil(absent.value)
        test.eq(code(call(manager, "define", {workspace_id = workspace, name = fresh("optional-type"), provider = "claude", source = {kind = "env_variable", ref = SOURCE}, optional = "true"})), "INVALID")
    end)
    test.it("issues and materializes projections only in the workspace the principal is bound to", function()
        local attempt = fresh("attempt")
        local request = {workspace_id = workspace, name = "anthropic", audience = USER, attempt_id = attempt, profile_id = "batch",
            profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")}
        local elsewhere = fresh("elsewhere")
        for _, bound_to in ipairs({elsewhere, false}) do
            local reply, err = bound(user, bound_to or nil):call("bee.credentials.binding:issue_projection", request)
            if err then error(tostring(err)) end
            test.eq(code(principals.reply(reply)), "DENIED")
        end
        local projection = issue(user, workspace, "anthropic", attempt)
        local app_runner = caller("bee.test.cred.app_runner", {"bee.credentials.security:credential_materialize_workspace_policy"})
        local use = {projection_id = projection.projection_id, subject = USER, audience = USER, attempt_id = attempt}
        local foreign, foreign_error = bound(app_runner, elsewhere):call("bee.credentials.binding:check", use)
        if foreign_error then error(tostring(foreign_error)) end
        test.eq(code(principals.reply(foreign)), "DENIED")
        local own, own_error = bound(app_runner, workspace):call("bee.credentials.binding:check", use)
        if own_error then error(tostring(own_error)) end
        test.eq((value(principals.reply(own))).projection_id, projection.projection_id)
    end)
    test.it("issues projections to the authenticated subject and materializes bytes once for the admitted materializer only", function()
        local attempt = fresh("attempt")
        test.eq(code(call(outsider, "issue_projection", {workspace_id = workspace, name = "anthropic", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")})), "DENIED")
        local projection = issue(user, workspace, "anthropic", attempt)
        test.eq(projection.subject, USER)
        test.eq(projection.destination, "ANTHROPIC_API_KEY")
        test.eq(projection.materializer, "bee.placement.native.binding:binding")
        test.eq(projection.materialization_generation, 0)
        clean(call(user, "issue_projection", {workspace_id = workspace, name = "anthropic", audience = USER, attempt_id = attempt, profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = fresh("key")}))
        local id = projection.projection_id
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
        local replay_key = fresh("complete-replay")
        local original: {[string]: unknown} = {workspace_id = workspace, name = "anthropic", audience = USER, attempt_id = fresh("attempt"),
            profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST,
            idempotency_key = replay_key, ttl_ms = 60000}
        value(call(user, "issue_projection", original))
        local conflicts: {{[string]: unknown}} = {
            {workspace_id = fresh("workspace")}, {audience = OTHER}, {profile_id = "interactive"},
            {profile_digest = string.rep("d", 64)}, {binding_digest = string.rep("e", 64)},
            {launch_policy_digest = string.rep("f", 64)}, {name = "another-name"}, {ttl_ms = 60001},
        }
        for _, changes in ipairs(conflicts) do
            local changed: {[string]: unknown} = {}
            for key, item in pairs(original) do changed[key] = item end
            for key, item in pairs(changes) do changed[key] = item end
            test.eq(code(call(user, "issue_projection", changed)), "CONFLICT", tostring(next(changes)))
        end
    end)
    test.it("projects entered Agy Grok and Muse keys without recording their values", function()
        local before = assert(registry.get("bee.credentials.env:credential_sources"))
        local selected = assert(registry.snapshot()):changes()
        selected:update(shipped_sources)
        assert(selected:apply())
        local ok, failure = pcall(function()
        for _, row in ipairs({{provider = "agy", destination = "GEMINI_API_KEY"},
            {provider = "grok", destination = "XAI_API_KEY"}, {provider = "muse", destination = "META_API_KEY"}}) do
            local ws, attempt = fresh(row.provider), fresh("entered-key-attempt")
            local ref = "bee.drivers." .. row.provider .. ".env:api_key"
            local secret = "fixture-entered-" .. row.provider .. "-832a"
            local defined = value(call(manager, "define", {workspace_id = ws, name = "api_key", provider = row.provider,
                source = {kind = "env_variable", ref = ref}}))
            test.eq(defined.destination, row.destination)
            local stored = call(manager, "set_value", {workspace_id = ws, name = "api_key", value = secret})
            test.is_true(stored.ok)
            local projected = issue(user, ws, "api_key", attempt)
            local materialized = value(call(runner, "materialize", {projection_id = projected.projection_id, subject = USER,
                audience = USER, attempt_id = attempt, generation_key = "entered-key"}))
            test.eq(materialized.destination, row.destination)
            test.eq(materialized.value, secret)
            for _, safe in ipairs({stored, call(manager, "list", {workspace_id = ws}), assert(registry.get(ref))}) do
                test.is_nil((assert(json.encode(safe)):find(secret, 1, true)))
            end
        end
        end)
        local restore = assert(registry.snapshot()):changes()
        restore:update(before)
        assert(restore:apply())
        if not ok then error(tostring(failure)) end
    end)
    test.it("holds a person-entered custom provider key outside credential and registry records", function()
        local ws, attempt = fresh("custom-provider"), fresh("custom-provider-attempt")
        local secret = "custom-provider-fixture-value-832a"
        local defined = value(call(manager, "define", {workspace_id = ws, name = "custom", provider = "local_endpoint",
            source = {kind = "env_variable", ref = "bee.tests.credentials:custom_key"}}))
        test.eq(defined.destination, "LOCAL_ENDPOINT_API_KEY")
        local stored = call(manager, "set_value", {workspace_id = ws, name = "custom", value = secret})
        test.is_true(stored.ok)
        test.is_true(not assert(json.encode(stored)):find(secret, 1, true))
        test.eq(code(call(outsider, "set_value", {workspace_id = ws, name = "custom", value = secret})), "DENIED")
        local projected = issue(user, ws, "custom", attempt)
        local materialized = value(call(runner, "materialize", {projection_id = projected.projection_id, subject = USER,
            audience = USER, attempt_id = attempt, generation_key = "custom-key"}))
        test.eq(materialized.destination, "LOCAL_ENDPOINT_API_KEY")
        test.eq(materialized.value, secret)
        local listed = call(manager, "list", {workspace_id = ws})
        local checked = call(runner, "check", {projection_id = projected.projection_id, subject = USER, audience = USER, attempt_id = attempt})
        for _, object in ipairs({listed, checked, assert(registry.get("bee.tests.credentials:custom_key"))}) do
            test.is_true(not assert(json.encode(object)):find(secret, 1, true))
        end
        local db = assert(store.open())
        local definitions = assert(db:query("SELECT * FROM bee_credential_definitions WHERE workspace_id = ?", {ws}))
        local projections = assert(db:query("SELECT * FROM bee_credential_projections WHERE workspace_id = ?", {ws}))
        db:release()
        test.is_true(not assert(json.encode({definitions, projections})):find(secret, 1, true))
    end)
    test.it("reserves unique monotonic materialization generations under concurrent calls", function()
        local attempt = fresh("parallel-materialization")
        local projection = issue(user, workspace, "anthropic", attempt)
        local projection_id = projection.projection_id
        local first_key, second_key = fresh("generation-a"), fresh("generation-b")
        local first_future = async_call(runner, "materialize", {projection_id = projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation_key = first_key})
        local second_future = async_call(runner, "materialize", {projection_id = projection_id, subject = USER, audience = USER,
            attempt_id = attempt, generation_key = second_key})
        local first_result, second_result = await_call(first_future), await_call(second_future)
        test.is_true(first_result.ok, tostring(first_result.error and first_result.error.message))
        test.is_true(second_result.ok, tostring(second_result.error and second_result.error.message))
        local first_generation = value(first_result).generation
        local second_generation = value(second_result).generation
        test.is_true(first_generation ~= second_generation)
        test.eq(math.min(first_generation, second_generation), 1)
        test.eq(math.max(first_generation, second_generation), 2)
        local checked = value(call(runner, "check", {projection_id = projection_id, subject = USER, audience = USER, attempt_id = attempt}))
        test.eq(checked.materialization_generation, 2)
        local db, open_error = store.open()
        if not db then error("open db: " .. tostring(open_error)) end
        local rows, query_error = db:query("SELECT generation_key, generation FROM bee_credential_generations WHERE projection_id = ?", {projection_id})
        db:release()
        if not rows then error("query materialization generations: " .. tostring(query_error)) end
        test.eq(#rows, 2)
        local reserved: {[string]: number} = {}
        for _, row in ipairs(rows) do reserved[tostring(row.generation_key)] = row.generation end
        test.eq(reserved[first_key], first_generation)
        test.eq(reserved[second_key], second_generation)
    end)
    test.it("refuses values an environment cannot carry without echoing them", function()
        local attempt = fresh("attempt")
        value(call(manager, "define", {workspace_id = workspace, name = "broken", provider = "codex", source = {kind = "env_variable", ref = BROKEN_SOURCE}}))
        local projection = issue(user, workspace, "broken", attempt)
        local refused = call(runner, "materialize", {projection_id = projection.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "g"})
        test.eq(code(refused), "INVALID")
        if tostring(json.encode(refused)):find("secret-9d8e7f", 1, true) then error("broken value leaked into the refusal") end
    end)
    test.it("renews the projections of a live attempt for its materializer past their first term, and never an ended one", function()
        with_clock(function()
            local live_attempt, idle_attempt = fresh("lease-live"), fresh("lease-idle")
            local function check(projection: {[string]: unknown}, attempt: string): credential_protocol.Reply
                return call(runner, "check", {projection_id = projection.projection_id, subject = USER, audience = USER, attempt_id = attempt})
            end
            local function renew(attempt: string): {[string]: unknown}
                return value(call(runner, "renew_attempt", {attempt_id = attempt, subject = USER, audience = USER}))
            end
            local live = issue(user, workspace, "anthropic", live_attempt, {ttl_ms = 2000})
            local idle = issue(user, workspace, "anthropic", idle_attempt, {ttl_ms = 2000})
            local revoked = issue(user, workspace, "anthropic", live_attempt, {ttl_ms = 2000})
            test.eq(code(call(user, "renew_attempt", {attempt_id = live_attempt, subject = USER, audience = USER})), "DENIED")
            test.eq(renew(live_attempt).renewed, 0)
            test.eq(value(check(live, live_attempt)).expires_at, live.expires_at)
            clean(call(user, "revoke", {projection_id = revoked.projection_id}))
            advance(1100)
            test.eq(renew(live_attempt).renewed, 1)
            advance(1100)
            value(check(live, live_attempt))
            test.eq(code(check(idle, idle_attempt)), "EXPIRED")
            test.eq(code(check(revoked, live_attempt)), "REVOKED")
            test.eq(renew(idle_attempt).renewed, 0)
            test.eq(code(check(idle, idle_attempt)), "EXPIRED")
        end)
    end)
    test.it("stops materializing on expiry, revocation, epoch advance and redefinition, and reads the source at each materialization", function()
        local attempt = fresh("attempt")
        with_clock(function()
            local short = issue(user, workspace, "anthropic", attempt, {ttl_ms = 1})
            advance(20)
            test.eq(code(call(runner, "materialize", {projection_id = short.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "g"})), "EXPIRED")
        end)
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
        local entry = registry.get("bee.credentials.env:credential_sources")
        if not entry then error("sources entry") end
        local data = assert(bounds.object(entry.data))
        data.sources = {{ref = OTHER_SOURCE, workspace_id = workspace, audience = "*", provider = "codex", projection_kinds = {"environment"}}}
        local changes = registry.snapshot():changes()
        changes:update(entry)
        local applied, apply_error = changes:apply()
        if not applied then error("remove source: " .. tostring(apply_error)) end
        test.eq(code(call(runner, "materialize", {projection_id = live.projection_id, subject = USER, audience = USER, attempt_id = attempt, generation_key = "removed"})), "FORBIDDEN")
        admit_sources(workspace)
        local reported = value(call(outsider, "capabilities", {}))
        test.eq(reported.repeat_generation, "refused")
        test.eq(reported.file_projections, true)
        test.eq(reported.provider_revocation, false)
        test.eq(reported.rotation, "next_materialization")
        test.eq(reported.revocation_enforcement, "stop_on_reconcile")
        test.eq(reported.max_file_bytes, 65536)
        local kinds = principals.strings(reported.projection_kinds)
        test.eq(kinds[1], "environment")
        test.eq(kinds[2], "file")
        local fdest = reported.file_destinations
        test.eq(fdest.claude, ".credentials.json")
        test.eq(fdest.codex, "auth.json")
    end)
end
return M
