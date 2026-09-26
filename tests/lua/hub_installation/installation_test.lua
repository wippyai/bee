-- MIT. Installation request values: decoding, plan selection, the approval
-- body a person decides on, ownership of a recorded request and the outcome
-- an apply reply reports. Pure; no Hub or approval owner runs.
local test = require("test")
local installation = require("installation")
type Object = {[string]: unknown}
local DIGEST = string.rep("a", 64)
local CONTEXT = {thread_id = "thread-1", action_id = "action-1", attempt_id = "attempt-1"}

local function plan(overrides: Object?): Object
    local value: Object = {digest = DIGEST, ready = true, base_revision = 7,
        request = {action = "install", component = "acme/tool", version = "1.2.0", migration_policy = "up", parameters = {}},
        modules = {
            {component = "acme/tool", version = "1.2.0", previous_version = "", change = "install"},
            {component = "acme/lib", version = "2.0.0", previous_version = "1.0.0", change = "update"},
            {component = "acme/old", version = "", previous_version = "0.3.0", change = "remove"},
            {component = "bee/core", version = "0.1.0", previous_version = "0.1.0", change = "keep"},
        },
        policy_changes = {
            {id = "acme.tool:files", component = "acme/tool", change = "add", actions = {"fs.get", "fs.list"},
                resources = {"acme.tool:data"}, expression = false},
            {id = "acme.lib:net", component = "acme/lib", change = "update", actions = {"http_client.request"},
                resources = {"*"}, expression = true},
            {id = "acme.old:reader", component = "acme/old", change = "remove", actions = {"registry.get"},
                resources = {"*"}, expression = false},
        },
        migrations = {{id = "acme.tool:m1", component = "acme/tool", target_db = "acme.tool:db", timestamp = "t"}},
        starts = {"acme.tool:service"}, capabilities = {}, missing = {}}
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

