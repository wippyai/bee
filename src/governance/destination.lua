-- MIT. Destination-owned governance coordination. This module joins the
-- durable plan store to the local Approvals owner; it has no remote call,
-- decision, registry or overlay capability.
local bounds = require("bounds")
local approval = require("approval")
local store = require("plan_store")
local replicas = require("replicas")
local delivery = require("delivery")
local canonical = require("canonical")
local hash = require("hash")
local preflight = require("preflight")
local transaction = require("transaction")

local M = {}
type Store = store.Store
type ReplicaStore = replicas.Store
type Executor = approval.Executor
type Object = {[string]: unknown}
type ReplicaIdentity = {source_owner: string, feed: string, version_key: string,
    descriptor_digest: string, idempotency_key: string}
type Resolver = {resolve: (Resolver, unknown) -> (preflight.Candidate?, preflight.Context?, string?)}

local function failure(code: string, message: string, value: unknown?): transaction.Result
    return transaction.failure(code, message, value)
end

local function identity(raw: unknown): (Object?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "plan identity must be an object" end
    local extra = bounds.fields(value, {"source_node", "source_workspace", "version"})
    if extra then return nil, extra end
    local source_node, source_workspace, version = bounds.id(value.source_node), bounds.id(value.source_workspace), bounds.id(value.version)
    if not source_node or not source_workspace or not version then return nil, "plan identity is invalid" end
    return {operation = "get", source_node = source_node, source_workspace = source_workspace, version = version}, nil
end

local function replica_identity(raw: unknown): (ReplicaIdentity?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "replica identity must be an object" end
    local extra = bounds.fields(value, {"source_owner", "feed", "version_key", "descriptor_digest", "idempotency_key"})
    if extra then return nil, extra end
    local source_owner, feed = bounds.id(value.source_owner), bounds.id(value.feed)
    local version_key, idempotency_key = bounds.id(value.version_key), bounds.id(value.idempotency_key)
    local descriptor_digest = value.descriptor_digest
    if not source_owner or not feed or not version_key or not idempotency_key
        or type(descriptor_digest) ~= "string" or #descriptor_digest ~= 64
        or not descriptor_digest:match("^[0-9a-f]+$") then
        return nil, "replica identity is invalid"
    end
    return {source_owner = source_owner :: string, feed = feed :: string,
        version_key = version_key :: string, descriptor_digest = descriptor_digest :: string,
        idempotency_key = idempotency_key :: string}, nil
end

-- A caller names only a locally replicated immutable version. The destination
-- derives all plan bytes and identities from that verified replica; it cannot
-- smuggle different candidate or artifact bytes into local review.
function M.stage_replica(target: Store, replica_store: ReplicaStore, actor: unknown, raw: unknown,
    resolver: Resolver, component_raw: unknown): transaction.Result
    local admitted_actor = bounds.id(actor)
    if not admitted_actor then return failure("INVALID", "plan actor is invalid") end
    local input, input_error = replica_identity(raw)
    if not input then return failure("INVALID", input_error or "invalid replica identity") end
    local replicated = replicas.read(replica_store, input)
    if not replicated.ok then return replicated end
    local received = bounds.object(replicated.value)
    if not received or type(received.content) ~= "string" then return failure("INTERNAL", "replica store returned invalid content") end
    local descriptor = bounds.object(received.descriptor)
    if not descriptor or type(descriptor.content_digest) ~= "string" then return failure("INTERNAL", "replica store returned invalid descriptor") end
    local application, decode_error = delivery.decode(received.content, descriptor.content_digest)
    if not application then return failure("INVALID", decode_error or "replica is not an application version") end
    local verified, descriptor_error = delivery.verify_descriptor(descriptor, application)
    if not verified then return failure("INVALID", descriptor_error or "replica descriptor does not match application version") end
    local component = bounds.text(component_raw, 160)
    if not component or component == "" or component ~= application.value.component then
        return failure("DENIED", "application version does not match the destination application slot")
    end
    if type(resolver) ~= "table" or type(resolver.resolve) ~= "function" then
        return failure("UNAVAILABLE", "destination resolver is unavailable")
    end
    local candidate, context, resolve_error = resolver:resolve({owner_node = target.node,
        workspace_id = target.workspace, source_node = application.value.source_node,
        source_workspace = application.value.source_workspace, version = application.value.version,
        artifact_bytes = application.value.artifact.bytes, artifact_digest = application.value.artifact.digest})
    if not candidate or not context then return failure("BLOCKED", tostring(resolve_error or "resolve destination plan")) end
    local candidate_bytes, candidate_error = canonical.encode(candidate, 1048576)
    local candidate_digest = candidate_bytes and hash.sha256(candidate_bytes) or nil
    if not candidate_bytes or not candidate_digest then return failure("INTERNAL", tostring(candidate_error or "measure destination candidate")) end
    local report, report_error = preflight.check(candidate, context)
    if not report then return failure("BLOCKED", tostring(report_error or "measure destination preflight")) end
    local report_bytes, report_digest, report_encode_error = preflight.encode_report(report)
    if not report_bytes or not report_digest then return failure("INTERNAL", tostring(report_encode_error or "encode destination preflight")) end
    return store.call(target, admitted_actor, {operation = "stage", expected_revision = 0,
        idempotency_key = input.idempotency_key, source_node = application.value.source_node,
        source_workspace = application.value.source_workspace, version = application.value.version,
        candidate = {bytes = candidate_bytes, digest = candidate_digest},
        artifact = application.value.artifact,
        preflight = {bytes = report_bytes, digest = report_digest}})
end

function M.request_approval(target: Store, actor_raw: unknown, executor: Executor, identity_raw: unknown,
    policy_raw: unknown, request_key_raw: unknown, bind_key_raw: unknown): transaction.Result
    local actor, policy = bounds.id(actor_raw), bounds.id(policy_raw)
    local request_key, bind_key = bounds.id(request_key_raw), bounds.id(bind_key_raw)
    local selected, identity_error = identity(identity_raw)
    if not actor or not policy or not request_key or not bind_key or not selected then
        return failure("INVALID", identity_error or "approval request identity is invalid")
    end
    local found = store.call(target, actor, selected)
    if not found.ok then return found end
    local plan = bounds.object(found.value)
    if not plan then return failure("INTERNAL", "plan store returned no plan") end
    if plan.selected ~= true or plan.status ~= "reviewed" or plan.review_status ~= "accepted" then
        return failure("CONFLICT", "plan must be selected after an accepted review")
    end
    local bound, approval_error = approval.request(executor, plan, policy, request_key)
    if not bound then return failure("APPROVAL", approval_error or "request local approval") end
    local request: Object = {operation = "bind_approval", source_node = plan.source_node,
        source_workspace = plan.source_workspace, version = plan.version,
        expected_revision = plan.revision, idempotency_key = bind_key,
        approval_id = bound.approval_id, approval_plan_digest = bound.approval_plan_digest,
        approval_proposal_digest = bound.approval_proposal_digest,
        approval_owner_incarnation = bound.owner_incarnation}
    return store.call(target, actor, request)
end

return M
