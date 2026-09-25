-- MIT. Callee-side owner checks for contract calls admitted by grants.
local test = require("test")
local catalog = require("capability_catalog")
local grants = require("capability_grants")
local contracts = require("capability_contracts")
local registry = require("registry")
local hash = require("hash")

local OWNER = "bee.gov.apps:workspace-1.notes"
local APP = "app.notes:app"
local BINDING = "app.peer:api"
local OTHER_BINDING = "app.other:api"

local function vocabulary(): unknown
    return assert(catalog.decode(assert(registry.get("bee:capability_catalog"))))
end

local function request(capability: string, parameters: {[string]: unknown}): {[string]: unknown}
    return {id = "app.notes:request", expected_kind = "security.policy", value = nil,
        targets = {APP}, capability_request = {capability = capability, parameters = parameters,
            catalog_revision = assert(vocabulary()).revision,
            template_revision = 1, reason = "call the peer contract",
            target = APP, path = ".security.policies +="}}
end

local function issued(binding: string, methods: {string}): unknown
    local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
        {request("contract.call", {binding = binding, methods = methods})}))
    local record = assert(grants.record(OWNER, "workspace-1", APP, proposed, "approval-call", 1))
    return assert(grants.decode(record, OWNER, "workspace-1", APP, vocabulary()))
end

local function define_tests()
    test.describe("contract call owner checks", function()
        test.it("admits the exact approved binding and method for its own workspace", function()
            local record = issued(BINDING, {"get", "list"})
            test.is_true(contracts.authorize(record, OWNER, "workspace-1", APP, BINDING, "get", true))
            test.is_true(contracts.authorize(record, OWNER, "workspace-1", APP, BINDING, "list", true))
        end)
        test.it("refuses a confused deputy call on another binding", function()
            local record = issued(BINDING, {"get", "list"})
            test.is_nil(contracts.authorize(record, OWNER, "workspace-1", APP, OTHER_BINDING, "get", true))
        end)
        test.it("refuses an unapproved method on the approved binding", function()
            local record = issued(BINDING, {"get"})
            test.is_nil(contracts.authorize(record, OWNER, "workspace-1", APP, BINDING, "drop", true))
        end)
        test.it("refuses cross-workspace calls on another workspace's grant", function()
            local record = issued(BINDING, {"get"})
            test.is_nil(contracts.authorize(record, OWNER, "workspace-2", APP, BINDING, "get", true))
            test.is_nil(contracts.authorize(record, "bee.gov.apps:workspace-2.notes",
                "workspace-1", APP, BINDING, "get", true))
        end)
        test.it("refuses revoked grants and tampered records", function()
            local record = issued(BINDING, {"get"})
            test.is_nil(contracts.authorize(record, OWNER, "workspace-1", APP, BINDING, "get", false))
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("contract.call", {binding = BINDING, methods = {"get"}})}))
            local stored = assert(grants.record(OWNER, "workspace-1", APP, proposed, "approval-call", 1))
            local data = (stored :: {[string]: unknown}).data :: {[string]: unknown}
            data.workspace_id = "workspace-2"
            test.is_nil(grants.decode(stored, OWNER, "workspace-1", APP, vocabulary()))
        end)
        test.it("materializes an exact binding and method caller grant", function()
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("contract.call", {binding = BINDING, methods = {"get"}})}))
            test.eq(#proposed.capabilities, 1)
            test.eq(proposed.capabilities[1].operation, "contract.call")
            test.eq(#proposed.policies, 1)
            test.eq(proposed.policies[1].kind, "security.policy.expr")
        end)
    end)
end
return test.run_cases(define_tests)
