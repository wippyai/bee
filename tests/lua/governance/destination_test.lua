-- MIT. Destination coordination asks local Approvals only after review and selection.
local test = require("test")
local destination = require("destination")
local store = require("plan_store")
local canonical = require("canonical")
local hash = require("hash")
local base64 = require("base64")
local replicas = require("replicas")
local delivery = require("delivery")
local artifact = require("artifact")
local preflight = require("preflight")
local version = require("version")

local function blob(bytes: string): {[string]: string}
    local digest, err = hash.sha256(bytes)
    if not digest then error(tostring(err)) end
    return {bytes = bytes, digest = digest}
end

local function executor(): destination.Executor
    local selected = {}
    function selected:call(method: string, raw: unknown): (unknown?, unknown?)
        if method ~= "bee.approvals:request" then return nil, "unexpected method" end
        local request = raw :: {[string]: unknown}
        local proposal = request.proposal
        local bytes = assert(canonical.encode(proposal))
        return {ok = true, replayed = false, value = {approval_id = "approval-destination",
            proposal = proposal, proposal_digest = assert(hash.sha256(bytes)), owner_incarnation = 4}}, nil
    end
    return selected :: destination.Executor
end

local function ok(result: {[string]: unknown}): {[string]: unknown}
    if result.ok ~= true then error(tostring(result.code) .. ": " .. tostring(result.message)) end
    return result.value :: {[string]: unknown}
end

local function application(source_node: string, source_workspace: string, component: string): delivery.Delivery
    local exact = assert(artifact.create({{id = "replicated.app:main", kind = "function.lua",
        data = {source = "--" .. string.rep("x", 40000) .. "\nreturn true"}}}))
    local result, result_error = delivery.create({schema_revision = delivery.SCHEMA,
        source_node = source_node, source_workspace = source_workspace,
        component = component, version = "v1", artifact = {bytes = exact.bytes, digest = exact.digest}})
    if not result then error(tostring(result_error)) end
    return result
end

