-- MIT. A person installs an application the host admits and then removes it: the
-- application is gone from the registry and its removal stays in the history.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
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

type Object = {[string]: unknown}

local APPROVER = "bee.test.lifecycle_person"
local POLICY = "lifecycle-removal-test"
local FACADE = "bee.gov.binding:destination_call"

local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end

local person = funcs.new():with_actor(security.new_actor(APPROVER))
    :with_scope(scope({"bee.security.approvals:approval_decide_policy", "bee.approvals:client_test_policy"}))

-- The host's fixture: this test's person approves workspace applications, and
-- the shipped admission rule names that approval. Both are restored afterwards.
local function fixture(): () -> ()
    local approvers = assert(registry.get("bee.security.approvals:approver_policies"))
    local approver_data = assert(bounds.object(approvers.data))
    local listed = principals.objects(approver_data.policies)
    approver_data.policies = listed
    listed[#listed + 1] = {name = POLICY, approvers = {APPROVER}, max_ttl_ms = 60000}
    local profiles = assert(registry.get("bee.gov:activation_profiles"))
    local profile_data = assert(bounds.object(profiles.data))
    local rule = assert(bounds.object(profile_data.workspace_applications))
    local original = rule.approval_policy
    rule.approval_policy = POLICY
    local changes = registry.snapshot():changes()
    changes:update(approvers)
    changes:update(profiles)
    assert(changes:apply())
    return function()
        local restore = registry.snapshot():changes()
        local current = assert(registry.get("bee.gov:activation_profiles"))
        local current_data = assert(bounds.object(current.data))
        assert(bounds.object(current_data.workspace_applications)).approval_policy = original
        restore:update(current)
        assert(restore:apply())
    end
end

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
        test.it("installs an application through the person's approval and removes it again", function()
            local restore = fixture()
            local suffix = assert(uuid.v7()):gsub("%-", ""):sub(1, 12)
            local name = "lifecycle_" .. suffix
            local namespace = "app." .. name
            local application = namespace .. ":app"
            local node = assert(system.node.id())
            local workspace = "workspace-lifecycle-" .. suffix
            local ok_run, failure = pcall(function()
                local exact = assert(artifact.create({{id = application, kind = "process.lua",
                    meta = {type = "bee.app", application = {api_version = 1, title = "Lifecycle", lifetime = "view",
                        revision = "1", instance_policy = "singleton", menus = {"bee.shell:apps_menu"}}},
                    data = {source = "return {main = function() end}", method = "main"}}}))
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
                    expected_revision = approval.revision, proposal_digest = approval.proposal_digest, decision = "approved"})))
                test.is_true(decided.ok == true, tostring(decided.message))

                local settled: Object = intent
                for attempt = 1, 8 do
                    if settled.phase == "settled" then break end
                    settled = ok(call({operation = "step", workspace_id = workspace, intent_id = "intent-" .. suffix,
                        receipt_key = "step-" .. suffix .. "-" .. tostring(attempt)}))
                end
                test.eq(settled.phase, "settled")
                test.eq(settled.outcome, "applied")
                test.not_nil((registry.get(application)))

                local installed = principals.objects(ok(call({operation = "activations", workspace_id = workspace})).activations)
                test.eq(#installed, 1)
                test.eq(installed[1].application, application)

                local removed = ok(call({operation = "uninstall", workspace_id = workspace, source_workspace = name,
                    receipt_key = "remove-" .. suffix}))
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
            restore()
            if not ok_run then error(tostring(failure)) end
        end)
    end)
end

return test.run_cases(define_tests)
