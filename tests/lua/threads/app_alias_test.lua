-- MIT. Stable application alias: the broker attests each instance it opens
-- for the app's stable identity, and a reopened instance without its own
-- row still belongs through that stable family. A different app, an
-- unattested instance, or a left family stays refused.
local test = require("test")
local harness = require("harness")
local app_identity = require("app_identity")
local ALIAS_POLICY = "bee.security.threads:application_thread_alias_policy"
local WORKSPACE = string.rep("a", 32)
local OTHER_WORKSPACE = string.rep("b", 32)

local function stable(definition: string, workspace_id: string?): string
    return assert(app_identity.stable(workspace_id or WORKSPACE, definition)).id
end

local function instance(workspace_id: string?): string
    return "bee.application:" .. (workspace_id or WORKSPACE) .. ":" .. harness.key()
end

type Client = harness.Client

local function app_principal(id: string, grants: {string}, workspace_id: string?): Client
    return harness.principal(id, grants, workspace_id or WORKSPACE)
end

local function attest(broker: Client, definition: string, id: string, workspace_id: string?): {[string]: unknown}
    local selected_workspace = workspace_id or WORKSPACE
    local value: unknown = harness.value(broker:call("register_app_alias", {stable = stable(definition, selected_workspace),
        instance = id, workspace_id = selected_workspace, definition_id = definition}))
    if type(value) ~= "table" then error("application alias reply must be an object") end
    return value :: {[string]: unknown}
end

local function define_tests()
    test.describe("Application alias", function()
        test.it("attests each opened instance for the stable app", function()
            local broker = app_principal("broker", {ALIAS_POLICY})
            local definition, other_definition = "bee.alias_register:app", "bee.alias_register_other:app"
            local first, second = instance(), instance()
            local wanted = stable(definition)
            local first_reply = attest(broker, definition, first)
            test.eq(first_reply.stable, wanted)
            test.eq(first_reply.instance, first)
            local again = broker:call("register_app_alias", {stable = wanted,
                instance = first, workspace_id = WORKSPACE, definition_id = definition})
            test.is_true(again.ok and again.replayed)
            attest(broker, definition, second)
            local foreign = stable(other_definition)
            test.eq(harness.code(broker:call("register_app_alias", {stable = foreign,
                instance = first, workspace_id = WORKSPACE, definition_id = other_definition})), "CONFLICT")
            test.eq(harness.code(broker:call("register_app_alias", {stable = "not-an-app",
                instance = first, workspace_id = WORKSPACE, definition_id = definition})), "INVALID_ARGUMENT")
            local outsider = app_principal("outsider", {})
            test.eq(harness.code(outsider:call("register_app_alias", {stable = wanted,
                instance = instance(), workspace_id = WORKSPACE, definition_id = definition})), "DENIED")
            test.eq(harness.code(outsider:call("fence_app", {stable = wanted})), "DENIED")
            for _ = 1, 10 do attest(broker, definition, instance()) end
        end)
        test.it("keeps a reopened instance on the threads its app launched", function()
            local broker = app_principal("broker", {ALIAS_POLICY})
            local definition = "bee.alias_reopen:app"
            local wanted = stable(definition)
            local first = instance()
            local opener = app_principal(first, harness.ALL)
            local thread_id = harness.thread(opener, "App work")
            attest(broker, definition, first)
            local second = instance()
            local reopened = app_principal(second, {})
            test.eq(harness.code(reopened:call("get", {thread_id = thread_id})), "DENIED")
            attest(broker, definition, second)
            local seen = harness.value(reopened:call("get", {thread_id = thread_id}))
            test.eq(seen.membership.active, true)
            local posted = harness.value(reopened:call("record", {thread_id = thread_id,
                idempotency_key = harness.key(), kind = "message",
                body = harness.message("steer-1", "continue with the plan")}))
            test.eq(posted.sequence, 1)
            local read = harness.value(reopened:call("read_after", {thread_id = thread_id, cursor = 0, limit = 8}))
            test.eq(#read.records, 1)
            local listed = harness.value(reopened:call("list", {limit = 8}))
            local found = false
            for _, raw in ipairs(listed.threads :: {unknown}) do
                if (raw :: {[string]: unknown}).thread_id == thread_id then found = true end
            end
            test.is_true(found)
            local other_broker = app_principal("other-broker", {ALIAS_POLICY}, OTHER_WORKSPACE)
            local foreign_instance = instance(OTHER_WORKSPACE)
            attest(other_broker, definition, foreign_instance, OTHER_WORKSPACE)
            local foreign = app_principal(foreign_instance, {}, OTHER_WORKSPACE)
            test.eq(harness.code(foreign:call("get", {thread_id = thread_id})), "DENIED")
        end)
        test.it("does not fall through from an inactive member row to family membership", function()
            local broker = app_principal("inactive-member-broker", {ALIAS_POLICY})
            local definition = "bee.alias_inactive_member:app"
            local first = instance()
            local owner = app_principal(first, harness.ALL)
            local thread_id = harness.thread(owner, "App work")
            attest(broker, definition, first)

            local second = instance()
            local reopened = app_principal(second, {})
            attest(broker, definition, second)
            test.eq(harness.value(reopened:call("get", {thread_id = thread_id})).membership.active, true)
            harness.value(owner:call("join", {thread_id = thread_id, idempotency_key = harness.key(),
                member_id = second, role = "participant", expected_revision = 1}))
            harness.value(reopened:call("leave", {thread_id = thread_id, idempotency_key = harness.key(),
                member_id = second, expected_revision = 2}))
            test.eq(harness.code(reopened:call("get", {thread_id = thread_id})), "DENIED")
        end)
        test.it("keeps guest membership per instance and fences the family", function()
            local broker = app_principal("broker", {ALIAS_POLICY})
            local definition, other_definition = "bee.alias_fence:app", "bee.alias_fence_other:app"
            local wanted = stable(definition)
            local owner = app_principal("alias-fence-owner", harness.ALL)
            local thread_id = harness.thread(owner, "App work")
            local first = instance()
            harness.value(owner:call("join", {thread_id = thread_id, idempotency_key = harness.key(),
                member_id = first, role = "participant", expected_revision = 1}))
            attest(broker, definition, first)
            local other = instance()
            local other_app = app_principal(other, {})
            attest(broker, other_definition, other)
            test.eq(harness.code(other_app:call("get", {thread_id = thread_id})), "DENIED")
            local member = app_principal(first, {})
            local before = harness.value(member:call("get", {thread_id = thread_id}))
            test.eq(before.membership.active, true)
            local second = instance()
            local reopened = app_principal(second, {})
            attest(broker, definition, second)
            test.eq(harness.code(reopened:call("get", {thread_id = thread_id})), "DENIED")
            local fenced = harness.value(broker:call("fence_app", {stable = wanted}))
            test.eq(fenced.fenced, 1)
            test.eq(harness.code(member:call("get", {thread_id = thread_id})), "DENIED")
            local converged = harness.value(broker:call("fence_app", {stable = wanted}))
            test.eq(converged.fenced, 0)
        end)
    end)
end

return test.run_cases(define_tests)
