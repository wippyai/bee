-- MIT. Pure, bounded protocol decoder for destination-owned governance plans.
-- Node and workspace are deliberately absent: the opened store supplies them.
local bounds = require("bounds")
local M = {}

M.MAX_VERSION_BYTES = 160
M.MAX_SOURCE_BYTES = 160
M.MAX_CANDIDATE_BYTES = 1048576
M.MAX_ARTIFACT_BYTES = 262144
M.MAX_PREFLIGHT_BYTES = 131072
M.MAX_REVIEW_BYTES = 8192
M.MAX_APPROVAL_BYTES = 160
M.MAX_RECEIPT_BYTES = 160

type Blob = {bytes: string, digest: string}
type Request = {
    operation: "stage" | "get" | "list" | "record_review" | "select" | "bind_approval",
    version: string?, source_node: string?, source_workspace: string?,
    candidate: Blob?, artifact: Blob?, preflight: Blob?,
    expected_revision: integer?, idempotency_key: string?,
    review_status: "accepted" | "rejected"?, review_reason: string?,
    approval_id: string?, approval_plan_digest: string?, approval_proposal_digest: string?, approval_owner_incarnation: integer?
}

local function object(value: unknown): {[string]: unknown}?
    return bounds.object(value)
end

local function fields(value: {[string]: unknown}, allowed: {string}): string?
    return bounds.fields(value, allowed)
end

