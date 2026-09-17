-- MIT. Shared constants and calls for the inbox decide acceptance probe.
local system = require("system")
local hash = require("hash")
local canonical = require("canonical")
local artifact = require("artifact")
local plan_store = require("plan_store")
local staging = require("staging")
local approval = require("approval")

local M = {}
M.WORKSPACE = "0123456789abcdef0123456789abcdef"
M.SOURCE_NODE = "decide-source"
M.SOURCE_WORKSPACE = "decide-workspace"
M.VERSION = "v1"
M.POLICY = "inbox-decide"
M.PROMPT = "Apply demo decide version v1 to this workspace?"
M.EFFECT_KEY = "inbox-decide-effect"
M.RETRY_EFFECT_KEY = "inbox-decide-effect-retry"

type Object = {[string]: unknown}

function M.blob(bytes: string): {[string]: string}
    local digest, err = hash.sha256(bytes)
    if not digest then error(tostring(err)) end
    return {bytes = bytes, digest = digest}
end

function M.object(value: unknown, label: string): Object
    if type(value) ~= "table" then error(label) end
    return value :: Object
end

function M.open_plans(): plan_store.Store
    local node_id, node_error = system.node.id()
    if not node_id then error(tostring(node_error or "native node identity is unavailable")) end
    local resource, resource_error = staging.database()
    if not resource then error(tostring(resource_error or "governance database is not linked")) end
    local plans, open_error = plan_store.open(resource, node_id, M.WORKSPACE)
    if not plans then error(tostring(open_error)) end
    return plans
end

function M.selected_plan(plans: plan_store.Store): Object
    local entry = {id = "demo:decide", kind = "function.lua", data = {source = "return 'decided'"}}
    local exact = assert(artifact.create({entry}))
    local staged, stage_error = plan_store.call(plans, "host-decide", {operation = "stage", expected_revision = 0,
        idempotency_key = "inbox-decide-stage", source_node = M.SOURCE_NODE,
        source_workspace = M.SOURCE_WORKSPACE, version = M.VERSION,
        candidate = M.blob("candidate-decide-v1"), artifact = {bytes = exact.bytes, digest = exact.digest},
        preflight = M.blob("source-preflight-decide-v1")})
    if not staged.ok then error(tostring(staged.code) .. ": " .. tostring(staged.message)) end
    local staged_value = M.object(staged.value, "plan stage returned no plan")
    local reviewed, review_error = plan_store.call(plans, "host-decide", {operation = "record_review",
        expected_revision = staged_value.revision, idempotency_key = "inbox-decide-review",
        source_node = M.SOURCE_NODE, source_workspace = M.SOURCE_WORKSPACE, version = M.VERSION,
        review_status = "accepted", review_reason = "reviewed exact bytes"})
    if not reviewed.ok then error(tostring(reviewed.code) .. ": " .. tostring(reviewed.message)) end
    local reviewed_value = M.object(reviewed.value, "plan review returned no plan")
    local selected, select_error = plan_store.call(plans, "host-decide", {operation = "select",
        expected_revision = reviewed_value.revision, idempotency_key = "inbox-decide-select",
        source_node = M.SOURCE_NODE, source_workspace = M.SOURCE_WORKSPACE, version = M.VERSION})
    if not selected.ok then error(tostring(selected.code) .. ": " .. tostring(selected.message)) end
    return M.object(selected.value, "plan select returned no plan")
end

function M.close(plans: plan_store.Store)
    assert(plan_store.close(plans))
end

function M.get_selected(plans: plan_store.Store): Object
    local found, get_error = plan_store.call(plans, "host-decide", {operation = "get",
        source_node = M.SOURCE_NODE, source_workspace = M.SOURCE_WORKSPACE, version = M.VERSION})
    if get_error ~= nil then error("unexpected plan store error") end
    if not found.ok then error(tostring(found.code) .. ": " .. tostring(found.message)) end
    return M.object(found.value, "plan store returned no plan")
end

function M.proposal(plan: Object): (Object, string)
    local proposal, proposal_error = approval.proposal(plan)
    if not proposal then error(tostring(proposal_error)) end
    local bytes, encode_error = canonical.encode(proposal)
    if not bytes then error(tostring(encode_error or "cannot encode decision proposal")) end
    local digest, digest_error = hash.sha256(bytes)
    if not digest then error(tostring(digest_error)) end
    return proposal, digest
end

return M
