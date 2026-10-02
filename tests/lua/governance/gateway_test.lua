-- MIT. The capability gateway serves only an authenticated application
-- principal with its own live grant; any other caller is refused before a
-- binding is opened or a request is sent.
local funcs = require("funcs")
local security = require("security")
local test = require("test")
local bounds = require("bounds")
local registry = require("registry")
local grants = require("capability_grants")
local model = require("capability_model")
local enrollment = require("enrollment")
local WORKSPACE = string.rep("d", 32)
local BINDING = "bee.gov:gateway_probe_binding"

local function admitted(binding_id: string, methods: {string}, name: string): (funcs.Executor, string, string)
    local vocabulary = assert(model.decode(assert(registry.get("bee.security.capability:capability_catalog"))))
    local application = "app." .. name .. ":app"
    local owner = "bee.gov.apps:" .. WORKSPACE .. "." .. name
    local proposal = assert(grants.propose(vocabulary, owner, application, {
        {id = "app." .. name .. ":request", expected_kind = "security.policy", targets = {application},
            capability_request = {capability = "contract.call", parameters = {binding = binding_id, methods = methods},
                template_revision = 1, catalog_revision = model.revisions(vocabulary, "contract.call"),
                reason = "exercise approved call", target = application, path = ".security.policies +="}}
    }))
    local record = assert(grants.record(owner, WORKSPACE, application, proposal, "approval-gateway-test", 1))
    local snapshot = assert(registry.snapshot())
    local changes = snapshot:changes()
    changes:create({id = assert(bounds.id(record.id)), kind = assert(bounds.text(record.kind, 160)),
        meta = assert(bounds.object(record.meta)), data = record.data})
    for _, policy in ipairs(proposal.policies) do
        changes:create({id = assert(bounds.id(policy.id)), kind = assert(bounds.text(policy.kind, 160)),
            meta = assert(bounds.object(policy.meta)), data = policy.data})
    end
    for _, binding in ipairs(proposal.bindings) do
        changes:create({id = assert(bounds.id(binding.requirement_id)), kind = "ns.requirement",
            data = {default = binding.policy_id}})
    end
    assert(changes:apply())
    local actor_id = "bee.application:" .. WORKSPACE .. ":instance-1"
    local actor = security.new_actor(actor_id, {workspace_id = WORKSPACE, definition_id = application,
        definition_revision = "1", execution_generation = 1})
    local scope = security.new_scope({assert(security.policy("bee.security:app_boundary_policy")),
        assert(security.policy(proposal.policies[1].id))})
    test.eq(scope:evaluate(actor, "security.scope.create", "custom"), "deny")
    return funcs.new():with_actor(actor):with_scope(scope), actor_id, assert(bounds.id(proposal.policies[1].id))
end

local function call(target: string, request: unknown, actor: unknown?): {[string]: unknown}
    local executor = funcs.new()
    if actor then executor = executor:with_actor(actor) end
    local result, err = executor:call(target, request)
    if type(result) ~= "table" then error(tostring(err or "gateway returned no result")) end
    return assert(bounds.object(result))
end

local function code(result: {[string]: unknown}): unknown
    local fault = assert(bounds.object(result.error))
    return fault.code
end

