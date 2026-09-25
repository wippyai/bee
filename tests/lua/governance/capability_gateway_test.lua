-- MIT. The host gateway's checks for contract calls and HTTP requests made
-- under installed grants: the authenticated application, its own workspace
-- grant, the exact binding and method, and the approved origin, method and
-- path prefix.
local test = require("test")
local catalog = require("capability_catalog")
local grants = require("capability_grants")
local gateway = require("capability_gateway")
local registry = require("registry")

local WORKSPACE = string.rep("a", 32)
local OTHER_WORKSPACE = string.rep("b", 32)
local OWNER = "bee.gov.apps:" .. WORKSPACE .. ".notes"
local APP = "app.notes:app"
local BINDING = "app.peer:api"
local OTHER_BINDING = "app.other:api"
local ACTOR = "bee.application:" .. WORKSPACE .. ":instance-1"

local function vocabulary(): unknown
    return assert(catalog.decode(assert(registry.get("bee:capability_catalog"))))
end

local function request(capability: string, parameters: {[string]: unknown}): {[string]: unknown}
    return {id = "app.notes:request", expected_kind = "security.policy", value = nil,
        targets = {APP}, capability_request = {capability = capability, parameters = parameters,
            catalog_revision = assert(vocabulary()).revision,
            template_revision = 1, reason = "reach the approved service",
            target = APP, path = ".security.policies +="}}
end

local function issued(capability: string, parameters: {[string]: unknown}): unknown
    local proposed = assert(grants.propose(vocabulary(), OWNER, APP, {request(capability, parameters)}))
    local record = assert(grants.record(OWNER, WORKSPACE, APP, proposed, "approval-1", 1))
    return assert(grants.decode(record, OWNER, WORKSPACE, APP, vocabulary()))
end

local function caller(): unknown
    return assert(gateway.caller(ACTOR, {workspace_id = WORKSPACE, definition_id = APP,
        definition_revision = "1", execution_generation = 1}))
end

local function define_tests()
    test.describe("capability gateway checks", function()
        test.it("authenticates only a broker application principal", function()
            local identity = caller() :: {[string]: unknown}
            test.eq(identity.workspace_id, WORKSPACE)
            test.eq(identity.definition_id, APP)
            test.is_nil(gateway.caller("bee.gov.activation", {workspace_id = WORKSPACE, definition_id = APP}))
            test.is_nil(gateway.caller(ACTOR, {workspace_id = OTHER_WORKSPACE, definition_id = APP}))
            test.is_nil(gateway.caller(ACTOR, {workspace_id = WORKSPACE}))
        end)
        test.it("admits the exact approved binding and method for its own workspace", function()
            local record = issued("contract.call", {binding = BINDING, methods = {"get", "list"}})
            test.is_true(gateway.contract(record, caller(), BINDING, "get", true))
            test.is_true(gateway.contract(record, caller(), BINDING, "list", true))
        end)
        test.it("refuses a confused deputy call on another binding", function()
            local record = issued("contract.call", {binding = BINDING, methods = {"get", "list"}})
            test.is_nil(gateway.contract(record, caller(), OTHER_BINDING, "get", true))
        end)
        test.it("refuses an unapproved method on the approved binding", function()
            local record = issued("contract.call", {binding = BINDING, methods = {"get"}})
            test.is_nil(gateway.contract(record, caller(), BINDING, "drop", true))
        end)
        test.it("refuses cross-workspace calls on another workspace's grant", function()
            local record = issued("contract.call", {binding = BINDING, methods = {"get"}})
            local foreign = assert(gateway.caller("bee.application:" .. OTHER_WORKSPACE .. ":instance-1",
                {workspace_id = OTHER_WORKSPACE, definition_id = APP}))
            test.is_nil(gateway.contract(record, foreign, BINDING, "get", true))
            local sibling = assert(gateway.caller(ACTOR, {workspace_id = WORKSPACE, definition_id = "app.other:app"}))
            test.is_nil(gateway.contract(record, sibling, BINDING, "get", true))
        end)
        test.it("refuses revoked grants and tampered records", function()
            local record = issued("contract.call", {binding = BINDING, methods = {"get"}})
            test.is_nil(gateway.contract(record, caller(), BINDING, "get", false))
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("contract.call", {binding = BINDING, methods = {"get"}})}))
            local stored = assert(grants.record(OWNER, WORKSPACE, APP, proposed, "approval-call", 1))
            local data = (stored :: {[string]: unknown}).data :: {[string]: unknown}
            data.workspace_id = OTHER_WORKSPACE
            test.is_nil(grants.decode(stored, OWNER, WORKSPACE, APP, vocabulary()))
        end)
        test.it("admits only the approved HTTP origin, method and path prefix", function()
            local record = issued("http.api", {origin = "https://api.example.com", methods = {"GET"},
                path_prefix = "/v1"})
            test.is_true(gateway.http(record, caller(), "GET", "https://api.example.com/v1/items?page=2", true))
            test.is_true(gateway.http(record, caller(), "get", "https://api.example.com/v1", true))
            test.is_nil(gateway.http(record, caller(), "POST", "https://api.example.com/v1/items", true))
            test.is_nil(gateway.http(record, caller(), "GET", "https://api.example.com/v10/items", true))
            test.is_nil(gateway.http(record, caller(), "GET", "https://api.example.com/v1/../admin", true))
            test.is_nil(gateway.http(record, caller(), "GET", "https://api.example.com/v1/%2e%2e/admin", true))
            test.is_nil(gateway.http(record, caller(), "GET", "https://api.example.com.evil/v1", true))
            test.is_nil(gateway.http(record, caller(), "GET", "https://user@api.example.com/v1", true))
            test.is_nil(gateway.http(record, caller(), "GET", "http://api.example.com/v1", true))
            test.is_nil(gateway.http(record, caller(), "GET", "https://api.example.com/v1/items", false))
            test.is_true(gateway.located(record, "https://api.example.com/v1/next"))
            test.is_nil(gateway.located(record, "https://elsewhere.example.com/v1"))
        end)
        test.it("materializes callable gateway grants rather than direct runtime access", function()
            local contract_grant = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("contract.call", {binding = BINDING, methods = {"get"}})}))
            local contract_inner = (contract_grant.policies[1].data :: {[string]: unknown}).policy :: {[string]: unknown}
            test.eq((contract_inner.actions :: {string})[1], "funcs.call")
            test.eq((contract_inner.resources :: {string})[1], gateway.CONTRACT_CALL)
            local http_grant = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("http.api", {origin = "https://api.example.com", methods = {"GET"}, path_prefix = "/v1"})}))
            local http_inner = (http_grant.policies[1].data :: {[string]: unknown}).policy :: {[string]: unknown}
            test.eq((http_inner.resources :: {string})[1], gateway.HTTP_REQUEST)
        end)
    end)
end
return test.run_cases(define_tests)