local function resolver(): destination.Resolver
    local value = {}
    function value:resolve(raw: unknown): (preflight.Candidate?, preflight.Context?, string?)
        local spec = raw :: {[string]: unknown}
        test.eq(spec.owner_node, "node-d")
        test.eq(spec.workspace_id, "workspace-d")
        test.eq(spec.source_workspace, "source/application")
        test.eq(spec.version, "v1")
        test.is_true(type(spec.source_node) == "string" and #spec.source_node > 0)
        test.is_true(type(spec.artifact_bytes) == "string" and #spec.artifact_bytes > 0)
        test.is_true(type(spec.artifact_digest) == "string" and #spec.artifact_digest == 64)
        local digest = spec.artifact_digest :: string
        local candidate: preflight.Candidate = {destination_node = "node-d", source_node = spec.source_node :: string,
            base_revision = 1, base_digest = string.rep("a", 64),
            artifacts = {{component = "sample/app", version = "v1", digest = digest,
                dependencies = {}, namespaces = {"sample"}}},
            entries = {}, requirements = {}, migrations = {}}
        local context: preflight.Context = {node_id = "node-d", registry_revision = 1,
            registry_digest = string.rep("a", 64), policy_digest = string.rep("b", 64),
            packages = {["sample/app"] = true}, namespaces = {sample = true},
            kinds = {}, databases = {}, grants = {}, modules = {}, entries = {}, installed_entries = nil, applied = {},
            exact_expansion = true, migration_barrier = false}
        return candidate, context, nil
    end
    return value :: destination.Resolver
end

local function replicate(target: replicas.Store, item: delivery.Delivery): version.Descriptor
    local descriptor, descriptor_error = delivery.descriptor(item)
    if not descriptor then error(tostring(descriptor_error)) end
    test.is_true(replicas.begin(target, descriptor, 1).ok)
    local offset = 0
    while offset < #item.bytes do
        local last = math.min(#item.bytes, offset + (replicas.MAX_CHUNK_BYTES :: integer))
        local encoded = assert(base64.encode(item.bytes:sub(offset + 1, last)))
        test.is_true(replicas.put(target, {source_owner = descriptor.owner_id, feed = descriptor.feed,
            version_key = descriptor.key, descriptor_digest = descriptor.digest}, offset, encoded).ok)
        offset = last
    end
    test.is_true(replicas.finish(target, {source_owner = descriptor.owner_id, feed = descriptor.feed,
        version_key = descriptor.key, descriptor_digest = descriptor.digest}).ok)
    return descriptor
end

local function define_tests()
    test.describe("Governance destination owner", function()
        test.it("binds a selected reviewed plan to an exact local approval", function()
            local target, open_error = store.open("bee.governance:destination_test_db", "node-d", "workspace-d")
            if not target then error(tostring(open_error)) end
            local stage = {operation = "stage", source_node = "node-s", source_workspace = "application-s", version = "v1",
                expected_revision = 0, idempotency_key = "stage-d", candidate = blob("candidate-d"),
                artifact = blob("artifact-d"), preflight = blob("preflight-d")}
            ok(store.call(target, "local-user", stage))
            ok(store.call(target, "local-user", {operation = "record_review", source_node = "node-s",
                source_workspace = "application-s", version = "v1", expected_revision = 1,
                idempotency_key = "review-d", review_status = "accepted", review_reason = "reviewed"}))
            ok(store.call(target, "local-user", {operation = "select", source_node = "node-s",
                source_workspace = "application-s", version = "v1", expected_revision = 2,
                idempotency_key = "select-d"}))
            local bound = ok(destination.request_approval(target, "local-user", executor(),
                {source_node = "node-s", source_workspace = "application-s", version = "v1"},
                "user-approval", "approval-request-d", "approval-bind-d"))
            test.eq(bound.status, "approval_bound")
            test.eq(bound.approval_owner_incarnation, 4)
            test.eq(bound.approval_plan_digest, bound.plan_digest)
            assert(store.close(target))
        end)

        test.it("does not request approval before local selection", function()
            local target, open_error = store.open("bee.governance:destination_refusal_test_db", "node-d", "workspace-d")
            if not target then error(tostring(open_error)) end
            ok(store.call(target, "local-user", {operation = "stage", source_node = "node-s",
                source_workspace = "application-s", version = "v1", expected_revision = 0,
                idempotency_key = "stage-r", candidate = blob("candidate-r"), artifact = blob("artifact-r"), preflight = blob("preflight-r")}))
            local refused = destination.request_approval(target, "local-user", executor(),
                {source_node = "node-s", source_workspace = "application-s", version = "v1"},
                "user-approval", "approval-request-r", "approval-bind-r")
            test.is_false(refused.ok == true)
            assert(store.close(target))
        end)

        test.it("stages only verified destination replicas and preserves local authority", function()
            local plans, plan_error = store.open("bee.governance:destination_replica_test_db", "node-d", "workspace-d")
            if not plans then error(tostring(plan_error)) end
            local replica_store, replica_error = replicas.open("bee.sync:sync_test_db")
            if not replica_store then error(tostring(replica_error)) end
            local item = application("source-node", "source/application", "sample/app")
            local descriptor = replicate(replica_store, item)
            local request = {source_owner = descriptor.owner_id, feed = descriptor.feed,
                version_key = descriptor.key, descriptor_digest = descriptor.digest,
                idempotency_key = "stage-replica-1"}
            local staged = ok(destination.stage_replica(plans, replica_store, "local-reviewer", request,
                resolver(), "sample/app"))
            test.eq(staged.status, "staged")
            test.is_false(staged.selected == true)
            test.is_nil(staged.approval_id)
            assert(store.close(plans))
            assert(replicas.close(replica_store))

            local reopened_plans, reopened_plan_error = store.open("bee.governance:destination_replica_test_db", "node-d", "workspace-d")
            if not reopened_plans then error(tostring(reopened_plan_error)) end
            local reopened_replicas, reopened_replica_error = replicas.open("bee.sync:sync_test_db")
            if not reopened_replicas then error(tostring(reopened_replica_error)) end
            local replay = destination.stage_replica(reopened_plans, reopened_replicas, "local-reviewer", request,
                resolver(), "sample/app")
            test.is_true(replay.ok == true and replay.replayed == true)

            local other_source = application("another-node", "source/application", "sample/app")
            local other_descriptor = replicate(reopened_replicas, other_source)
            local from_other_source = ok(destination.stage_replica(reopened_plans, reopened_replicas, "local-reviewer",
                {source_owner = other_descriptor.owner_id, feed = other_descriptor.feed,
                    version_key = other_descriptor.key, descriptor_digest = other_descriptor.digest,
                    idempotency_key = "stage-other-source"}, resolver(), "sample/app"))
            test.eq(from_other_source.status, "staged")

            local wrong_slot = destination.stage_replica(reopened_plans, reopened_replicas, "local-reviewer",
                request, resolver(), "other/app")
            test.eq(wrong_slot.code, "DENIED")
            assert(store.close(reopened_plans))
            assert(replicas.close(reopened_replicas))
        end)
    end)
end

return test.run_cases(define_tests)
