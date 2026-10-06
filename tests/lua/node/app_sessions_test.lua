-- MIT. An app the person approved for managed agents reaches Sessions through
-- the public client library, and opens only the definitions approved for it.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local system = require("system")
local uuid = require("uuid")
local bounds = require("bounds")
local client = require("client")
local app_scope = require("app_scope")
local capability_model = require("capability_model")
local grants = require("capability_grants")

local OWNER = "bee.gov.apps:workspace-1.agents"
local APP = "app.agents:app"
local POLICY = "bee.tests.node:app_sessions_grant"
local APPROVED = "bee.tests.node:approved_agent"
local OTHER = "bee.tests.node:unapproved_agent"

local function home(): string
    local value, err = client.call(assert(system.node.id()), "watch", {})
    if not value then error("watch: " .. tostring(err)) end
    return assert(client.state(value)).home
end

-- The policy activation generates for an approved agents.launch request,
-- installed the way activation installs it.
local function install_grant()
    if registry.get(POLICY) then return end
    local vocabulary = assert(capability_model.decode(assert(registry.get("bee.capability:catalog"))))
    local proposed = assert(grants.propose(vocabulary, OWNER, APP, {{id = "app.agents:request", expected_kind = "security.policy",
        targets = {APP}, capability_request = {capability = "agents.launch", parameters = {definitions = {APPROVED}},
            catalog_revision = capability_model.revisions(vocabulary, "agents.launch"), template_revision = 1,
            reason = "run agents for the person", target = APP, path = ".security.policies +="}}}))
    local generated = assert(bounds.object(proposed.policies[1]))
    local changes = registry.snapshot():changes()
    assert(changes:create({id = POLICY, kind = generated.kind, meta = generated.meta, data = generated.data}))
    assert(changes:apply())
end

local function as_app(op: string, definition: string?): {[string]: unknown}
    local workspace = home()
    local actor = assert(security.new_actor("bee.application:" .. workspace .. ":agents-test",
        {workspace_id = workspace, definition_id = APP, definition_revision = "1", execution_generation = 1}))
    local executor = funcs.new():with_actor(actor):with_scope(app_scope.boundary({POLICY}))
    local raw, err = executor:call("bee.tests.node:app_sessions_probe", {op = op, definition = definition,
        operation_key = assert(uuid.v4())})
    if err then error(tostring(err)) end
    return assert(bounds.object(raw))
end

local function define_tests()
    test.describe("application sessions grant", function()
        test.it("reads the agent catalog and the session directory through the public contracts", function()
            install_grant()
            local catalog = as_app("catalog")
            test.is_true(catalog.ok == true, tostring(catalog.message))
            local listed = as_app("list")
            test.is_true(listed.ok == true, tostring(listed.message))
        end)

        test.it("refuses to open a definition the person did not approve for the app", function()
            install_grant()
            local refused = as_app("open", OTHER)
            test.eq(refused.code, "DENIED", tostring(refused.message))
            test.is_true(tostring(refused.message):find("launch grant", 1, true) ~= nil, tostring(refused.message))
            local approved = as_app("open", APPROVED)
            test.is_true(approved.code ~= "DENIED" or tostring(approved.message):find("launch grant", 1, true) == nil,
                tostring(approved.message))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
