-- MIT. The capability gateway serves only an authenticated application
-- principal with its own live grant; any other caller is refused before a
-- binding is opened or a request is sent.
local funcs = require("funcs")
local security = require("security")
local app_scope = require("app_scope")
local test = require("test")
local bounds = require("bounds")
local registry = require("registry")
local grants = require("capability_grants")
local model = require("capability_model")
local WORKSPACE = string.rep("d", 32)
local BINDING = "bee.tests.gov:gateway_probe_binding"

local function admitted(binding_id: string, methods: {string}, name: string): (funcs.Executor, string, string, {string})
    local vocabulary = assert(model.decode(assert(registry.get("bee.capability:catalog"))))
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
    local created = {assert(bounds.id(record.id))}
    changes:create({id = assert(bounds.id(record.id)), kind = assert(bounds.text(record.kind, 160)),
        meta = assert(bounds.object(record.meta)), data = record.data})
    for _, policy in ipairs(proposal.policies) do
        created[#created + 1] = assert(bounds.id(policy.id))
        changes:create({id = assert(bounds.id(policy.id)), kind = assert(bounds.text(policy.kind, 160)),
            meta = assert(bounds.object(policy.meta)), data = policy.data})
    end
    for _, binding in ipairs(proposal.bindings) do
        created[#created + 1] = assert(bounds.id(binding.requirement_id))
        changes:create({id = assert(bounds.id(binding.requirement_id)), kind = "ns.requirement",
            data = {default = binding.policy_id}})
    end
    assert(changes:apply())
    local actor_id = "bee.application:" .. WORKSPACE .. ":instance-1"
    local actor = security.new_actor(actor_id, {workspace_id = WORKSPACE, definition_id = application,
        definition_revision = "1", execution_generation = 1})
    local scope = app_scope.boundary({assert(bounds.id(proposal.policies[1].id))})
    test.eq(scope:evaluate(actor, "security.scope.create", "custom"), "deny")
    return funcs.new():with_actor(actor):with_scope(scope), actor_id, assert(bounds.id(proposal.policies[1].id)), created
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
        test.it("makes each newly committed policy available to the first gateway request", function()
            for index = 1, 32 do
                local caller, _, _, created = admitted(BINDING, {"inspect"}, "firstrequest" .. tostring(index))
                local reply, err = caller:call("bee.gov.binding:contract_call", {binding = BINDING, method = "inspect"})
                test.eq(err, nil)
                test.is_true(assert(bounds.object(reply)).ok == true)
                local changes = assert(registry.snapshot()):changes()
                for _, id in ipairs(created) do changes:delete(id) end
                assert(changes:apply())
            end
        end)
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
        test.it("refuses malformed requests", function()
            test.eq(code(call("bee.gov.binding:contract_call", {binding = "app.peer:api", method = "get",
                extra = true})), "INVALID")
            test.eq(code(call("bee.gov.binding:http_request", {method = "GET", url = "https://api.example.com/v1",
                timeout = 600})), "INVALID")
        end)
    end)
end

return test.run_cases(define_tests)
