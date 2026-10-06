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
local resolution = require("resolution")

local M = {}
type Store = store.Store
type ReplicaStore = replicas.Store
type Executor = approval.Executor
type Object = {[string]: unknown}
type ReplicaIdentity = {source_owner: string, feed: string, version_key: string,
    descriptor_digest: string, idempotency_key: string}
type Resolver = resolution.Resolver

local function failure(code: string, message: string, value: unknown?): transaction.Result
    return transaction.failure(code, message, value)
end

local function identity(raw: unknown): (Object?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "plan identity must be an object" end
    local extra = bounds.fields(value, {"source_node", "source_workspace", "version"})
    if extra then return nil, extra end
    local source_node, source_workspace, version = bounds.id(value.source_node), bounds.id(value.source_workspace), bounds.id(value.version)
    if not source_node then return nil, "plan identity is invalid" end
    if not source_workspace then return nil, "plan identity is invalid" end
    if not version then return nil, "plan identity is invalid" end
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
    if not source_owner then return nil, "replica identity is invalid" end
    if not feed then return nil, "replica identity is invalid" end
    if not version_key then return nil, "replica identity is invalid" end
    if not idempotency_key then return nil, "replica identity is invalid" end
    if type(descriptor_digest) ~= "string" then return nil, "replica identity is invalid" end
    if #descriptor_digest ~= 64 then return nil, "replica identity is invalid" end
    if not descriptor_digest:match("^[0-9a-f]+$") then return nil, "replica identity is invalid" end
    return {source_owner = source_owner, feed = feed,
        version_key = version_key, descriptor_digest = descriptor_digest,
        idempotency_key = idempotency_key}, nil
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
    if not received then return failure("INTERNAL", "replica store returned invalid content") end
    if type(received.content) ~= "string" then return failure("INTERNAL", "replica store returned invalid content") end
    local descriptor = bounds.object(received.descriptor)
    if not descriptor then return failure("INTERNAL", "replica store returned invalid descriptor") end
    if type(descriptor.content_digest) ~= "string" then return failure("INTERNAL", "replica store returned invalid descriptor") end
    local application, decode_error = delivery.decode(received.content, descriptor.content_digest)
    if not application then return failure("INVALID", decode_error or "replica is not an application version") end
    local verified, descriptor_error = delivery.verify_descriptor(descriptor, application)
    if not verified then return failure("INVALID", descriptor_error or "replica descriptor does not match application version") end
    local component = bounds.text(component_raw, 160)
    if not component then return failure("DENIED", "application version does not match the destination application slot") end
    if component == "" then return failure("DENIED", "application version does not match the destination application slot") end
    if component ~= application.value.component then return failure("DENIED", "application version does not match the destination application slot") end
    if type(resolver) ~= "table" then return failure("UNAVAILABLE", "destination resolver is unavailable") end
    if type(resolver.resolve) ~= "function" then return failure("UNAVAILABLE", "destination resolver is unavailable") end
    local candidate, context, resolve_error = resolver:resolve({owner_node = target.node,
        workspace_id = target.workspace, source_node = application.value.source_node,
        source_workspace = application.value.source_workspace, version = application.value.version,
        artifact_bytes = application.value.artifact.bytes, artifact_digest = application.value.artifact.digest})
    if not candidate then return failure("BLOCKED", tostring(resolve_error or "resolve destination plan")) end
    if not context then return failure("BLOCKED", tostring(resolve_error or "resolve destination plan")) end
    local candidate_bytes, candidate_error = canonical.encode(candidate, 1048576)
    local candidate_digest = candidate_bytes and hash.sha256(candidate_bytes) or nil
    if not candidate_bytes then return failure("INTERNAL", tostring(candidate_error or "measure destination candidate")) end
    if not candidate_digest then return failure("INTERNAL", tostring(candidate_error or "measure destination candidate")) end
    local report, report_error = preflight.check(candidate, context)
    if not report then return failure("BLOCKED", tostring(report_error or "measure destination preflight")) end
    local report_bytes, report_digest, report_encode_error = preflight.encode_report(report)
    if not report_bytes then return failure("INTERNAL", tostring(report_encode_error or "encode destination preflight")) end
    if not report_digest then return failure("INTERNAL", tostring(report_encode_error or "encode destination preflight")) end
    return store.call(target, admitted_actor, {operation = "stage", expected_revision = 0,
        idempotency_key = input.idempotency_key, source_node = application.value.source_node,
        source_workspace = application.value.source_workspace, version = application.value.version,
        candidate = {bytes = candidate_bytes, digest = candidate_digest},
        artifact = application.value.artifact,
        preflight = {bytes = report_bytes, digest = report_digest}})
end

return M
