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

type Object = {[string]: unknown}
local WORKSPACE = "hive-receiver-workspace"
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

local function install(audience: string, mode: string?, blocked: boolean?): string
    remove()
    local vocabulary = assert(model.decode(assert(registry.get("bee.capability:catalog"))))
    local requirement = {id = "receiver.sdk:exposure", value = nil, expected_kind = "security.policy", targets = {RUN},
        capability_request = {capability = "hive.expose", parameters = {operations = {RUN},
            mode = mode or "open", audiences = {audience}}, catalog_revision = model.revisions(vocabulary, "hive.expose"),
            template_revision = 2, target = RUN, path = ".security.policies +="}}
    local proposal = assert(grants.propose(vocabulary, OWNER, APP, {requirement}))
    local record = assert(grants.record(OWNER, WORKSPACE, APP, proposal, "receiver-approval", 1))
    local entries: {Object} = {
        {id = APP, kind = "process.lua", meta = {type = "bee.app", application = {api_version = 1,
            title = "Receiver SDK", lifetime = "view", revision = "1", instance_policy = "multiple"}},
            data = {source = "return {main = function() end}", method = "main"}},
        {id = RUN, kind = "function.lua", meta = {application_ref = APP, hive = mode or "open", hive_service = "test-sdk",
            hive_operation = {name = "run", revision = "1", input = {type = "object", additionalProperties = false,
                properties = {configuration = {type = "string"}}, required = {"configuration"}}, output = {type = "object"}}},
            data = {method = "run", modules = {"security", "ctx"}, source = [[
local security = require("security")
local ctx = require("ctx")
return {run = function(args)
    return {configuration = args.configuration, actor = security.actor():id(),
        registry = security.can("registry.get", "bee:db"), database = security.can("db.get", "bee:db"),
        exposure = security.can("hive.expose.open", "unrelated.runner:run"), caller = ctx.get("bee.hive.caller")}
end}]]}}}
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
    for _, binding in ipairs(proposal.bindings) do
        entries[#entries + 1] = {id = binding.requirement_id, kind = "ns.requirement",
            meta = {value_kind = "security.policy", capability = "hive.expose",
                parameters = {operations = {RUN}, mode = mode or "open", audiences = {audience}},
                reason = "Expose the receiver fixture"},
            data = {targets = {{entry = RUN, path = ".security.policies +="}}}}
    end
    assert(materializer.reconcile_composed(OWNER, entries, nil,
        {policies = proposal.policies, bindings = proposal.bindings, record = record}))
    local changes = assert(registry.snapshot()):changes()
    changes:create({id = ADMISSION, kind = "registry.entry", meta = {type = "bee.node.application_admission"},
        data = {bindings = {{definition_id = APP, policies = {tostring(proposal.policies[1].id)}}}}})
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
