-- MIT. Installed grant records and generated policy bindings are host output.
local test = require("test")
local catalog = require("capability_catalog")
local grants = require("capability_grants")
local registry = require("registry")

local OWNER = "bee.governance.workspace_applications:workspace-1.notes"
local APP = "app.notes:app"

local function vocabulary(): unknown
    return assert(catalog.decode(assert(registry.get("bee:capability_catalog"))))
end

local function request(capability: string, parameters: {[string]: unknown}): {[string]: unknown}
    return {id = "app.notes:request", expected_kind = "security.policy", value = nil,
        targets = {APP}, capability_request = {capability = capability, parameters = parameters,
            catalog_revision = 1, template_revision = 1, reason = "show the person's threads",
            target = APP, path = ".security.policies +="}}
end

local function define_tests()
    test.describe("installed capability grants", function()
        test.it("resolves the catalog request and binds one host policy", function()
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("threads.read", {scope = "owned"})}))
            test.eq(#proposed.capabilities, 1)
            test.eq(proposed.capabilities[1].operation, "threads.read")
            test.eq(#proposed.policies, 1)
            test.is_true(proposed.policies[1].id:find("^bee%.governance%.grants:policy%." ) ~= nil)
            test.eq(proposed.policies[1].kind, "security.policy")
            test.eq(proposed.bindings[1].requirement_id, "app.notes:request")
            test.eq(proposed.bindings[1].policy_id, proposed.policies[1].id)
            test.eq(proposed.thread_access, "none")
        end)
        test.it("reuses only a live grant record containing the resolved set", function()
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("threads.read", {scope = "owned"})}))
            local first = assert(grants.record(OWNER, "workspace-1", APP, proposed,
                "approval-first", 1))
            local decoded = assert(grants.decode(first, OWNER, "workspace-1", APP, vocabulary()))
            local installed_entries: {[string]: unknown} = {}
            installed_entries[proposed.policies[1].id :: string] = proposed.policies[1]
            installed_entries["app.notes:request"] = {kind = "ns.requirement",
                data = {default = proposed.policies[1].id}}
            test.is_true(grants.live(decoded, function(id: string): unknown return installed_entries[id] end))
            installed_entries[proposed.policies[1].id :: string] = nil
            test.is_false(grants.live(decoded, function(id: string): unknown return installed_entries[id] end))
            local same = assert(grants.diff(vocabulary(), decoded, proposed))
            test.is_false(same.requires_approval)
            local empty = assert(grants.propose(vocabulary(), OWNER, APP, {}))
            local narrower = assert(grants.diff(vocabulary(), decoded, empty))
            test.is_false(narrower.requires_approval)
            test.eq(#narrower.removed, 1)
            local widening = assert(grants.diff(vocabulary(), nil, proposed))
            test.is_true(widening.requires_approval)
            test.eq(#widening.added, 1)
            test.is_true(table.concat(widening.lines, "\n"):find("Read owned threads", 1, true) ~= nil)
            local changed = first.data :: {[string]: unknown}
            changed.revision = 0
            test.is_nil(grants.decode(first, OWNER, "workspace-1", APP, vocabulary()))
            changed.revision = 1
            changed.digest = string.rep("0", 64)
            test.is_nil(grants.decode(first, OWNER, "workspace-1", APP, vocabulary()))
            changed.digest = proposed.digest
            local policies = changed.policies :: {{[string]: unknown}}
            policies[1].data = {policy = {actions = {"registry.overlay.apply"}, resources = "*", effect = "allow"}}
            test.is_nil(grants.decode(first, OWNER, "workspace-1", APP, vocabulary()))
        end)
        test.it("refuses unimplemented materialization and foreign app targets", function()
            test.is_nil(grants.propose(vocabulary(), OWNER, APP,
                {request("workspace.files.read", {subpath = "docs"})}))
            local foreign = request("threads.read", {scope = "owned"})
            foreign.targets = {"app.other:app"}
            test.is_nil(grants.propose(vocabulary(), OWNER, APP, {foreign}))
        end)
    end)
end
return test.run_cases(define_tests)
