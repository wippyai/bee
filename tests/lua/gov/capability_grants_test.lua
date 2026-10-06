-- MIT. Installed grant records and generated policy bindings are host output.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local capability_model = require("capability_model")
local grants = require("capability_grants")
local registry = require("registry")
local hash = require("hash")

local OWNER = "bee.gov.apps:workspace-1.notes"
local APP = "app.notes:app"

local function vocabulary(): capability_model.Vocabulary
    return assert(capability_model.decode(assert(registry.get("bee.capability:catalog"))))
end

local function request(capability: string, parameters: {[string]: unknown}, template_revision: integer?): {[string]: unknown}
    local catalog_revision = capability_model.revisions(vocabulary(), capability)
    return {id = "app.notes:request", expected_kind = "security.policy", value = nil,
        targets = {APP}, capability_request = {capability = capability, parameters = parameters,
            catalog_revision = catalog_revision,
            template_revision = template_revision or 1, reason = "show the person's threads",
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
        test.it("rejects capability request identities before catalog resolution", function()
            local malformed: {unknown} = {false, 17, {}, "", "Threads.read", "threads.read\n", string.rep("a", 161)}
            for _, capability in ipairs(malformed) do
                local item = request("threads.read", {scope = "owned"})
                item.capability_request = {capability = capability, parameters = {scope = "owned"},
                    catalog_revision = 1, template_revision = 1, target = APP, path = ".security.policies +="}
                local proposed, err = grants.propose(vocabulary(), OWNER, APP, {item})
                test.is_nil(proposed)
                test.eq(err, "capability request identity is invalid")
            end
            local missing = request("threads.read", {scope = "owned"})
            missing.capability_request = {parameters = {scope = "owned"}, catalog_revision = 1,
                template_revision = 1, target = APP, path = ".security.policies +="}
            local proposed, err = grants.propose(vocabulary(), OWNER, APP, {missing})
            test.is_nil(proposed)
            test.eq(err, "capability request identity is invalid")
        end)
        test.it("reuses only a live grant record containing the resolved set", function()
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("threads.read", {scope = "owned"})}))
            local first = assert(grants.record(OWNER, "workspace-1", APP, proposed,
                "approval-first", 1))
            local decoded = assert(grants.decode(first, OWNER, "workspace-1", APP, vocabulary()))
            local installed_entries: {[string]: unknown} = {}
            installed_entries[proposed.policies[1].id] = proposed.policies[1]
            installed_entries["app.notes:request"] = {kind = "ns.requirement",
                data = {default = proposed.policies[1].id}}
            test.is_true(grants.live(decoded, function(id: string): unknown return installed_entries[id] end))
            installed_entries[proposed.policies[1].id] = nil
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
            local changed = assert(bounds.object(first.data))
            changed.revision = 0
            test.is_nil(grants.decode(first, OWNER, "workspace-1", APP, vocabulary()))
            changed.revision = 1
            changed.digest = string.rep("0", 64)
            test.is_nil(grants.decode(first, OWNER, "workspace-1", APP, vocabulary()))
            changed.digest = proposed.digest
            local policies = principals.objects(changed.policies)
            policies[1].data = {policy = {actions = {"registry.overlay.apply"}, resources = "*", effect = "allow"}}
            test.is_nil(grants.decode(first, OWNER, "workspace-1", APP, vocabulary()))
        end)
        test.it("renders replaced meanings from the shared revocation report", function()
            local words = vocabulary()
            local previous = assert(capability_model.resolve(words, "threads.read", {scope = "owned"}))
            previous[1].template_revision = 2
            local proposed = assert(grants.propose(words, OWNER, APP,
                {request("threads.read", {scope = "owned"})}))
            local compared = assert(grants.diff(words, {capabilities = previous}, proposed))
            test.eq(#(principals.items(compared.changed)), 1)
            local revocation = compared.revocation
            local revoked = revocation.grants
            test.eq(#revoked, 1)
            test.eq(revoked[1].template_revision, 2)
            test.is_true(table.concat(principals.strings(compared.lines), "\n"):find("revoked:", 1, true) ~= nil)
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
            test.eq((principals.objects(decoded.policies))[1].id, proposed.policies[1].id)
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
            local decoded = assert(grants.decode(record, OWNER, "workspace-1", APP, vocabulary()))
            test.eq(#(principals.items(decoded.capabilities)), 3)
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
            test.eq((assert(bounds.object(proposed.volumes[1].data))).directory, "alpha/docs")
            test.is_nil(grants.propose(vocabulary(), OWNER, APP,
                {request("workspace.files.read", {subpath = "docs"})}))
            test.is_true((assert(bounds.object(proposed.volumes[1].data))).readonly)
            local record = assert(grants.record(OWNER, "workspace-1", APP, proposed,
                "approval-files", 1))
            local decoded = assert(grants.decode(record, OWNER, "workspace-1", APP, vocabulary()))
            local installed_entries: {[string]: unknown} = {}
            installed_entries[proposed.policies[1].id] = proposed.policies[1]
            installed_entries[proposed.volumes[1].id] = proposed.volumes[1]
            installed_entries["app.notes:request"] = {kind = "ns.requirement",
                data = {default = proposed.policies[1].id}}
            test.is_true(grants.live(decoded, function(id: string): unknown return installed_entries[id] end))
            installed_entries[proposed.volumes[1].id] = nil
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
            test.eq(#(principals.items(decoded.databases)), 1)
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
            local body = assert(bounds.object((assert(bounds.object(proposed.policies[1].data))).policy))
            test.eq((principals.strings(body.actions))[1], "funcs.call")
        end)
        test.it("materializes managed agent launch as the sessions contract on the exact definitions", function()
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("agents.launch", {definitions = {"acme:research"}})}))
            test.eq(#proposed.capabilities, 1)
            test.eq(proposed.capabilities[1].operation, "agents.launch")
            test.eq(proposed.policies[1].kind, "security.policy.expr")
            local body = assert(bounds.object((assert(bounds.object(proposed.policies[1].data))).policy))
            local actions: {[string]: boolean} = {}
            for _, action in ipairs(principals.strings(body.actions)) do actions[action] = true end
            test.is_true(actions["contract.get"])
            test.is_true(actions["contract.open"])
            test.is_true(actions["contract.call"])
            test.is_true(actions["funcs.call"])
            test.is_true(actions["bee.harness.launch"])
            local expression = body.expression
            test.is_true(expression:find('resource in ["acme:research"]', 1, true) ~= nil)
            test.is_true(expression:find("agent_call", 1, true) == nil)
            test.is_true(expression:find("resource matches", 1, true) == nil)
            test.is_true(expression:find("bee.threads.sessions.binding:run", 1, true) ~= nil)
            test.is_true(expression:find('"history", "await"', 1, true) ~= nil)
        end)
        test.it("materializes process execution as a dedicated executor and an exact command policy", function()
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("process.exec", {command = "/usr/bin/git status", directory = "src"})}, nil, FOLDER))
            test.eq(#proposed.capabilities, 1)
            test.eq(proposed.capabilities[1].operation, "process.exec")
            test.eq(#proposed.executors, 1)
            local executor = proposed.executors[1]
            test.eq(executor.kind, "exec.native")
            test.is_true(tostring(executor.id):find("^bee%.gov%.grants:executor%.[0-9a-f]+$") ~= nil)
            local config = assert(bounds.object(executor.data))
            test.eq(config.default_work_dir, "alpha/src")
            local environment = assert(bounds.object(config.default_env))
            test.eq(environment.PATH, "${env:bee.capability:exec_path}")
            local names = 0
            for _ in pairs(environment) do names = names + 1 end
            test.eq(names, 1)
            test.eq(proposed.policies[1].kind, "security.policy.expr")
            test.is_true(grants.expression("process.exec"))
            test.is_true(grants.expression("agents.launch"))
            test.is_false(grants.expression("contract.call"))
            local body = assert(bounds.object((assert(bounds.object(proposed.policies[1].data))).policy))
            local actions = principals.strings(body.actions)
            test.eq(table.concat(actions, ","), "funcs.call,exec.get,exec.run")
            test.is_true(tostring(body.expression):find('action == "funcs.call" && resource == "bee.gov.binding:granted_resources"', 1, true) ~= nil)
            local expression = tostring(body.expression)
            test.is_true(expression:find('action == "exec.get" && resource == "' .. executor.id .. '"', 1, true) ~= nil)
            test.is_true(expression:find('meta.executor == "' .. executor.id .. '"', 1, true) ~= nil)
            test.is_true(expression:find('meta.work_dir == ""', 1, true) ~= nil)
            test.is_true(expression:find("len(meta.env_names) == 0", 1, true) ~= nil)
            test.is_true(expression:find('resource == "/usr/bin/git status" || resource startsWith "/usr/bin/git status "', 1, true) ~= nil)
            test.is_nil(grants.propose(vocabulary(), OWNER, APP,
                {request("process.exec", {command = "make", directory = "src"})}))
            test.is_nil(grants.propose(vocabulary(), OWNER, APP,
                {request("process.exec", {command = "make", directory = ".wippy"})}, nil, FOLDER))
            local root = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("process.exec", {command = "make", directory = "."})}, nil, FOLDER))
            test.eq((assert(bounds.object(root.executors[1].data))).default_work_dir, "alpha")
            test.is_true(root.executors[1].id ~= executor.id)
            local record = assert(grants.record(OWNER, "workspace-1", APP, proposed, "approval-exec", 1))
            local decoded = assert(grants.decode(record, OWNER, "workspace-1", APP, vocabulary()))
            test.eq(#(principals.items(decoded.executors)), 1)
            test.eq(decoded.digest, proposed.digest)
            local installed_entries: {[string]: unknown} = {}
            installed_entries[proposed.policies[1].id] = proposed.policies[1]
            installed_entries[executor.id] = executor
            installed_entries["app.notes:request"] = {kind = "ns.requirement",
                data = {default = proposed.policies[1].id}}
            test.is_true(grants.live(decoded, function(id: string): unknown return installed_entries[id] end))
            installed_entries[executor.id] = nil
            test.is_false(grants.live(decoded, function(id: string): unknown return installed_entries[id] end))
        end)
        test.it("lets the application scope call exactly its approved agent tools", function()
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("agent.tools", {tools = {"app.notes:search", "app.notes:add"}})}))
            test.eq(proposed.capabilities[1].operation, "agent.tools")
            test.eq(proposed.policies[1].kind, "security.policy")
            local body = assert(bounds.object((assert(bounds.object(proposed.policies[1].data))).policy))
            test.eq(table.concat(principals.strings(body.actions), ","), "funcs.call")
            test.eq(table.concat(principals.strings(body.resources), ","), "app.notes:add,app.notes:search")
            local record = assert(grants.record(OWNER, "workspace-1", APP, proposed, "approval-tools", 1))
            test.eq(assert(grants.decode(record, OWNER, "workspace-1", APP, vocabulary())).digest, proposed.digest)
        end)
        test.it("grants scoped HTTP only through the host gateway", function()
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("http.api", {origin = "https://api.example.com",
                    methods = {"GET"}, path_prefix = "/v1"})}))
            test.eq(#proposed.capabilities, 1)
            test.eq(proposed.capabilities[1].operation, "http.request")
            local scope = assert(bounds.object(proposed.capabilities[1].scope))
            test.eq(scope.path_prefix, "/v1")
            test.eq(proposed.policies[1].kind, "security.policy")
            local body = assert(bounds.object((assert(bounds.object(proposed.policies[1].data))).policy))
            test.eq((principals.strings(body.actions))[1], "funcs.call")
            test.eq(#(principals.strings(body.resources)), 1)
            test.eq((principals.strings(body.resources))[1], "bee.gov.binding:http_request")
        end)
        test.it("generates Hive exposure over exactly the approved operations", function()
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("hive.expose", {operations = {"bee.hive.telemetry.binding:stats", "bee.hive.telemetry.binding:presence"},
                    mode = "open", audiences = {"*"}}, 2)}))
            test.eq(#proposed.capabilities, 1)
            test.eq(proposed.capabilities[1].operation, "hive.expose")
            test.eq(proposed.capabilities[1].resource, "open")
            local scope = assert(bounds.object(proposed.capabilities[1].scope))
            local operations = principals.strings(scope.operations)
            test.eq(#operations, 2)
            test.eq(operations[1], "bee.hive.telemetry.binding:presence")
            test.eq(operations[2], "bee.hive.telemetry.binding:stats")
            test.eq(#proposed.policies, 1)
            local generated = assert(bounds.object(proposed.policies[1]))
            test.eq(generated.kind, "security.policy")
            local groups = principals.strings(generated.groups)
            test.eq(#groups, 1)
            test.eq(groups[1], "bee.security.hive:hive_exposure_scope")
            local body = assert(bounds.object((assert(bounds.object(generated.data))).policy))
            local actions = principals.strings(body.actions)
            test.eq(#actions, 1)
            test.eq(actions[1], "hive.expose.open")
            local resources = principals.strings(body.resources)
            test.eq(#resources, 2)
            test.eq(resources[1], "bee.hive.telemetry.binding:presence")
            test.eq(resources[2], "bee.hive.telemetry.binding:stats")
            test.eq(body.effect, "allow")
            test.eq(proposed.bindings[1].requirement_id, "app.notes:request")
            test.eq(proposed.bindings[1].policy_id, generated.id)
            local record = assert(grants.record(OWNER, "workspace-1", APP, proposed, "approval-expose", 1))
            local decoded = assert(grants.decode(record, OWNER, "workspace-1", APP, vocabulary()))
            local installed_entries: {[string]: unknown} = {}
            installed_entries[generated.id] = generated
            installed_entries["app.notes:request"] = {kind = "ns.requirement",
                data = {default = generated.id}}
            test.is_true(grants.live(decoded, function(id: string): unknown return installed_entries[id] end))
            local lines = assert(capability_model.render(vocabulary(), proposed.capabilities))
            test.is_true(table.concat(lines, "\n"):find("Hive operations bee.hive.telemetry.binding:presence", 1, true) ~= nil)
        end)
        test.it("targets the supervisor exposure scope with a loadable grant", function()
            local proposed = assert(grants.propose(vocabulary(), OWNER, APP,
                {request("hive.expose", {operations = {"bee.hive:probe_open"},
                    mode = "open", audiences = {"node-1"}}, 2)}))
            local generated = assert(bounds.object(proposed.policies[1]))
            test.eq(generated.kind, "security.policy")
            local groups = principals.strings(generated.groups)
            test.eq(#groups, 1)
            test.eq(groups[1], "bee.security.hive:hive_exposure_scope")
            local body = assert(bounds.object((assert(bounds.object(generated.data))).policy))
            test.eq((principals.strings(body.actions))[1], "hive.expose.open")
            test.eq((principals.strings(body.resources))[1], "bee.hive:probe_open")
            test.eq(body.effect, "allow")
        end)
        test.it("materializes the package capabilities with their reviewed bodies", function()
            local vocabulary_value = vocabulary()
            local cases = {
                {capability = "hive.view", operation = "hive.view",
                    actions = {"system.read"}, kind = "security.policy"},
                {capability = "desktop.application_stop", operation = "desktop.application_stop",
                    actions = {"system.read"}, kind = "security.policy"},
                {capability = "hub.manage", operation = "hub.manage",
                    actions = {"bee.hub.manage"}, kind = "security.policy"},
                {capability = "gov.delivery.manage", operation = "gov.delivery.manage",
                    actions = {"bee.gov.delivery.manage"}, kind = "security.policy"},
                {capability = "gov.delivery.activate", operation = "gov.delivery.activate",
                    actions = {"bee.gov.delivery.activate"}, kind = "security.policy"},
            }
            for _, case in ipairs(cases) do
                local proposed = assert(grants.propose(vocabulary_value, OWNER, APP,
                    {request(case.capability, {})}))
                test.eq(proposed.capabilities[1].operation, case.operation)
                test.eq(proposed.policies[1].kind, case.kind)
                local body = assert(bounds.object((assert(bounds.object(proposed.policies[1].data))).policy))
                local found = false
                for _, action in ipairs(principals.strings(body.actions)) do
                    for _, wanted in ipairs(case.actions) do
                        if action == wanted then found = true end
                    end
                end
                test.is_true(found)
                local lines = assert(capability_model.render(vocabulary_value, proposed.capabilities))
                test.eq(#lines, 1)
            end
        end)
        test.it("round-trips an installed package grant record", function()
            local vocabulary_value = vocabulary()
            local proposed = assert(grants.propose(vocabulary_value, OWNER, APP,
                {request("hub.manage", {})}))
            local record = assert(grants.record(OWNER, "workspace-1", APP, proposed,
                "approval-package", 1))
            local decoded = assert(grants.decode(record, OWNER, "workspace-1", APP, vocabulary_value))
            local installed_entries: {[string]: unknown} = {}
            installed_entries[proposed.policies[1].id] = proposed.policies[1]
            installed_entries["app.notes:request"] = {kind = "ns.requirement",
                data = {default = proposed.policies[1].id}}
            test.is_true(grants.live(decoded, function(id: string): unknown return installed_entries[id] end))
            local compared = assert(grants.diff(vocabulary_value, nil, proposed))
            test.is_true(compared.requires_approval)
            test.is_true(table.concat(compared.lines, "\n"):find("Plan and apply Hub", 1, true) ~= nil)
        end)
        test.it("grants Bee self-update only to the host Modules app", function()
            local vocabulary_value = vocabulary()
            local request_value = request("hub.self_update", {})
            request_value.targets = {"bee.apps.modules:app"}
            local cap = request_value.capability_request
            if type(cap) ~= "table" then error("missing capability request") end
            cap.target = "bee.apps.modules:app"
            local proposed = assert(grants.propose(vocabulary_value, OWNER,
                "bee.apps.modules:app", {request_value}))
            local data = proposed.policies[1].data
            if type(data) ~= "table" then error("missing policy data") end
            local body = data.policy
            if type(body) ~= "table" then error("missing policy") end
            local actions, resources = body.actions, body.resources
            if type(actions) ~= "table" or type(resources) ~= "table" then error("missing policy scope") end
            test.eq(actions[1], "bee.hub.self_update")
            test.eq(resources[1], "bee/bee")
            local agent_request = request("hub.self_update", {})
            agent_request.targets = {"app.notes:agent"}
            local agent_cap = agent_request.capability_request
            if type(agent_cap) ~= "table" then error("missing capability request") end
            agent_cap.target = "app.notes:agent"
            test.is_nil(grants.propose(vocabulary_value, OWNER, "app.notes:agent", {agent_request}))
        end)
    end)
end
return test.run_cases(define_tests)
