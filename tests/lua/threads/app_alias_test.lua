-- MIT. Stable application alias: the broker attests each instance it opens
-- for the app's stable identity, and a reopened instance without its own
-- row still belongs through that stable family. A different app, an
-- unattested instance, or a left family stays refused.
local test = require("test")
local harness = require("harness")
local app_identity = require("app_identity")
local ALIAS_POLICY = "bee.security.threads:application_thread_alias_policy"
local WORKSPACE = string.rep("a", 32)

local function stable(definition: string): string
    return assert(app_identity.stable(WORKSPACE, definition)).id
end

local function instance(): string
    return "bee.application:" .. WORKSPACE .. ":" .. harness.key()
end

local function app_principal(id: string, grants: {string})
    return harness.principal(id, grants, WORKSPACE)
end

local function attest(broker: unknown, definition: string, id: string)
    local caller = broker :: {call: (unknown, string, {[string]: unknown}) -> {[string]: unknown}}
    return harness.value(caller:call("register_app_alias", {stable = stable(definition),
        instance = id, workspace_id = WORKSPACE, definition_id = definition}))
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
            test.eq(harness.code(outsider:call("app_family", {stable = wanted})), "DENIED")
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
        end)
        test.it("refuses another app and a fenced family", function()
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
            local family = harness.value(broker:call("app_family", {stable = wanted}))
            test.eq(#family.threads, 1)
            test.eq(family.threads[1].thread_id, thread_id)
            test.eq(family.threads[1].actor, first)
            local member = app_principal(first, {})
            local left = harness.value(member:call("leave", {thread_id = thread_id,
                idempotency_key = harness.key(), member_id = first, expected_revision = 2}))
            test.is_false(left.active)
            local second = instance()
            local reopened = app_principal(second, {})
            attest(broker, definition, second)
            test.eq(harness.code(reopened:call("get", {thread_id = thread_id})), "DENIED")
            local empty = harness.value(broker:call("app_family", {stable = wanted}))
            test.eq(#empty.threads, 0)
        end)
    end)
end

return test.run_cases(define_tests)
