local bounds = require("bounds")
-- MIT. Seed the inbox lease smoke: two pending requests of one requester for
-- the batch, one pending activation request to lease, and one active lease
-- with a recorded use so the leases view shows usage and can revoke it.
local funcs = require("funcs")
local system = require("system")
local process = require("process")
local time = require("time")
local logger = require("logger")
local staging = require("staging")
local lease_store = require("lease_store")

local WORKSPACE = "0123456789abcdef0123456789abcdef"
local POLICY = "inbox-leases"

type Object = {[string]: unknown}

local function call(target: string, request: unknown): Object
    local raw, err = funcs.new():call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    local reply = assert(bounds.object(raw))
    if reply.ok ~= true then
        local fault = assert(bounds.object(reply.error))
        error(target .. ": " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return assert(bounds.object(reply.value))
end

local function request(key: string, ref: string, payload: Object, prompt: string)
    call("bee.approvals.binding:request", {workspace_id = WORKSPACE, idempotency_key = key,
        request_kind = "permission", policy = POLICY,
        proposal = {kind = "operation", ref = ref, revision = "r1", payload = payload}, prompt = {text = prompt}})
end

-- The approval authority registers its name after it establishes its
-- incarnation; a command that starts alongside the services waits for it.
local function await_authority()
    for _ = 1, 250 do
        local pid = process.registry.lookup("bee.approvals.authority")
        if pid then return end
        time.sleep("20ms")
    end
    error("approval authority did not start")
end

local function main()
    await_authority()
    request("batch-a", "bee.smoke:first", {operation = "first"}, "First batched request")
    request("batch-b", "bee.smoke:second", {operation = "second"}, "Second batched request")
    request("activation", "bee.gov:establish-overlay", {operation = "establish", workspace_id = WORKSPACE,
        source_node = "smoke-source", source_workspace = "smoke-notes"}, "Apply smoke-notes version v1")
    local node_id = assert(system.node.id())
    local resource = assert(staging.database())
    local leases = assert(lease_store.open(resource, node_id, WORKSPACE))
    local grant: Object = {capability = "workspace.files.write", template_revision = 1, operation = "files.write",
        resource = "workspace", scope = {subpath = "docs"}, parameters = {subpath = "docs"}}
    local granted = lease_store.call(leases, "smoke-seed", {operation = "grant", idempotency_key = "smoke-lease",
        lease_id = "smoke-lease-1", target = "bee.gov:smoke-notes", envelope = {grant},
        source_approval_id = "smoke-approval", source_approval_proposal_digest = string.rep("a", 64),
        source_approval_owner_incarnation = 1, granted_by = "smoke-person", ttl_seconds = 3600, max_applies = 5})
    if not granted.ok then error("seed lease: " .. tostring(granted.message)) end
    local used = lease_store.call(leases, "smoke-seed", {operation = "use", idempotency_key = "smoke-use",
        lease_id = "smoke-lease-1", expected_revision = 1, intent_id = "smoke-intent", proposal_capabilities = {grant}})
    if not used.ok then error("seed lease use: " .. tostring(used.message)) end
    lease_store.close(leases)
    logger:info("INBOX_LEASES_SEEDED")
end

local function guarded()
    local ok, failure = pcall(main)
    if not ok then
        logger:error("INBOX_LEASES_SEED_FAILED", {error = tostring(failure)})
        error(failure)
    end
end

return {main = guarded}
