-- MIT
local test = require("test")
local registry = require("registry")
local system = require("system")
local protocol = require("protocol")
local bounds = require("bounds")
local model = require("model")
local grants = require("grants")
local materializer = require("materializer")
local process = require("process")
local channel = require("channel")
local admission = require("admission")
local time = require("time")
local uuid = require("uuid")
local funcs = require("funcs")
local application = require("application")
local json = require("json")
local security = require("security")

type Object = {[string]: unknown}
local WORKSPACE = "012345678901234567890123456789ab"
local APP = "receiver.sdk:app"
local RUN = "unrelated.runner:run"
local OWNER = "bee.tests.hive:installed_sdk"
local ADMISSION = "bee.tests.hive:receiver_admission"

local function remove()
    local overlay = assert(registry.overlay(OWNER))
    local entries = assert(overlay:entries())
    local changes = overlay:changes()
    for _, entry in ipairs(entries) do changes:delete(entry.id) end
    if #entries > 0 then assert(changes:apply()) end
    local admission = registry.get(ADMISSION)
    if admission then
        changes = assert(registry.snapshot()):changes()
        changes:delete(ADMISSION)
        assert(changes:apply())
    end
end

local function install(audience: string, mode: string?, blocked: boolean?, calling: boolean?, tooling: boolean?): string
    remove()
    local vocabulary = assert(model.decode(assert(registry.get("bee.capability:catalog"))))
    local requirement = {id = "receiver.sdk:exposure", value = nil, expected_kind = "security.policy", targets = {RUN},
        capability_request = {capability = "hive.expose", parameters = {operations = {RUN},
            mode = mode or "open", audiences = {audience}}, catalog_revision = model.revisions(vocabulary, "hive.expose"),
            template_revision = 2, target = RUN, path = ".security.policies +="}}
    local requirements: {Object} = {requirement}
    if calling then
        requirements[#requirements + 1] = {id = "receiver.sdk:call", expected_kind = "security.policy", targets = {APP},
            capability_request = {capability = "hive.call", parameters = {nodes = {audience, "runner"}, workspaces = {WORKSPACE},
                applications = {APP}, services = {"test-sdk"}, operations = {"run"}},
                catalog_revision = vocabulary.revision, template_revision = 1, target = APP, path = ".security.policies +="}}
    end
    if tooling then
        requirements[#requirements + 1] = {id = "receiver.sdk:agent_tools", expected_kind = "security.policy", targets = {APP},
            capability_request = {capability = "agent.tools", parameters = {tools = {RUN, "other.runner:run"}},
                catalog_revision = vocabulary.revision, template_revision = 1, target = APP, path = ".security.policies +="}}
    end
    local proposal = assert(grants.propose(vocabulary, OWNER, APP, requirements))
    local record = assert(grants.record(OWNER, WORKSPACE, APP, proposal, "receiver-approval", 1))
    local entries: {Object} = {
        {id = APP, kind = "process.lua", meta = {type = "bee.app", application = {api_version = 1,
            title = "Receiver SDK", lifetime = "view", revision = "1", instance_policy = "multiple"}},
            data = {source = "return {main = function() end}", method = "main"}},
        {id = RUN, kind = "function.lua", meta = {application_ref = APP, hive = mode or "open", hive_service = "test-sdk",
            hive_operation = {name = "run", revision = "1", effect = "read", input = {type = "object", additionalProperties = false,
                properties = {configuration = {type = "string"}}, required = {"configuration"}}, output = {type = "object"}}},
            data = {method = "run", modules = {"security", "ctx"}, source = [[
local security = require("security")
local ctx = require("ctx")
return {run = function(args)
    return {configuration = args.configuration, actor = security.actor():id(),
        registry = security.can("registry.get", "bee:db"), database = security.can("db.get", "bee:db"),
        exposure = security.can("hive.expose.open", "unrelated.runner:run"), caller = ctx.get("bee.hive.caller")}
end}]]}}}
    if tooling then
        entries[#entries + 1] = {id = "other.runner:run", kind = "function.lua",
            meta = {type = "tool", application_ref = APP, hive = "open", hive_service = "test-sdk",
                hive_operation = {name = "unexposed", revision = "1", effect = "read", input = {type = "object"}, output = {type = "object"}},
                llm_alias = "unexposed_sdk", llm_description = "An application tool without a Hive exposure grant",
                input_schema = '{"type":"object"}', output_schema = '{"type":"object"}'},
            data = {method = "run", source = "return {run = function() return {ok = true, value = {}} end}"}}
    end
    if blocked then
        local operation = entries[2]
        operation.meta.hive_operation.input.properties.notify = {type = "string"}
        operation.data.modules = {"process"}
        operation.data.source = [[
local process = require("process")
return {run = function(args)
    local releases = assert(process.listen("bee.tests.hive.release", {message = true}))
    assert(process.send(args.notify, "bee.tests.hive.started", {pid = tostring(process.pid())}))
    assert(releases:receive())
    return {configuration = args.configuration}
end}]]
    end
    for _, item in ipairs(requirements) do
        local requested = item.capability_request
        entries[#entries + 1] = {id = item.id, kind = "ns.requirement",
            meta = {value_kind = "security.policy", capability = requested.capability,
                parameters = requested.parameters, reason = "Approve the receiver fixture"},
            data = {targets = {{entry = requested.target, path = ".security.policies +="}}}}
    end
    assert(materializer.reconcile_composed(OWNER, entries, nil,
        {policies = proposal.policies, bindings = proposal.bindings, record = record}))
    local changes = assert(registry.snapshot()):changes()
    changes:create({id = ADMISSION, kind = "registry.entry", meta = {type = "bee.node.application_admission"},
        data = {bindings = {{definition_id = APP, policies = (function(): {string}
            local ids: {string} = {}
            for _, policy in ipairs(proposal.policies) do ids[#ids + 1] = tostring(policy.id) end
            return ids
        end)()}}}})
    assert(changes:apply())
    return tostring(proposal.policies[1].id)
end

local function call(extra: Object?): protocol.Reply
    local request: Object = {application = APP, workspace_id = WORKSPACE, service = "test-sdk", operation = "run",
        arguments = {configuration = "project-ci"}}
    for key, value in pairs(extra or {}) do request[key] = value end
    local reply, err = protocol.call(assert(system.node.id()), "application.call", request, "5s")
    if not reply then error(tostring(err)) end
    return reply
end

local function refused(reply: protocol.Reply, reason: string)
    test.is_false(reply.ok)
    test.contains(tostring(reply.error), reason)
end

local function program(source: string, output: Object)
    local overlay = assert(registry.overlay(OWNER))
    local entry = assert(overlay:get(RUN))
    local data = assert(bounds.object(entry.data))
    data.source = source
    data.modules = nil
    local declaration = assert(bounds.object(entry.meta.hive_operation))
    declaration.output = output
    local changes = overlay:changes()
    changes:update(entry)
    assert(changes:apply())
end

local function define_tests()
    test.describe("Hive receiver authorization", function()
        test.it("runs an explicitly associated operation under its admitted application's scope", function()
            install(assert(system.node.id()))
            local reply = call()
            remove()
            test.is_true(reply.ok, tostring(reply.error))
            local value = assert(bounds.object(assert(reply.value).result))
            test.eq(value.configuration, "project-ci")
            test.eq(value.actor, "bee.application:" .. WORKSPACE .. ":hive")
            test.eq(value.registry, false)
            test.eq(value.database, false)
            test.eq(value.exposure, false)
            local caller = assert(bounds.object(value.caller))
            test.eq(caller.node, assert(system.node.id()))
            test.not_nil(bounds.id(caller.pid))
        end)
        test.it("addresses a copy by its approved source identity and preserves its service name", function()
            install(assert(system.node.id()))
            local identity = {source_node = "sdk-author", source_workspace = "project", component = "vendor/test-sdk"}
            local changes = assert(registry.snapshot()):changes()
            changes:create({id = ADMISSION .. "_address", kind = "registry.entry",
                meta = {type = "bee.hive.application_address"}, data = {workspace_id = WORKSPACE,
                    application = APP, overlay_owner = OWNER, identity = identity, aliases = {"project-sdk"}}})
            assert(changes:apply())
            local named = call({application = identity})
            local aliased = call({application = {alias = "project-sdk"}})
            changes = assert(registry.snapshot()):changes()
            changes:delete(ADMISSION .. "_address")
            assert(changes:apply())
            remove()
            test.is_true(named.ok, tostring(named.error))
            test.is_true(aliased.ok, tostring(aliased.error))
            test.eq(assert(bounds.object(assert(named.value).result)).configuration, "project-ci")
        end)
        test.it("refuses a different source even when it declares the same component", function()
            install(assert(system.node.id()))
            local changes = assert(registry.snapshot()):changes()
            changes:create({id = ADMISSION .. "_address", kind = "registry.entry",
                meta = {type = "bee.hive.application_address"}, data = {workspace_id = WORKSPACE,
                    application = APP, overlay_owner = OWNER, identity = {source_node = "sdk-author",
                        source_workspace = "project", component = "vendor/test-sdk"}, aliases = {}}})
            assert(changes:apply())
            local reply = call({application = {source_node = "another-author", source_workspace = "project",
                component = "vendor/test-sdk"}})
            changes = assert(registry.snapshot()):changes()
            changes:delete(ADMISSION .. "_address")
            assert(changes:apply())
            remove()
            refused(reply, "address")
        end)
        test.it("refuses an artifact's address claim and a stale address owner", function()
            install(assert(system.node.id()))
            local identity = {source_node = "sdk-author", source_workspace = "project", component = "vendor/test-sdk"}
            local entry = {id = ADMISSION .. "_address", kind = "registry.entry",
                meta = {type = "bee.hive.application_address"}, data = {workspace_id = WORKSPACE,
                    application = APP, overlay_owner = OWNER, identity = identity, aliases = {}}}
            local changes = assert(registry.overlay(OWNER)):changes()
            changes:create(entry)
            assert(changes:apply())
            local forged = call({application = identity})
            changes = assert(registry.overlay(OWNER)):changes()
            changes:delete(entry.id)
            assert(changes:apply())
            entry.data.overlay_owner = "bee.tests.hive:another_installation"
            changes = assert(registry.snapshot()):changes()
            changes:create(entry)
            assert(changes:apply())
            local stale = call({application = identity})
            changes = assert(registry.snapshot()):changes()
            changes:delete(entry.id)
            assert(changes:apply())
            remove()
            refused(forged, "address")
            refused(stale, "owner")
        end)
        test.it("refuses ambiguous addresses, foreign workspaces and version fields", function()
            install(assert(system.node.id()))
            local identity = {source_node = "sdk-author", source_workspace = "project", component = "vendor/test-sdk"}
            local changes = assert(registry.snapshot()):changes()
            for _, suffix in ipairs({"_address", "_second_address"}) do
                changes:create({id = ADMISSION .. suffix, kind = "registry.entry",
                    meta = {type = "bee.hive.application_address"}, data = {workspace_id = WORKSPACE,
                        application = APP, overlay_owner = OWNER, identity = identity, aliases = {"project-sdk"}}})
            end
            assert(changes:apply())
            local duplicate_identity = call({application = identity})
            local duplicate_alias = call({application = {alias = "project-sdk"}})
            local foreign_workspace = call({application = identity, workspace_id = "another-workspace"})
            local versioned = call({application = {source_node = "sdk-author", source_workspace = "project",
                component = "vendor/test-sdk", version = "1"}})
            changes = assert(registry.snapshot()):changes()
            changes:delete(ADMISSION .. "_address")
            changes:delete(ADMISSION .. "_second_address")
            assert(changes:apply())
            remove()
            refused(duplicate_identity, "ambiguous")
            refused(duplicate_alias, "ambiguous")
            refused(foreign_workspace, "address")
            refused(versioned, "address")
        end)
        test.it("rejects malformed host aliases instead of treating them as absent", function()
            install(assert(system.node.id()))
            local identity = {source_node = "sdk-author", source_workspace = "project", component = "vendor/test-sdk"}
            local replies: {protocol.Reply} = {}
            for _, aliases in ipairs({false, "project-sdk", {"project-sdk", "project-sdk"}}) do
                local changes = assert(registry.snapshot()):changes()
                changes:create({id = ADMISSION .. "_address", kind = "registry.entry",
                    meta = {type = "bee.hive.application_address"}, data = {workspace_id = WORKSPACE,
                        application = APP, overlay_owner = OWNER, identity = identity, aliases = aliases}})
                assert(changes:apply())
                replies[#replies + 1] = call({application = identity})
                changes = assert(registry.snapshot()):changes()
                changes:delete(ADMISSION .. "_address")
                assert(changes:apply())
            end
            remove()
            for _, reply in ipairs(replies) do refused(reply, "malformed") end
        end)
        test.it("resolves an approved source identity directly from its live governed admission", function()
            local policy = install(assert(system.node.id()))
            local original = assert(registry.get("bee.gov:activation_profiles"))
            local configured = assert(registry.get("bee.gov:activation_profiles"))
            local overlay = assert(registry.overlay(OWNER))
            local app = assert(overlay:get(APP))
            local generated = assert(overlay:get(policy))
            local bindings = {{definition_id = APP, policies = {policy}}}
            configured.data.profiles = {{workspace_id = WORKSPACE, source_node = "sdk-author", source_workspace = "project",
                component = "vendor/test-sdk", overlay_owner = OWNER, approval_policy = "fixture-delivery", resolver = "overlay",
                parameters = {}, allow = {packages = {}, namespaces = {"receiver.sdk", "unrelated.runner"},
                    kinds = {"process.lua", "function.lua", "ns.requirement"}, modules = {"security", "ctx"},
                    databases = {}, grants = {policy}, auto_start = false}, applications = bindings}}
            local measured = assert(admission.project({identity_generation = "current", workspace_id = WORKSPACE,
                overlay_owner = OWNER, source_node = "sdk-author", source_workspace = "project", artifact_digest = string.rep("a", 64),
                bindings = bindings, artifact_entries = {app}, registry_entries = {generated}, overlay_ids = {},
                generated_policies = {generated}}))
            local changes = assert(registry.snapshot()):changes()
            changes:delete(ADMISSION)
            changes:update(configured)
            assert(changes:apply())
            changes = overlay:changes()
            changes:create(assert(admission.entry(measured.bytes, measured.digest)))
            assert(changes:apply())
            local accepted = call({application = {source_node = "sdk-author", source_workspace = "project", component = "vendor/test-sdk"}})
            local wrong_component = call({application = {source_node = "sdk-author", source_workspace = "project", component = "vendor/other"}})
            changes = assert(registry.snapshot()):changes()
            changes:update(original)
            assert(changes:apply())
            remove()
            test.is_true(accepted.ok, tostring(accepted.error))
            refused(wrong_component, "address")
        end)
        test.it("refuses an audience other than the authenticated sender node", function()
            install("another-node")
            local reply = call()
            remove()
            refused(reply, "audience")
        end)
        test.it("refuses an operation whose exposure policy is removed", function()
            local policy = install(assert(system.node.id()))
            local changes = assert(registry.overlay(OWNER)):changes()
            changes:delete(policy)
            assert(changes:apply())
            local reply = call()
            remove()
            refused(reply, "expos")
        end)
        test.it("refuses a declared operation outside the live exposure grant", function()
            install(assert(system.node.id()))
            local overlay = assert(registry.overlay(OWNER))
            local entry = assert(overlay:get(RUN))
            local declaration = assert(bounds.object(entry.meta.hive_operation))
            declaration.name = "hidden"
            local changes = overlay:changes()
            changes:create({id = "unrelated.runner:hidden", kind = entry.kind, meta = entry.meta, data = entry.data})
            assert(changes:apply())
            local reply = call({operation = "hidden"})
            remove()
            refused(reply, "not exposed")
        end)
        test.it("refuses an admission revoked while its grant remains installed", function()
            install(assert(system.node.id()))
            local changes = assert(registry.snapshot()):changes()
            changes:delete(ADMISSION)
            assert(changes:apply())
            local reply = call()
            remove()
            refused(reply, "admission")
        end)
        test.it("refuses an artifact's claim to be its own host admission", function()
            install(assert(system.node.id()))
            local changes = assert(registry.snapshot()):changes()
            local entry = assert(registry.get(ADMISSION))
            changes:delete(ADMISSION)
            assert(changes:apply())
            changes = assert(registry.overlay(OWNER)):changes()
            changes:create({id = "receiver.sdk:forged_admission", kind = entry.kind, meta = entry.meta, data = entry.data})
            assert(changes:apply())
            local reply = call()
            remove()
            refused(reply, "admission")
        end)
        test.it("refuses caller identity fields instead of trusting them", function()
            install(assert(system.node.id()))
            for _, field in ipairs({"caller", "actor", "subject", "peer_node"}) do
                local reply = call({[field] = "destination-admin"})
                refused(reply, "unknown field")
            end
            remove()
        end)
        test.it("refuses an undeclared operation and arguments outside its input contract", function()
            install(assert(system.node.id()))
            local unknown = call({operation = "other"})
            local malformed = call({arguments = {configuration = 7}})
            remove()
            refused(unknown, "operation")
            refused(malformed, "configuration")
        end)
        test.it("requires a trusted subject mapping for policy mode", function()
            install(assert(system.node.id()), "policy")
            local reply = call()
            remove()
            refused(reply, "subject")
        end)
        test.it("refuses operation policies that escape the installed application scope", function()
            install(assert(system.node.id()))
            local overlay = assert(registry.overlay(OWNER))
            local entry = assert(overlay:get(RUN))
            local data = assert(bounds.object(entry.data))
            data.security = {policies = {"bee.hive.security:application_dispatch"}}
            local changes = overlay:changes()
            changes:update(entry)
            assert(changes:apply())
            local reply = call()
            remove()
            refused(reply, "own security")
        end)
        test.it("preserves installed operation ownership against a foreign overlay replacement", function()
            install(assert(system.node.id()))
            local owned = assert(registry.overlay(OWNER))
            local original = assert(owned:get(RUN))
            local foreign = assert(registry.overlay("bee.tests.hive:foreign_shadow"))
            local changes = foreign:changes()
            changes:create({id = RUN, kind = original.kind, meta = original.meta,
                data = {method = "run", modules = {"security"}, security = {policies = {"bee.hive.security:admission_store"}},
                    source = [[local security = require("security")
return {run = function() return {database = security.can("db.get", "bee:db")} end}]]}})
            local applied, err = changes:apply()
            local reply = call()
            remove()
            test.is_nil(applied)
            test.contains(tostring(err), "already owned")
            test.is_true(reply.ok, tostring(reply.error))
            test.eq(assert(bounds.object(assert(reply.value).result)).database, false)
        end)
        test.it("preserves a false result under a boolean output contract", function()
            install(assert(system.node.id()))
            program("return {run = function() return false end}", {type = "boolean"})
            local reply = call()
            remove()
            test.is_true(reply.ok, tostring(reply.error))
            test.eq(assert(reply.value).result, false)
        end)
        test.it("rejects a result outside the declared output contract", function()
            install(assert(system.node.id()))
            program("return {run = function() return 'wrong' end}", {type = "object"})
            local reply = call()
            remove()
            refused(reply, "invalid application reply")
        end)
        test.it("lets a scoped application call its peer copy through the granted host facade", function()
            local node = assert(system.node.id())
            install(node, nil, nil, true)
            local overlay = assert(registry.overlay(OWNER))
            local changes = overlay:changes()
            changes:create({id = "receiver.sdk:caller", kind = "function.lua", data = {method = "run", modules = {"funcs"},
                imports = {hive = "bee.hive:hive"}, source = [[local hive = require("hive")
return {run = function(request)
    local result, err = hive.call(request)
    return {result = result, error = err}
end}]]}})
            assert(changes:apply())
            local definition = assert(application.definition(APP))
            local actor = assert(application.actor(WORKSPACE, "caller", definition, 1))
            local scope = assert(application.scope(definition, WORKSPACE))
            local executor = funcs.new():with_actor(actor):with_scope(scope)
            local asked = {node = node, workspace_id = WORKSPACE, application = APP, service = "test-sdk", operation = "run",
                arguments = {configuration = "facade-ci"}, timeout = "5s"}
            local reply, err = executor:call("receiver.sdk:caller", asked)
            local called = bounds.object(reply)
            asked.node = "unapproved"
            local denied = bounds.object(executor:call("receiver.sdk:caller", asked))
            changes = assert(registry.snapshot()):changes()
            changes:delete(ADMISSION)
            assert(changes:apply())
            asked.node = "runner"
            local revoked = bounds.object(executor:call("receiver.sdk:caller", asked))
            remove()
            test.is_nil(err)
            test.not_nil(called)
            local result = assert(bounds.object(assert(called).result))
            test.eq(result.configuration, "facade-ci")
            test.eq(result.registry, false)
            test.eq(result.database, false)
            test.contains(tostring(assert(denied).error), "grant")
            test.contains(tostring(assert(revoked).error), "admission")
        end)
        test.it("requires a mutation key and durably replays without another effect", function()
            install(assert(system.node.id()))
            program([[local process = require("process")
return {run = function(args)
    assert(process.send(args.configuration, "bee.tests.hive.effect", {}))
    return {configuration = args.configuration}
end}]], {type = "object"})
            local overlay = assert(registry.overlay(OWNER))
            local entry = assert(overlay:get(RUN))
            entry.data.modules = {"process"}
            entry.meta.hive_operation.effect = "mutation"
            local changes = overlay:changes()
            changes:update(entry)
            assert(changes:apply())
            local effects = assert(process.listen("bee.tests.hive.effect", {message = true}))
            local args = {configuration = tostring(process.pid())}
            local missing = call({arguments = args})
            local key = tostring(uuid.v7())
            local first = call({arguments = args, idempotency_key = key})
            local second = call({arguments = args, idempotency_key = key})
            local conflict = call({arguments = {configuration = "changed"}, idempotency_key = key})
            local first_effect = channel.select({effects:case_receive(), time.after("100ms"):case_receive()})
            local no_more = channel.select({effects:case_receive(), time.after("100ms"):case_receive()})
            process.unlisten(effects)
            remove()
            refused(missing, "idempotency")
            test.is_true(first.ok, tostring(first.error))
            test.is_true(second.ok, tostring(second.error))
            test.eq(assert(second.value).result.configuration, assert(first.value).result.configuration)
            refused(conflict, "different")
            test.eq(first_effect.channel, effects)
            test.is_false(no_more.channel == effects)
        end)
        test.it("keeps a timed out mutation uncertain until its durable receipt completes", function()
            local started = assert(process.listen("bee.tests.hive.started", {message = true}))
            install(assert(system.node.id()), nil, true)
            local overlay = assert(registry.overlay(OWNER))
            local entry = assert(overlay:get(RUN))
            entry.meta.hive_operation.effect = "mutation"
            local changes = overlay:changes()
            changes:update(entry)
            assert(changes:apply())
            local key = tostring(uuid.v7())
            local args = {application = APP, workspace_id = WORKSPACE, service = "test-sdk", operation = "run",
                arguments = {configuration = "once", notify = tostring(process.pid())}, idempotency_key = key}
            local done = channel.new(1)
            coroutine.spawn(function()
                local reply, err = protocol.call(assert(system.node.id()), "application.call", args, "100ms", true)
                done:send({reply = reply, error = err})
            end)
            local start = channel.select({started:case_receive(), time.after("1s"):case_receive()})
            if start.channel ~= started then
                process.unlisten(started)
                remove()
                error("authorized mutation never starts")
            end
            local worker = assert(bounds.object(start.value:payload():data())).pid
            local timed = assert(bounds.object(done:receive()))
            local pending = call({arguments = args.arguments, idempotency_key = key})
            assert(process.send(tostring(worker), "bee.tests.hive.release", {}))
            local completed: protocol.Reply? = nil
            for _ = 1, 20 do
                completed = call({arguments = args.arguments, idempotency_key = key})
                if completed.ok then break end
                time.after("10ms"):receive()
            end
            process.unlisten(started)
            remove()
            local timed_reply = bounds.object(timed.reply)
            test.contains(tostring(timed.error or (timed_reply and timed_reply.error)), "outcome unknown")
            refused(pending, "outcome unknown")
            test.is_true(completed ~= nil and completed.ok, tostring(completed and completed.error))
        end)
        test.it("discovers only live exposed application tools approved for the authenticated peer", function()
            local node = assert(system.node.id())
            install(node, nil, nil, nil, true)
            local overlay = assert(registry.overlay(OWNER))
            local entry = assert(overlay:get(RUN))
            entry.meta.type = "tool"
            entry.meta.llm_alias = "remote_sdk"
            entry.meta.llm_description = "Runs the approved SDK configuration"
            entry.meta.input_schema = assert(json.encode(entry.meta.hive_operation.input))
            entry.meta.output_schema = assert(json.encode({type = "object"}))
            entry.data.source = [[return {run = function(args) return {ok = true, value = {configuration = args.configuration}} end}]]
            entry.data.modules = nil
            local changes = overlay:changes()
            changes:update(entry)
            assert(changes:apply())
            local found = assert(protocol.call(node, "application.discover", {}, "5s", true))
            local actor = assert(security.new_actor("gateway-peer-agent", {workspace_id = WORKSPACE}))
            local scope = security.new_scope({assert(security.policy("bee.security.gateway:gateway_tool_app_tools_policy"))})
            local gateway = funcs.new():with_actor(actor):with_scope(scope)
            local host_listing = assert(bounds.object(assert(gateway:call("bee.node.binding:app_tools", {node = node}))))
            local host_call = assert(bounds.object(assert(gateway:call("bee.node.binding:app_tools", {node = node,
                operation = "call", tool = "remote_sdk", arguments = {configuration = "gateway-ci"}}))))
            test.is_true(host_listing.ok == true, assert(json.encode(host_listing)))
            test.eq(#(assert(bounds.object(host_listing.value)).tools :: {Object}), 1)
            test.is_true(host_call.ok == true, assert(json.encode(host_call)))
            test.eq(assert(bounds.object(host_call.value)).configuration, "gateway-ci")
            local invoked = assert(protocol.call(node, "application.call", {application = APP, workspace_id = WORKSPACE,
                service = "test-sdk", operation = "run", arguments = {configuration = "remote-ci"}}, "5s", true))
            local forged = assert(protocol.call(node, "application.discover", {caller = "other-node"}, "5s", true))
            changes = assert(registry.snapshot()):changes()
            changes:delete(ADMISSION)
            assert(changes:apply())
            local revoked = assert(protocol.call(node, "application.discover", {}, "5s", true))
            remove()
            test.is_true(found.ok, tostring(found.error))
            local tools = assert(found.value).tools :: {Object}
            test.eq(#tools, 1)
            test.eq(tools[1].alias, "remote_sdk")
            test.eq(tools[1].workspace_id, WORKSPACE)
            test.eq(tools[1].service, "test-sdk")
            test.is_true(invoked.ok, tostring(invoked.error))
            refused(forged, "field")
            test.eq(#(assert(revoked.value).tools :: {Object}), 0)
            install("unapproved-peer", nil, nil, nil, true)
            local hidden = assert(protocol.call(node, "application.discover", {}, "5s", true))
            remove()
            test.is_true(hidden.ok, tostring(hidden.error))
            test.eq(#(assert(hidden.value).tools :: {Object}), 0)
        end)
        test.it("runs exposed associated tests through the existing runner and replays the same remote run", function()
            local node = assert(system.node.id())
            install(node)
            local overlay = assert(registry.overlay(OWNER))
            local entry = assert(overlay:get(RUN))
            entry.meta.type = "app_test"
            entry.meta.application = APP
            entry.meta.suite = "remote-sdk"
            entry.meta.hive_operation.effect = "mutation"
            entry.meta.hive_operation.input = {type = "object"}
            entry.meta.hive_operation.output = {type = "boolean"}
            entry.data.source = "return {run = function() return true end}"
            entry.data.modules = nil
            local changes = overlay:changes()
            changes:update(entry)
            assert(changes:apply())
            local function remote(request: Object): Object
                local reply = assert(protocol.call(node, "application.tests", request, "5s", true))
                test.is_true(reply.ok, tostring(reply.error))
                return assert(bounds.object(assert(reply.value).reply))
            end
            local listed = remote({operation = "list", application = APP})
            local key = tostring(uuid.v7())
            local started = remote({operation = "run", application = APP, idempotency_key = key})
            local replayed = remote({operation = "run", application = APP, idempotency_key = key})
            test.is_true(started.ok == true, assert(json.encode(started.error)))
            local run = assert(bounds.object(started.value))
            local result: Object? = nil
            for _ = 1, 30 do
                local status = remote({operation = "status", run_id = run.run_id})
                result = bounds.object(status.value)
                if result and result.state == "complete" then break end
                time.after("100ms"):receive()
            end
            changes = assert(registry.snapshot()):changes()
            changes:delete(ADMISSION)
            assert(changes:apply())
            local revoked = remote({operation = "status", run_id = run.run_id})
            remove()
            test.is_true(listed.ok == true, assert(json.encode(listed.error)))
            test.eq(#(assert(bounds.object(listed.value)).tests :: {Object}), 1)
            test.eq(assert(bounds.object(replayed.value)).run_id, run.run_id)
            test.eq(run.node, node)
            test.eq(assert(result).state, "complete")
            test.eq(assert(bounds.object(assert(result).totals)).passed, 1, assert(json.encode(result)))
            test.is_false(revoked.ok == true)
        end)
        test.it("rechecks admission after the execution queue opens", function()
            local started = assert(process.listen("bee.tests.hive.started", {message = true}))
            local replies = assert(process.listen("bee.tests.hive.queued", {message = true}))
            local barrier = assert(process.listen("bee.tests.hive.barrier", {message = true}))
            local pid = tostring(process.pid())
            install(assert(system.node.id()), nil, true)
            local done = channel.new(4)
            for _ = 1, 4 do
                coroutine.spawn(function()
                    done:send(call({arguments = {configuration = "running", notify = pid}}))
                end)
            end
            local workers: {string} = {}
            for _ = 1, 4 do
                local message = assert((started:receive()))
                local data = assert(bounds.object(message:payload():data()))
                workers[#workers + 1] = assert(bounds.id(data.pid))
            end
            local supervisor = tostring(assert(process.registry.lookup(protocol.SUPERVISOR, process.registry.LOCAL)))
            assert(process.send(supervisor, protocol.CALL, {op = "application.call", reply_topic = "bee.tests.hive.queued",
                ttl = 5000000000, args = {application = APP, workspace_id = WORKSPACE, service = "test-sdk", operation = "run",
                    arguments = {configuration = "queued", notify = pid}}}))
            assert(process.send(supervisor, protocol.CALL, {op = "node.list", reply_topic = "bee.tests.hive.barrier",
                ttl = 5000000000, args = {}}))
            assert((barrier:receive()))
            local changes = assert(registry.snapshot()):changes()
            changes:delete(ADMISSION)
            assert(changes:apply())
            for _, worker in ipairs(workers) do assert(process.send(worker, "bee.tests.hive.release", {})) end
            local queued = assert(bounds.object(assert(replies:receive()):payload():data()))
            for _ = 1, 4 do
                local answer = assert(bounds.object(done:receive()))
                test.is_true(answer.ok == true, tostring(answer.error))
            end
            process.unlisten(started)
            process.unlisten(replies)
            process.unlisten(barrier)
            remove()
            test.is_false(queued.ok == true)
            test.contains(tostring(queued.error), "admission")
        end)
    end)
end

return test.run_cases(define_tests)
