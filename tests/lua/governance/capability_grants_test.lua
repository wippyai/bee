-- MIT. Installed grant records and generated policy bindings are host output.
local test = require("test")
local catalog = require("capability_catalog")
local grants = require("capability_grants")
local registry = require("registry")
local hash = require("hash")

local OWNER = "bee.gov.apps:workspace-1.notes"
local APP = "app.notes:app"

local function vocabulary(): unknown
    return assert(catalog.decode(assert(registry.get("bee:capability_catalog"))))
end

local function request(capability: string, parameters: {[string]: unknown}): {[string]: unknown}
    return {id = "app.notes:request", expected_kind = "security.policy", value = nil,
        targets = {APP}, capability_request = {capability = capability, parameters = parameters,
            catalog_revision = assert(vocabulary()).revision,
            template_revision = 1, reason = "show the person's threads",
            target = APP, path = ".security.policies +="}}
end

local FOLDER = {root_ref = "bee.env:workspace_root", directory = ".", base = "project", subpath = "alpha"}
local function define_tests()
    test.describe("installed capability grants", function()
        test.it("resolves the catalog request and binds one host policy", function()
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("threads.read", {scope = "owned"})}))
            test.eq(#proposed.capabilities, 1)
            test.eq(proposed.capabilities[1].operation, "threads.read")
            test.eq(#proposed.policies, 1)
            test.is_true(proposed.policies[1].id:find("^bee%.gov%.grants:policy%." ) ~= nil)
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
        test.it("reads approval-bound grants installed before the namespace rename", function()
            local old_owner = "bee.governance.workspace_applications:workspace-1.notes"
            local proposed = assert(grants.propose(vocabulary(), old_owner, APP,
                {request("threads.read", {scope = "owned"})}, true))
            local record = assert(grants.record(old_owner, "workspace-1", APP, proposed,
                "approval-old", 1, nil, nil, true))
            test.eq(record.id, "bee.governance.grants:record." .. assert(hash.sha256(old_owner)))
            test.is_true(grants.reserved(record.id))
            local decoded = assert(grants.decode(record, old_owner, "workspace-1", APP, vocabulary()))
            test.eq((decoded.policies :: {{[string]: unknown}})[1].id, proposed.policies[1].id)
            record.id = "bee.governance.grants:record." .. string.rep("0", 64)
            test.is_nil(grants.decode(record, old_owner, "workspace-1", APP, vocabulary()))
        end)
        test.it("decodes a record whose grants sort differently from their requirements", function()
            local function named(id: string, capability: string, parameters: {[string]: unknown}): {[string]: unknown}
                local item = request(capability, parameters)
                item.id = id
                return item
            end
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP, {
                named("app.notes:shared_files", "workspace.files.read", {subpath = "docs"}),
                named("app.notes:store", "app.database", {name = "notes"}),
                named("app.notes:threads", "threads.read", {scope = "owned"})}, nil, FOLDER))
            local record = assert(grants.record(OWNER, "workspace-1", APP, proposed, "approval-several", 1))
            local decoded, decode_error = grants.decode(record, OWNER, "workspace-1", APP, vocabulary())
            test.is_nil(decode_error)
            test.not_nil(decoded)
        end)
        test.it("materializes a verified workspace file volume and its policy", function()
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("workspace.files.read", {subpath = "docs"})}, nil, FOLDER))
            test.eq(#proposed.capabilities, 1)
            test.eq(proposed.capabilities[1].operation, "files.read")
            test.eq(#proposed.policies, 1)
            test.eq(proposed.policies[1].kind, "security.policy")
            test.eq(#proposed.volumes, 1)
            test.eq(proposed.volumes[1].kind, "fs.directory")
            test.eq((proposed.volumes[1].data :: {[string]: unknown}).directory, "alpha/docs")
            test.is_nil(grants.propose(vocabulary(), OWNER, APP,
                {request("workspace.files.read", {subpath = "docs"})}))
            test.is_true((proposed.volumes[1].data :: {[string]: unknown}).readonly)
            local record = assert(grants.record(OWNER, "workspace-1", APP, proposed,
                "approval-files", 1))
            local decoded = assert(grants.decode(record, OWNER, "workspace-1", APP, vocabulary()))
            local installed_entries: {[string]: unknown} = {}
            installed_entries[proposed.policies[1].id :: string] = proposed.policies[1]
            installed_entries[proposed.volumes[1].id :: string] = proposed.volumes[1]
            installed_entries["app.notes:request"] = {kind = "ns.requirement",
                data = {default = proposed.policies[1].id}}
            test.is_true(grants.live(decoded, function(id: string): unknown return installed_entries[id] end))
            installed_entries[proposed.volumes[1].id :: string] = nil
            test.is_false(grants.live(decoded, function(id: string): unknown return installed_entries[id] end))
        end)
        test.it("materializes an isolated application database and its policy", function()
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("app.database", {name = "notes"})}))
            test.eq(#proposed.capabilities, 1)
            test.eq(proposed.capabilities[1].operation, "database.use")
            test.eq(#proposed.policies, 1)
            test.eq(#proposed.databases, 1)
            test.eq(proposed.databases[1].kind, "db.sql.sqlite")
            local record = assert(grants.record(OWNER, "workspace-1", APP, proposed,
                "approval-database", 1))
            local decoded = assert(grants.decode(record, OWNER, "workspace-1", APP, vocabulary()))
            test.eq(#(decoded.databases :: {unknown}), 1)
        end)
        test.it("refuses private workspace subroots and foreign app targets", function()
            test.is_nil(grants.propose(vocabulary(), OWNER, APP,
                {request("workspace.files.read", {subpath = ".wippy"})}, nil, FOLDER))
            local foreign = request("threads.read", {scope = "owned"})
            foreign.targets = {"app.other:app"}
            test.is_nil(grants.propose(vocabulary(), OWNER, APP, {foreign}))
        end)
        test.it("materializes child thread messaging on its owner verbs", function()
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("threads.message", {scope = "children"})}))
            test.eq(#proposed.capabilities, 1)
            test.eq(proposed.capabilities[1].operation, "threads.message")
            test.eq(#proposed.policies, 1)
            local body = (proposed.policies[1].data :: {[string]: unknown}).policy :: {[string]: unknown}
            test.eq((body.actions :: {string})[1], "funcs.call")
        end)
        test.it("materializes managed agent launch on the exact definitions", function()
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("agents.launch", {definitions = {"acme:research"}})}))
            test.eq(#proposed.capabilities, 1)
            test.eq(proposed.capabilities[1].operation, "agents.launch")
            local body = (proposed.policies[1].data :: {[string]: unknown}).policy :: {[string]: unknown}
            test.eq((body.actions :: {string})[1], "bee.harness.launch")
            local resources = body.resources :: {string}
            test.eq(#resources, 1)
            test.eq(resources[1], "acme:research")
        end)
        test.it("grants scoped HTTP only through the host gateway", function()
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("http.api", {origin = "https://api.example.com",
                    methods = {"GET"}, path_prefix = "/v1"})}))
            test.eq(#proposed.capabilities, 1)
            test.eq(proposed.capabilities[1].operation, "http.request")
            local scope = proposed.capabilities[1].scope :: {[string]: unknown}
            test.eq(scope.path_prefix, "/v1")
            test.eq(proposed.policies[1].kind, "security.policy")
            local body = (proposed.policies[1].data :: {[string]: unknown}).policy :: {[string]: unknown}
            test.eq((body.actions :: {string})[1], "funcs.call")
            test.eq(#(body.resources :: {string}), 1)
            test.eq((body.resources :: {string})[1], "bee.gov.binding:http_request")
        end)
        test.it("keeps Hive exposure as review vocabulary without installable enforcement", function()
            test.is_nil(grants.propose(vocabulary(), OWNER, APP,
                {request("hive.expose", {contract = "app.notes:api", methods = {"get"}})}))
        end)
    end)
end
return test.run_cases(define_tests)
