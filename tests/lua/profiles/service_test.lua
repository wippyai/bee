-- MIT. Exercise the public facade with actual actor scopes and committed SQLite state.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local uuid = require("uuid")
local bounds = require("bounds")
local host = require("host")
local editor = require("editor")
local protocol = require("protocol")
local WORKSPACE = "saved-profile-workspace"
local function caller(id: string, grant: string?): funcs.Executor
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee.harness.profiles:test_call", grant or "bee.harness.profiles:test_call"}) do
        local policy, err = security.policy(name)
        if not policy then error(tostring(err)) end
        policies[#policies + 1] = policy
    end
    return funcs.new():with_actor(security.new_actor(id)):with_scope(security.new_scope(policies))
end
local function call(client: funcs.Executor, request: unknown): {[string]: unknown}
    local raw, err = client:call("bee.harness.binding:call", request)
    if err then error(tostring(err)) end
    local reply = bounds.object(raw)
    if not reply then error("malformed reply") end
    return reply
end
local function value(reply: {[string]: unknown}): {[string]: unknown}
    if reply.ok ~= true then error(tostring(reply.code) .. ": " .. tostring(reply.message)) end
    local result = bounds.object(reply.value)
    if not result then error("missing value") end
    return result
end
local function fresh(): string
    local id, err = uuid.v7()
    if not id then error(tostring(err)) end
    return id
end
local function put(id: string, revision: integer, key: string, title: string): {[string]: unknown}
    return {operation = "put", workspace_id = WORKSPACE, profile_id = id, expected_revision = revision, idempotency_key = key,
        profile = {schema_revision = "bee.agent-profile@3", name = title, definition_ref = "bee.driver.codex.profiles:research_batch", driver_binding_ref = "bee.driver.codex.binding:binding", provider = {}, bee = {mcp = {}}}}
end
local function define_tests()
    test.describe("Saved profile owner facade", function()
        test.it("rejects delegated writes of person-only folder trust even under an exact grant", function()
            local id = fresh()
            local request = put(id, 0, fresh(), "Trusted folder")
            local profile = assert(bounds.object(request.profile))
            profile.provider = {options = {folder_trust = "approved-workdir"}}
            local writer = caller("profile-authority", "bee.harness.profiles:test_write")
            local approved = value(call(writer, request))
            local agent = caller("profile-agent", "bee.harness.profiles:test_delegated_write"):with_actor(security.new_actor("profile-agent", {definition_id = "fixture:agent"}))
            agent = assert(agent:with_context({["bee.gateway.binding"] = {subject = "profile-agent", approving_grant_id = approved.grant_id}}))
            request.expected_revision, request.idempotency_key = 1, fresh()
            local denied = call(agent, request)
            test.eq(denied.ok, false)
            test.is_true(tostring(denied.message):find("person write", 1, true) ~= nil)
        end)

        test.it("round trips editor traits, role and context through profile CAS", function()
            local request = put(fresh(), 0, fresh(), "Edited")
            local original = assert(protocol.profile(request.profile))
            local settings = {options = {}, mcp_tools = {}, instructions = false}
            local draft = assert(editor.new(original, settings))
            test.is_true(editor.set_role(draft, "Inspect changes"))
            test.is_true(editor.cycle_trait(draft, "bee.tests.memory:trait"))
            test.is_true(editor.cycle_trait(draft, "bee.tests.memory:trait"))
            test.is_true(editor.set_context(draft, {{key = "project", value = "Bee"}, {key = "readonly", value = "false"}}))
            request.profile = assert(editor.result(draft))
            local writer = caller("profile-authority", "bee.harness.profiles:test_write")
            local saved = value(call(writer, request))
            local loaded = value(call(caller("profile-reader", "bee.harness.profiles:test_read"),
                {operation = "get", workspace_id = WORKSPACE, profile_id = saved.profile_id}))
            local restored = assert(editor.new(assert(protocol.profile(loaded.profile)), settings))
            test.eq(restored.role, "Inspect changes")
            test.eq(assert(restored.requestable)[1], "bee.tests.memory:trait")
            test.eq(assert(restored.context).readonly, false)
        end)
        test.it("persists role, requestable traits and bounded scalar context through the owner", function()
            local writer = caller("profile-authority", "bee.harness.profiles:test_write")
            local request = put(fresh(), 0, fresh(), "Researcher")
            local profile = assert(bounds.object(request.profile))
            profile.role = "Review changes"
            profile.requestable = {"bee.tests.memory:trait"}
            profile.context = {project = "Bee", iteration = 2, readonly = false}
            local saved = value(call(writer, request))
            local read = value(call(caller("profile-reader", "bee.harness.profiles:test_read"),
                {operation = "get", workspace_id = WORKSPACE, profile_id = saved.profile_id}))
            local restored = assert(bounds.object(read.profile))
            test.eq(restored.role, "Review changes")
            test.eq(assert(bounds.array(restored.requestable, 16))[1], "bee.tests.memory:trait")
            test.eq(assert(bounds.object(restored.context)).readonly, false)
            for _, context in ipairs({{["bee.workspace_id"] = "forged"}, {nested = {x = 1}}, {large = string.rep("x", 16385)}}) do
                profile.context = context
                test.eq(call(writer, request).ok, false)
            end
        end)
        test.it("retains every approving ancestor across successive delegated edits", function()
            local person = caller("profile-authority", "bee.harness.profiles:test_write")
            local id = fresh()
            local approved = value(call(person, put(id, 0, fresh(), "Person's profile")))
            local agent = caller("profile-agent", "bee.harness.profiles:test_delegated_write"):with_actor(security.new_actor("profile-agent", {definition_id = "fixture:agent"}))
            agent = assert(agent:with_context({["bee.gateway.binding"] = {subject = "profile-agent", approving_grant_id = approved.grant_id}}))
            local first = value(call(agent, put(id, 1, fresh(), "First delegated edit")))
            test.eq(first.grant_state, "active")
            agent = assert(agent:with_context({["bee.gateway.binding"] = {subject = "profile-agent", approving_grant_id = first.grant_id}}))
            local second = value(call(agent, put(id, 2, fresh(), "Second delegated edit")))
            test.eq(second.grant_state, "active")
        end)
        test.it("seeds a session through the person's approval rather than profile write authority", function()
            local session, question = host.open(true)
            local payload = assert(bounds.object(assert(bounds.object(question.proposal)).payload))
            test.eq(payload.session_ref, session.session)
            test.eq(assert(bounds.object(assert(bounds.array(payload.declarations, 16))[1])).id, host.TRAIT)
        end)
        test.it("never mints person consent for a delegated profile write", function()
            local agent = caller("profile-agent", "bee.harness.profiles:test_delegated_write"):with_actor(
                security.new_actor("profile-agent", {definition_id = "fixture:agent"}))
            local saved = call(agent, put(fresh(), 0, fresh(), "Delegated"))
            test.eq(saved.code, "DENIED")
        end)
        test.it("records the approving grant and refuses delegated capability escalation", function()
            local person = caller("profile-authority", "bee.harness.profiles:test_write")
            local original = put(fresh(), 0, fresh(), "Original")
            local approved = value(call(person, original))
            local agent = caller("profile-agent", "bee.harness.profiles:test_delegated_write"):with_actor(security.new_actor("profile-agent", {definition_id = "fixture:agent"}))
            agent = assert(agent:with_context({["bee.gateway.binding"] = {subject = "profile-agent", approving_grant_id = approved.grant_id}}))
            local request = put(fresh(), 0, fresh(), "Delegated")
            assert(bounds.object(request.profile)).active_traits = {"bee.tests.memory:trait"}
            local saved = value(call(agent, request))
            test.eq(saved.approving_grant_id, approved.grant_id)
            local raw_reply, err = person:call("bee.approvals.binding:grant", {operation = "read", grant_id = saved.grant_id})
            assert(not err, tostring(err))
            local grant = assert(bounds.object(value(assert(bounds.object(raw_reply))).grant))
            test.eq(assert(bounds.object(grant.provenance)).kind, "delegated")
            test.eq(grant.granted_by, "profile-authority")
            test.is_nil(grant.granted_definition)
            local escalation = put(fresh(), 0, fresh(), "Escalation")
            assert(bounds.object(escalation.profile)).bee = {mcp = {{tool = "app_tools", scope = {}}}}
            test.eq(call(agent, escalation).code, "DENIED")
            raw_reply, err = person:call("bee.approvals.binding:grant", {operation = "read", grant_id = approved.grant_id})
            assert(not err, tostring(err))
            local parent = assert(bounds.object(value(assert(bounds.object(raw_reply))).grant))
            raw_reply, err = person:call("bee.approvals.binding:grant", {operation = "revoke", grant_id = approved.grant_id, expected_revision = parent.revision})
            assert(not err, tostring(err)); value(assert(bounds.object(raw_reply)))
            local retained = value(call(caller("profile-reader", "bee.harness.profiles:test_read"), {operation = "get", workspace_id = WORKSPACE, profile_id = saved.profile_id}))
            test.eq(retained.grant_state, "revoked")
            test.eq(call(agent, put(fresh(), 0, fresh(), "After revocation")).code, "DENIED")
        end)
        test.it("accepts active trait preferences while keeping activation subject to consent", function()
            local request = put(fresh(), 0, fresh(), "Trait preferences")
            local profile = assert(bounds.object(request.profile))
            profile.active_traits = {"bee.tests.memory:trait"}
            local saved = value(call(caller("profile-authority", "bee.harness.profiles:test_write"), request))
            test.eq(assert(bounds.array(assert(bounds.object(saved.profile)).active_traits, 16))[1], "bee.tests.memory:trait")
        end)
        test.it("records saved authority as one revocable grant without deleting preferences", function()
            local writer = caller("profile-authority", "bee.harness.profiles:test_write")
            local id = fresh()
            local saved = value(call(writer, put(id, 0, fresh(), "Consent")))
            local grant_id = assert(bounds.id(saved.grant_id))
            test.eq(saved.grant_state, "active")
            local raw, err = writer:call("bee.approvals.binding:grant", {operation = "read", grant_id = grant_id})
            assert(not err, tostring(err))
            local grant = assert(bounds.object(value(assert(bounds.object(raw))).grant))
            test.eq(grant.domain, "profile_choices")
            test.eq(grant.granted_by, "profile-authority")
            test.is_nil(grant.granted_definition)
            raw, err = writer:call("bee.approvals.binding:grant", {operation = "revoke", grant_id = grant_id, expected_revision = grant.revision})
            assert(not err, tostring(err)); test.eq(assert(bounds.object(raw)).ok, true)
            local remaining = value(call(caller("profile-reader", "bee.harness.profiles:test_read"), {operation = "get", workspace_id = WORKSPACE, profile_id = id}))
            test.eq(remaining.grant_state, "revoked")
            test.eq(assert(bounds.object(remaining.profile)).name, "Consent")
            local updated = value(call(writer, put(id, 1, fresh(), "Reconsented")))
            test.eq(updated.grant_state, "active")
            test.neq(updated.grant_id, grant_id)
        end)
        test.it("denies ungranted and cross-workspace reads and writes", function()
            local outsider = caller("profile-outsider")
            local reader = caller("profile-reader", "bee.harness.profiles:test_read")
            test.eq(call(outsider, {operation = "list", workspace_id = WORKSPACE}).code, "DENIED")
            test.eq(call(reader, {operation = "list", workspace_id = "foreign"}).code, "DENIED")
            test.eq(call(reader, put(fresh(), 0, fresh(), "Denied")).code, "DENIED")
        end)
        test.it("uses host context for profile grants and refuses a foreign request", function()
            local grants: {security.Policy} = {}
            for _, name in ipairs({"bee.harness.profiles:test_call", "bee.harness.security:profile_workspace_policy", "bee.harness.security:profile_context_boundary"}) do
                local policy, err = security.policy(name)
                if not policy then error(tostring(err)) end
                grants[#grants + 1] = policy
            end
            local scope = security.new_scope(grants)
            local actor = security.new_actor("profile-context-client")
            local bound = funcs.new():with_context({["bee.workspace_id"] = WORKSPACE}):with_actor(actor):with_scope(scope)
            test.is_true(call(bound, {operation = "list", workspace_id = WORKSPACE}).ok)
            test.eq(call(bound, {operation = "list", workspace_id = "foreign"}).code, "DENIED")
            local unbound = funcs.new():with_context({["bee.workspace_id"] = ""}):with_actor(actor):with_scope(scope)
            test.eq(call(unbound, {operation = "list", workspace_id = WORKSPACE}).code, "DENIED")
            local probe, probe_error = bound:call("bee.harness.profiles:context_probe")
            if probe_error then error(tostring(probe_error)) end
            local checked = bounds.object(probe)
            if not checked then error("missing context substitution result") end
            test.is_true(checked.blocked)
            test.eq(scope:evaluate(actor, "funcs.context", "context"), "deny")
            test.eq(scope:evaluate(actor, "process.context", "context"), "deny")
        end)
        test.it("shares committed preferences across authorized clients and fences edits", function()
            local writer = caller("profile-writer", "bee.harness.profiles:test_write")
            local reader = caller("profile-reader", "bee.harness.profiles:test_read")
            local id, key = fresh(), fresh()
            local request = put(id, 0, key, "Original")
            test.eq(value(call(writer, request)).revision, 1)
            local saved = value(call(reader, {operation = "get", workspace_id = WORKSPACE, profile_id = id}))
            test.eq(saved.revision, 1)
            local profile = bounds.object(saved.profile)
            if not profile then error("missing profile") end
            test.eq(profile.name, "Original")
            local replay = call(writer, request)
            test.eq(replay.replayed, true)
            test.eq(value(replay).revision, 1)
            test.eq(call(writer, put(id, 0, fresh(), "Stale")).code, "CONFLICT")
            test.eq(call(writer, put(id, 1, key, "Reused key")).code, "CONFLICT")
            test.eq(value(call(writer, put(id, 1, fresh(), "Updated"))).revision, 2)
            local remove = {operation = "remove", workspace_id = WORKSPACE, profile_id = id, expected_revision = 2, idempotency_key = fresh()}
            test.eq(value(call(writer, remove)).revision, 3)
            test.eq(call(writer, remove).replayed, true)
            local retired = value(call(reader, {operation = "get", workspace_id = WORKSPACE, profile_id = id}))
            test.eq(retired.tombstone, true)
            test.is_nil(retired.profile)
            local historical = call(writer, request)
            test.eq(historical.replayed, true)
            test.eq(value(historical).revision, 1)
            test.eq(value(call(reader, {operation = "get", workspace_id = WORKSPACE, profile_id = id})).tombstone, true)
        end)
        test.it("lists without an initial key and invalidates a changed continuation", function()
            local writer = caller("profile-page-writer", "bee.harness.profiles:test_write")
            local reader = caller("profile-page-reader", "bee.harness.profiles:test_read")
            value(call(writer, put(fresh(), 0, fresh(), "First")))
            value(call(writer, put(fresh(), 0, fresh(), "Second")))
            local page = value(call(reader, {operation = "list", workspace_id = WORKSPACE, limit = 1}))
            test.eq(page.complete, false)
            value(call(writer, put(fresh(), 0, fresh(), "Third")))
            local stale = call(reader, {operation = "list", workspace_id = WORKSPACE, limit = 1, after_key = page.next_key, expected_cursor = page.cursor})
            test.eq(stale.code, "RESET_REQUIRED")
            local reset = bounds.object(stale.value)
            if not reset then error("missing reset cursor") end
            test.eq(reset.workspace_id, WORKSPACE)
            test.is_nil(reset.owner_id)
        end)
    end)
end
return test.run_cases(define_tests)
