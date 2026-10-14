-- SPDX-License-Identifier: MIT

local test = require("test")
local fixtures = require("fixtures")
local funcs = require("funcs")
local registry = require("registry")
local system = require("system")
local uuid = require("uuid")
local bounds = require("bounds")
local principals = require("principals")
local artifact = require("artifact")
local publisher = require("publisher")
local delivery = require("delivery")
local governed = require("governed")
local library = require("library")
local harness = require("harness")
local memory_host = require("memory_host")

type Object = {[string]: unknown}

local FACADE = "bee.gov.binding:destination_call"

local function call(request: Object): Object
    local raw, err = funcs.call(FACADE, request)
    test.is_nil(err, tostring(err))
    return assert(bounds.object(raw))
end

local function ok(reply: Object): Object
    local fault = bounds.object(reply.error)
    test.is_true(reply.ok == true, tostring(fault and fault.code) .. ": " .. tostring(fault and fault.message))
    return assert(bounds.object(reply.value))
end

local function define_tests()
    test.describe("application removal", function()
        test.after_all(fixtures.registry_cleanup(true))
        test.after_all(memory_host.close_all)
        test.it("installs an application through the person's approval and removes it again", function()
            local suffix = assert(uuid.v7()):gsub("%-", ""):sub(1, 12)
            local name = "lifecycle_" .. suffix
            local namespace = "app." .. name
            local application = namespace .. ":app"
            local node = assert(system.node.id())
            local workspace = harness.isolated("lifecycle")
            local person = harness.person(workspace)
            local exact = assert(artifact.create({{id = application, kind = "process.lua",
                meta = {type = "bee.app", application = {api_version = 1, title = "Lifecycle", lifetime = "view",
                    revision = "1", instance_policy = "singleton", menus = {"bee.shell:apps_menu"}}},
                data = {source = "return {main = function() end}", method = "main"}},
                {id = namespace .. ":trait", kind = "registry.entry", meta = {type = "agent.trait", title = "Overlay hook", application_ref = application},
                    data = {prompt = "Review tools.", tools = {}, hooks = {"tool.before"}}},
                {id = namespace .. ":hook", kind = "function.lua",
                    meta = {type = "bee.session.hook", application_ref = application, application_revision = "1"},
                    data = {source = "return {hook = function(point: string, turn: {input: {text: string}}) return {kind = 'change', input = {text = turn.input.text .. ':overlay'}} end}", method = "hook"}}}))
            local prepared = publisher.prepare(node, {source_workspace = name, component = namespace, version = "1.0.0",
                artifact = {bytes = exact.bytes, digest = exact.digest}})
            test.is_true(prepared.ok == true, tostring(prepared.message))
            local descriptor = assert(bounds.object(assert(bounds.object(prepared.value)).descriptor))

            local available = ok(call({operation = "available", workspace_id = workspace}))
            local mine = 0
            for _, item in ipairs(principals.objects(available.versions)) do
                if item.key == descriptor.key then mine = mine + 1 end
            end
            test.eq(mine, 1)
            local staged = ok(call({operation = "stage", workspace_id = workspace, source_owner = node, feed = delivery.FEED,
                version_key = descriptor.key, descriptor_digest = descriptor.digest, idempotency_key = "stage-" .. suffix}))
            local identity = {workspace_id = workspace, source_node = node, source_workspace = name, version = "1.0.0"}
            local function with(fields: Object): Object
                local request: Object = {}
                for key, value in pairs(identity) do request[key] = value end
                for key, value in pairs(fields) do request[key] = value end
                return request
            end
            local reviewed = ok(call(with({operation = "review", expected_revision = staged.revision,
                idempotency_key = "review-" .. suffix, review_status = "accepted", review_reason = "reviewed"})))
            ok(call(with({operation = "select", expected_revision = reviewed.revision, idempotency_key = "select-" .. suffix})))
            local intent = ok(call(with({operation = "prepare", intent_id = "intent-" .. suffix, receipt_key = "prepare-" .. suffix})))
            test.eq(intent.phase, "approval_bound")

            local read = assert(bounds.object(person:call("bee.approvals.binding:read", {approval_id = intent.approval_id})))
            local approval = assert(bounds.object(read.value))
            local decided = assert(bounds.object(person:call("bee.approvals.binding:decide", {approval_id = intent.approval_id,
                expected_revision = approval.revision, proposal_digest = approval.proposal_digest, reviewed_digest = approval.reviewed_digest, decision = "approved"})))
            test.is_true(decided.ok == true, tostring(decided.message))

            local settled: Object = intent
            for attempt = 1, 8 do
                if settled.phase == "settled" then break end
                settled = ok(call({operation = "step", workspace_id = workspace, intent_id = "intent-" .. suffix,
                    receipt_key = "step-" .. suffix .. "-" .. tostring(attempt)}))
            end
            test.eq(settled.phase, "settled")
            test.eq(settled.outcome, "applied")
            harness.drain()
            test.not_nil((registry.get(application)))
            local admission_entry = assert(registry.get("bee.tests.memory:admission"))
            local original = admission_entry.data
            admission_entry.data = {bindings = {{definition_id = application,
                policies = {"bee.tests.memory:client_policy", "bee.tests.memory:index_policy"}}}}
            local changes = registry.snapshot():changes()
            changes:update(admission_entry)
            assert(changes:apply())
            local prior_workspace = memory_host.WORKSPACE
            memory_host.WORKSPACE = workspace
            local invoked, invocation_error = pcall(function()
                local session = memory_host.open(nil, namespace .. ":trait")
                local result = memory_host.call("bee.threads.hooks:dispatch", {session_ref = session.session, thread_id = session.thread,
                    workspace_id = workspace, point = "tool.before", occurrence_id = "overlay-" .. suffix, input = {text = "seed"}})
                test.eq(assert(bounds.object(result.input)).text, "seed:overlay")
            end)
            memory_host.WORKSPACE = prior_workspace
            admission_entry.data = original
            local restored = registry.snapshot():changes()
            restored:update(admission_entry)
            assert(restored:apply())
            assert(invoked, tostring(invocation_error))

            local installed = principals.objects(ok(call({operation = "activations", workspace_id = workspace})).activations)
            test.eq(#installed, 1)
            test.eq(installed[1].application, application)

            local stale = call({operation = "uninstall", workspace_id = workspace, source_workspace = name,
                receipt_key = "stale-remove-" .. suffix, expected_intent_id = "replaced-" .. suffix})
            test.eq(stale.ok, false)
            local fault = assert(bounds.object(stale.error))
            test.eq(fault.code, "CONFLICT")
            local removed = ok(call({operation = "uninstall", workspace_id = workspace, source_workspace = name,
                receipt_key = "remove-" .. suffix, expected_intent_id = "intent-" .. suffix}))
            test.eq(removed.intent_id, "intent-" .. suffix)
            test.is_nil((registry.get(application)))
            local history = principals.objects(ok(call({operation = "activations", workspace_id = workspace})).activations)
            test.eq(#history, 1)
            test.is_nil(history[1].observed_intent_id)
            test.eq(history[1].outcome, "applied")

            local shown = library.new(workspace)
            governed.apply_list(shown.governed, assert(governed.reply({ok = true, replayed = false,
                value = {owner_node = node, workspace_id = workspace, plans = {}}})))
            test.is_true(governed.apply_activations(shown.governed, assert(governed.reply({ok = true, replayed = false,
                value = {workspace_id = workspace, activations = history}}))))
            test.eq(#library.rows(shown, "installed"), 0)
            local past = library.rows(shown, "history")
            test.eq(#past, 1)
            test.eq(past[1].status, "Removed")
        end)
    end)
end

return test.run_cases(define_tests)