local function digest(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end

local function blob(value: unknown, limit: integer, label: string): (Blob?, string?)
    local item = object(value)
    if not item then return nil, label .. " must be an object" end
    local extra = fields(item, {"bytes", "digest"})
    if extra then return nil, label .. ": " .. extra end
    if type(item.bytes) ~= "string" or #item.bytes == 0 or #item.bytes > limit then
        return nil, label .. ".bytes exceeds its bound"
    end
    local measured = digest(item.digest)
    if not measured then return nil, label .. ".digest must be a lowercase SHA-256 digest" end
    local result: Blob = {bytes = item.bytes :: string, digest = measured}
    return result, nil
end

local function mutation_fields(value: {[string]: unknown}, extra: {string}): string?
    local allowed = {"operation", "version", "expected_revision", "idempotency_key"}
    for _, name in ipairs(extra) do allowed[#allowed + 1] = name end
    return fields(value, allowed)
end

function M.decode(raw: unknown): (Request?, string?)
    local value = object(raw)
    if not value then return nil, "governance plan request must be an object" end
    local operation = value.operation
    if operation ~= "stage" and operation ~= "get" and operation ~= "list"
        and operation ~= "record_review" and operation ~= "select" and operation ~= "bind_approval" then
        return nil, "unsupported governance plan operation"
    end

    if operation == "list" then
        local extra = fields(value, {"operation"})
        if extra then return nil, extra end
        local result: Request = {operation = "list"}
        return result, nil
    end

    local version = bounds.id(value.version)
    if not version or #version > M.MAX_VERSION_BYTES then return nil, "version is not a bounded identifier" end
    if operation == "get" then
        local extra = fields(value, {"operation", "version", "source_node", "source_workspace"})
        if extra then return nil, extra end
        local source_node, source_workspace = bounds.id(value.source_node), bounds.id(value.source_workspace)
        if not source_node or not source_workspace then return nil, "source identity is required" end
        local result: Request = {operation = "get", version = version, source_node = source_node, source_workspace = source_workspace}
        return result, nil
    end

    local expected = bounds.count(value.expected_revision)
    local key = bounds.id(value.idempotency_key)
    if not expected or not key or #key > M.MAX_RECEIPT_BYTES then
        return nil, "expected_revision and idempotency_key are required"
    end
    if operation == "stage" and expected ~= 0 then return nil, "stage requires expected_revision zero" end

    if operation == "stage" then
        local extra = mutation_fields(value, {"source_node", "source_workspace", "candidate", "artifact", "preflight"})
        if extra then return nil, extra end
        local source_node, source_workspace = bounds.id(value.source_node), bounds.id(value.source_workspace)
        if not source_node or not source_workspace then return nil, "source identity is invalid" end
        local candidate, candidate_error = blob(value.candidate, M.MAX_CANDIDATE_BYTES, "candidate")
        if not candidate then return nil, candidate_error end
        local artifact, artifact_error = blob(value.artifact, M.MAX_ARTIFACT_BYTES, "artifact")
        if not artifact then return nil, artifact_error end
        local preflight, preflight_error = blob(value.preflight, M.MAX_PREFLIGHT_BYTES, "preflight")
        if not preflight then return nil, preflight_error end
        local result: Request = {operation = "stage", version = version, expected_revision = expected, idempotency_key = key,
            source_node = source_node, source_workspace = source_workspace, candidate = candidate,
            artifact = artifact, preflight = preflight}
        return result
    end

    if operation == "record_review" then
        local extra = mutation_fields(value, {"source_node", "source_workspace", "review_status", "review_reason"})
        if extra then return nil, extra end
        local source_node, source_workspace = bounds.id(value.source_node), bounds.id(value.source_workspace)
        if not source_node or not source_workspace then return nil, "source identity is required" end
        local status = bounds.member(value.review_status, {"accepted", "rejected"})
        local reason_raw = value.review_reason
        local reason = ""
        if reason_raw ~= nil then
            reason = bounds.text(reason_raw, M.MAX_REVIEW_BYTES) or ""
            if reason == "" and reason_raw ~= "" then return nil, "review reason exceeds its bound" end
        end
        if not status then return nil, "review_status must be accepted or rejected" end
        local review_status: "accepted" | "rejected" = "rejected"
        if status == "accepted" then review_status = "accepted" end
        local result: Request = {operation = "record_review", version = version, expected_revision = expected,
            idempotency_key = key, source_node = source_node, source_workspace = source_workspace,
            review_status = review_status, review_reason = reason}
        return result
    end

    if operation == "bind_approval" then
        local extra = mutation_fields(value, {"source_node", "source_workspace", "approval_id", "approval_plan_digest", "approval_proposal_digest", "approval_owner_incarnation"})
        if extra then return nil, extra end
        local source_node, source_workspace = bounds.id(value.source_node), bounds.id(value.source_workspace)
        if not source_node or not source_workspace then return nil, "source identity is required" end
        local approval_id = bounds.id(value.approval_id)
        if not approval_id or #approval_id > M.MAX_APPROVAL_BYTES then return nil, "approval_id is invalid" end
        local approval_plan_digest = digest(value.approval_plan_digest)
        if not approval_plan_digest then return nil, "approval_plan_digest must be a lowercase SHA-256 digest" end
        local approval_proposal_digest = digest(value.approval_proposal_digest)
        if not approval_proposal_digest then return nil, "approval_proposal_digest must be a lowercase SHA-256 digest" end
        local approval_owner_incarnation = bounds.count(value.approval_owner_incarnation)
        if not approval_owner_incarnation or approval_owner_incarnation < 1 then return nil, "approval_owner_incarnation must be positive" end
        local result: Request = {operation = "bind_approval", version = version, expected_revision = expected,
            idempotency_key = key, source_node = source_node, source_workspace = source_workspace,
            approval_id = approval_id, approval_plan_digest = approval_plan_digest,
            approval_proposal_digest = approval_proposal_digest,
            approval_owner_incarnation = approval_owner_incarnation}
        return result
    end

    local extra = mutation_fields(value, {"source_node", "source_workspace"})
    if extra then return nil, extra end
    local source_node, source_workspace = bounds.id(value.source_node), bounds.id(value.source_workspace)
    if not source_node or not source_workspace then return nil, "source identity is required" end
    local result: Request = {operation = "select", version = version, expected_revision = expected, idempotency_key = key, source_node = source_node, source_workspace = source_workspace}
    return result, nil
end

return M