local function define_tests()
    test.describe("Hub installation request", function()
        test.it("decodes install and uninstall requests strictly", function()
            local install = installation.decode("install", {component = "acme/tool", version = "1.2.0"})
            test.not_nil(install)
            if install then test.eq(install.version, "1.2.0") end
            local latest = installation.decode("install", {component = "acme/tool"})
            test.not_nil(latest)
            if latest then test.is_nil(latest.version) end
            test.is_nil(installation.decode("install", {component = "acme/tool", version = "^1.0"}))
            test.is_nil(installation.decode("install", {component = "tool"}))
            test.is_nil(installation.decode("install", {component = "acme/tool", parameters = {}}))
            test.is_nil(installation.decode("uninstall", {component = "acme/tool", version = "1.2.0"}))
            test.not_nil(installation.decode("uninstall", {component = "acme/tool"}))
        end)

        test.it("updates a component this installer holds and installs any other", function()
            local decoded = installation.decode("install", {component = "acme/tool"})
            if not decoded then error("decode") end
            local roots = {roots = {{id = "bee.hub.deps:" .. DIGEST, component = "acme/tool", version = "1.0.0"}}}
            test.eq(installation.action(decoded, roots), "update")
            test.eq(installation.action(decoded, {roots = {{id = "bee.deps:host", component = "acme/tool"}}}), "install")
            test.eq(installation.action(decoded, {roots = {}}), "install")
            local _, problem = installation.action(decoded, {})
            test.not_nil(problem)
        end)

        test.it("selects the highest version that is not yanked", function()
            test.eq(installation.latest({versions = {{version = "1.0.0", yanked = false},
                {version = "1.10.0", yanked = false}, {version = "2.0.0", yanked = true}}}), "1.10.0")
            local none, problem = installation.latest({versions = {{version = "1.0.0", yanked = true}}})
            test.is_nil(none)
            test.not_nil(problem)
        end)

        test.it("runs migrations on install and blocks removal on applied ones", function()
            local install = installation.request("install", "acme/tool", "1.2.0")
            test.eq(install.migration_policy, "up")
            local removal = installation.request("uninstall", "acme/tool", nil)
            test.eq(removal.migration_policy, "block")
            test.is_nil(removal.version)
        end)

        test.it("builds one approval body from a ready plan", function()
            local proposal, prompt, problem = installation.proposal(plan(), CONTEXT)
            test.is_nil(problem)
            test.not_nil(proposal)
            if not proposal then return end
            test.eq(prompt, "Install acme/tool 1.2.0 from the Hub?")
            test.eq(proposal.ref, installation.REF)
            test.eq(proposal.input_digest, DIGEST)
            local payload = proposal.payload :: Object
            test.eq(payload.source, "hub")
            test.eq(payload.version, "1.2.0")
            test.eq(payload.attempt_id, "attempt-1")
            local dependencies = payload.dependency_changes :: {string}
            test.eq(#dependencies, 3)
            test.eq(dependencies[1], "install acme/tool 1.2.0")
            test.eq(dependencies[2], "update acme/lib 1.0.0 -> 2.0.0")
            test.eq(dependencies[3], "remove acme/old 0.3.0")
            local policies = payload.permission_changes :: {string}
            test.eq(policies[1], "added: acme.tool:files allows fs.get, fs.list on acme.tool:data")
            test.eq(policies[2], "replaced: acme.lib:net allows http_client.request on * where its expression holds")
            test.eq(policies[3], "removed: acme.old:reader allows registry.get on *")
            test.eq((payload.migrations :: {string})[1], "runs: acme.tool:m1 on acme.tool:db")
            test.eq((payload.auto_start :: {string})[1], "acme.tool:service")
        end)

        test.it("refuses a plan that still needs requirement values", function()
            local proposal, _, problem = installation.proposal(plan({ready = false, missing = {"acme.tool:port"}}), CONTEXT)
            test.is_nil(proposal)
            test.not_nil(problem)
        end)

        test.it("keys a retried request to the same attempt and plan", function()
            local first = installation.idempotency_key(CONTEXT, DIGEST)
            test.eq(first, installation.idempotency_key(CONTEXT, DIGEST))
            test.is_false(first == installation.idempotency_key(
                {thread_id = "thread-1", action_id = "action-1", attempt_id = "attempt-2"}, DIGEST))
        end)

        test.it("accepts only the asking agent's own recorded request", function()
            local proposal = installation.proposal(plan(), CONTEXT)
            local view: Object = {requester_id = "agent", thread_id = "thread-1", workspace_id = "ws",
                policy = "module-installation", proposal = proposal}
            local verified, problem = installation.verify(view, "agent", "ws", "module-installation", CONTEXT)
            test.is_nil(problem)
            test.not_nil(verified)
            if verified then
                test.eq(verified.digest, DIGEST)
                local request = installation.apply_request(verified)
                test.eq(request.action, "install"); test.eq(request.version, "1.2.0")
                test.eq(request.migration_policy, "up")
            end
            test.is_nil(installation.verify(view, "other-agent", "ws", "module-installation", CONTEXT))
            test.is_nil(installation.verify(view, "agent", "other-ws", "module-installation", CONTEXT))
            test.is_nil(installation.verify(view, "agent", "ws", "other-policy", CONTEXT))
            test.is_nil(installation.verify(view, "agent", "ws", "module-installation",
                {thread_id = "thread-1", action_id = "action-1", attempt_id = "attempt-2"}))
            local foreign: Object = {requester_id = "agent", thread_id = "thread-1", workspace_id = "ws",
                policy = "module-installation", proposal = {kind = "operation", ref = "bee.gov:apply", payload = {}}}
            test.is_nil(installation.verify(foreign, "agent", "ws", "module-installation", CONTEXT))
        end)

        test.it("reports the person's decision before any effect", function()
            test.eq(installation.decision({state = "pending"}).status, "pending")
            test.eq(installation.decision({state = "decided", decision = "approved"}).status, "approved")
            local denied = installation.decision({state = "decided", decision = "denied"})
            test.eq(denied.status, "refused"); test.eq(denied.code, "DENIED")
            local expired = installation.decision({state = "expired"})
            test.eq(expired.status, "refused"); test.eq(expired.code, "EXPIRED")
        end)

        test.it("maps the Hub apply reply to the agent outcome", function()
            test.eq(installation.status({ok = true, replayed = false, value = {state = "complete"}}).status, "applied")
            local stale = installation.status({ok = false, replayed = false, code = "STALE", message = "plan changed"})
            test.eq(stale.status, "failed"); test.eq(stale.code, "STALE")
            test.eq(installation.status({ok = false, replayed = false, code = "UNCERTAIN"}).status, "approved")
            local recovery = installation.status({ok = true, replayed = false,
                value = {state = "recovery_required", message = "review recovery"}})
            test.eq(recovery.status, "failed"); test.eq(recovery.message, "review recovery")
        end)
    end)
end

return test.run_cases(define_tests)
