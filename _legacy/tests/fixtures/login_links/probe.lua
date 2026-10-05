-- MIT. Proof uses synthetic fixture files only; no credential bytes are logged.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local env = require("env")
local fs = require("fs")
local locator = require("locator")
local agents = require("agents")
local sessions_fixtures = require("sessions_fixtures")
local sessions = require("sessions")
type Object = {[string]: unknown}
local WS, SUBJECT, ATTEMPT = "loginlinks-proof", "loginlinks-user", "loginlinks-attempt"
local function call(method: string, request: Object): principals.Reply
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee.credentials:client_test_policy", "bee.credentials.security:credential_manage_policy",
        "bee.credentials.security:credential_issue_policy", "bee.credentials.security:credential_materialize_policy"}) do
        policies[#policies + 1] = assert(security.policy(name))
    end
    local result, err = funcs.new():with_actor(principals.actor(SUBJECT, WS)):with_scope(security.new_scope(policies))
        :call("bee.credentials.binding:" .. method, request)
    if err then error(tostring(err)) end
    return principals.reply(result)
end
local function value(reply: principals.Reply): Object
    if not reply.ok then error(tostring(reply.error and reply.error.message)) end
    return assert(bounds.object(reply.value))
end
local function define_tests()
    local expected = assert(env.get("bee.test.loginlinks:expected"))
    local target = assert(env.get("bee.test.loginlinks:target"))
    assert(type(expected) == "string" and type(target) == "string")
    local accepted = expected == "accepted"
    local function refusal(message: string?)
        test.not_nil(message)
        if not message then error("missing refusal reason") end
        test.is_true(message:find(target, 1, true) ~= nil)
        test.is_true(message:find("group/other-writable", 1, true) ~= nil)
    end
    test.describe("Machine login links through broker and locate", function()
        test.it("uses the machine source entry and preserves the configured policy", function()
            local source = assert(registry.get("bee.env:machine_login_source"))
            test.eq(source.data.link_policy, "owner_safe")
            local volume = assert(fs.get("bee.env:machine_login_source"))
            local present, err = volume:exists(".codex/auth.json")
            test.eq(present, accepted)
            if accepted then test.is_nil(err) else refusal(tostring(err)) end
        end)
        test.it("reports metadata availability and projection check with refusal reasons", function()
            value(call("define", {workspace_id = WS, name = "login", provider = "codex",
                source = {kind = "fs_directory", ref = "bee.env:machine_login_source"}}))
            local availability = call("availability", {workspace_id = WS, name = "login"})
            if accepted then test.eq(value(availability).present, accepted)
            else test.eq(availability.error and availability.error.code, "UNAVAILABLE"); refusal(availability.error and availability.error.message) end
            local digest = string.rep("a", 64)
            local projection = value(call("issue_projection", {workspace_id = WS, name = "login", audience = SUBJECT,
                attempt_id = ATTEMPT, profile_id = "batch", profile_digest = digest, binding_digest = digest,
                launch_policy_digest = digest, idempotency_key = "loginlinks-issue"}))
            local projection_id = assert(bounds.id(projection.projection_id))
            local use: Object = {projection_id = projection_id, subject = SUBJECT, audience = SUBJECT, attempt_id = ATTEMPT}
            local checked = call("check", use)
            if accepted then test.eq(value(checked).source_present, accepted)
            else test.eq(checked.error and checked.error.code, "UNAVAILABLE"); refusal(checked.error and checked.error.message) end
            use.generation_key = "loginlinks-materialize"
            local materialized = call("materialize", use)
            if accepted then
                local result = value(materialized)
                test.eq(result.source_present, true)
                -- Compare only the synthetic fixture; never print the returned file.
                test.is_true(result.value == '{"fixture":true}')
            else
                test.eq(materialized.error and materialized.error.code, "UNAVAILABLE")
                refusal(materialized.error and materialized.error.message)
            end
        end)
        test.it("carries locate refusal into the person-facing login-needed state", function()
            local result = assert(locator.locate(assert(registry.snapshot()), "bee.driver.codex.binding:binding", "window", locator.new_cache()))
            test.eq(result.status, accepted and "ready" or "unconfigured")
            test.eq(result.login.exists, accepted)
            if not accepted then refusal(result.reason) end
            local client = sessions_fixtures.fixture_client({catalog = function(): (unknown, sessions.Fault?)
                return {items = {{ref = "bee.driver.codex.profiles:default_window", kind = "definition", title = "Codex",
                    status = result.status, checked_at = "2026-10-01T12:00:00.000Z", reasons = {result.reason or ""},
                    features = {"driver:codex", "presentation:start_menu"}, actions = {}}}, complete = true,
                    unavailable_count = accepted and 0 or 1, diagnostics = {}}, nil
            end})
            local listing = assert(agents.list(client, true))
            test.eq(listing.items[1].ready, accepted)
            if not accepted then refusal(listing.items[1].reason); test.is_true(listing.items[1].reason:find("Login needed", 1, true) ~= nil) end
        end)
    end)
end
return test.run_cases(define_tests)