local function define_tests()
    test.describe("capability gateway", function()
        test.it("refuses a caller that is not an application principal", function()
            local contract = call("bee.gov.binding:contract_call", {binding = "app.peer:api", method = "get"})
            test.is_false(contract.ok == true)
            test.eq(code(contract), "DENIED")
            local http = call("bee.gov.binding:http_request", {method = "GET", url = "https://api.example.com/v1"})
            test.is_false(http.ok == true)
            test.eq(code(http), "DENIED")
        end)
        test.it("refuses an application principal without an installed grant", function()
            local workspace = string.rep("c", 32)
            local actor = security.new_actor("bee.application:" .. workspace .. ":instance-1",
                {workspace_id = workspace, definition_id = "app.absent:app", definition_revision = "1",
                    execution_generation = 1})
            local contract = call("bee.gov.binding:contract_call", {binding = "app.peer:api", method = "get"}, actor)
            test.eq(code(contract), "DENIED")
            local http = call("bee.gov.binding:http_request", {method = "GET", url = "https://api.example.com/v1"},
                actor)
            test.eq(code(http), "DENIED")
        end)
        test.it("calls an approved binding under the app actor without gateway authority", function()
            local caller, actor_id, policy_id = admitted(BINDING, {"inspect"}, "gateway_test")
            local reply, err = caller:call("bee.gov.binding:contract_call", {binding = BINDING, method = "inspect"})
            test.eq(err, nil)
            local result = assert(bounds.object(reply))
            test.is_true(result.ok == true)
            local value = assert(bounds.object(result.value))
            test.eq(value.actor_id, actor_id)
            test.eq(value.workspace_id, WORKSPACE)
            test.is_false(value.registry_read == true)
            test.is_false(value.http_request == true)
            test.is_false(value.scope_create == true)
            local denied = assert(bounds.object(caller:call("bee.gov.binding:contract_call",
                {binding = BINDING, method = "unapproved"})))
            test.eq(code(denied), "DENIED")
            local changes = assert(registry.snapshot()):changes()
            changes:delete(policy_id)
            assert(changes:apply())
            local revoked = assert(bounds.object(caller:call("bee.gov.binding:contract_call",
                {binding = BINDING, method = "inspect"})))
            test.eq(code(revoked), "DENIED")
        end)
        test.it("reads approved status from the native host enrollment entry", function()
            local linked = assert(registry.get("bee.hive.telemetry.env:peer_source"))
            test.eq(assert(bounds.object(linked.data)).resource_ref, enrollment.ENTRY)
            local snapshot = assert(registry.snapshot())
            local changes = snapshot:changes()
            local entry = {id = enrollment.ENTRY, kind = "registry.entry",
                meta = {type = "bee.hive.supervisor_enrollment"},
                data = {nodes = {"fixture-local-client"}, peers = {"fixture-offline-peer"}}}
            if snapshot:get(entry.id) then changes:update(entry) else changes:create(entry) end
            assert(changes:apply())
            local caller = admitted("bee.hive.telemetry.binding:status", {"snapshot", "detail"}, "status_gateway_test")
            local reply, err = caller:call("bee.gov.binding:contract_call",
                {binding = "bee.hive.telemetry.binding:status", method = "snapshot", arguments = {{}}})
            test.eq(err, nil)
            local result = assert(bounds.object(reply))
            test.is_true(result.ok == true, tostring(result.error and assert(bounds.object(result.error)).message))
            local value = assert(bounds.object(result.value))
            local nodes = assert(bounds.array(value.nodes))
            test.eq(#nodes, 2)
            local found_local, found_offline = false, false
            for _, raw in ipairs(nodes) do
                local node = assert(bounds.object(raw))
                if node.node_id == "fixture-offline-peer" then
                    found_offline = true
                    test.is_false(node.online == true)
                    test.eq(node.status, "unavailable")
                    test.eq(node.running_sessions, nil)
                else
                    found_local = true
                    test.is_true(node.online == true)
                    test.eq(node.status, "unavailable")
                    test.eq(node.running_sessions, nil)
                    test.eq(node.pending_approvals, nil)
                    local detail, detail_error = caller:call("bee.gov.binding:contract_call",
                        {binding = "bee.hive.telemetry.binding:status", method = "detail",
                            arguments = {{node_id = node.node_id}}})
                    test.eq(detail_error, nil)
                    local detail_reply = assert(bounds.object(detail))
                    test.is_true(detail_reply.ok == true)
                    test.eq(assert(bounds.object(assert(bounds.object(detail_reply.value)).node)).node_id, node.node_id)
                end
            end
            test.is_true(found_local and found_offline)
        end)
        test.it("refuses malformed requests", function()
            test.eq(code(call("bee.gov.binding:contract_call", {binding = "app.peer:api", method = "get",
                extra = true})), "INVALID")
            test.eq(code(call("bee.gov.binding:http_request", {method = "GET", url = "https://api.example.com/v1",
                timeout = 600})), "INVALID")
        end)
    end)
end

return test.run_cases(define_tests)
