-- MIT. Test-only host enrollment and calls through the real native Hive route.
local registry = require("registry")
local client = require("client")
local types = require("types")
local funcs = require("funcs")
local principals = require("principals")
local function object(value: unknown): {[string]: unknown}
    if type(value) ~= "table" then error("expected object") end
    return value :: {[string]: unknown}
end
local function handle(raw: unknown): string
    local input = object(raw)
    if type(input.command) ~= "string" or type(input.remote) ~= "string" then error("bad command") end
    local command, remote = input.command, input.remote
    if command:match("^approval%-") then
        local entry = registry.get("bee:approver_policies")
        if not entry then error("missing approval policies") end
        local approvers: {string} = {}
        if command ~= "approval-revoke" then
            local subject = command:match("^approval%-create (.+)$")
            if not subject or types.pid_parts(subject) ~= remote then error("bad approval subject") end
            approvers[1] = principals.actor_of(remote, subject)
        end
        entry.data = {policies = {{name = "feed-approval", approvers = approvers, max_ttl_ms = 60000}}}
        local changes = registry.snapshot():changes()
        changes:update(entry)
        local applied, apply_error = changes:apply()
        if not applied then error(tostring(apply_error)) end
        if command == "approval-revoke" then return "approval_revoked" end
        local created, create_error = funcs.new():call("bee.approvals.binding:request", {workspace_id = "feed-workspace", idempotency_key = "feed-approval-1",
            request_kind = "permission", policy = "feed-approval", proposal = {kind = "operation", ref = "bee.node.binding:update_metadata", revision = "1", payload = {display_name = "Approved name"}}, prompt = {text = "Approve this test request?"}})
        if create_error or object(created).ok ~= true then error("create approval: " .. tostring(create_error)) end
        return "approval_created"
    end
    if command == "revoke" or command:match("^enroll%-") then
        local entry = registry.get("bee.hive.supervisor:principal_mappings")
        if not entry then error("missing mappings") end
        local mappings: {{[string]: unknown}} = {}
        if command ~= "revoke" then
            local subject = command:match("^enroll%-[a-z]+ (.+)$")
            if not subject or types.pid_parts(subject) ~= remote then error("bad peer subject") end
            local policies = {"bee.feed_probe:read_policy"}
            if command:match("^enroll%-write ") then policies[#policies + 1] = "bee.feed_probe:write_policy" end
            mappings[1] = {issuer = remote, subject_id = subject, policies = policies}
        end
        entry.data = {mappings = mappings}
        local changes = registry.snapshot():changes()
        changes:update(entry)
        local ok, err = changes:apply()
        if not ok then error(tostring(err)) end
        return command == "revoke" and "revoked" or "enrolled"
    end
    local mesh, err = client.open()
    if not mesh then error(tostring(err)) end
    if command == "feed-approval" or command == "feed-approval-empty" then
        local owner: types.OwnerRef = {node_id = remote, service_id = "bee.approvals.binding"}
        local snapshot = mesh:call(owner, {operation_ref = "bee.approvals.binding:feed_snapshot"}, {workspace_id = "feed-workspace"}, {timeout = "5s"})
        if not snapshot.ok then error("approval snapshot transport refused") end
        local domain = object(snapshot.value)
        if domain.ok ~= true then error("approval snapshot owner refused") end
        local page = object(domain.value)
        local items = page.items
        if type(items) ~= "table" then error("missing approval items") end
        if command == "feed-approval-empty" then
            if #items ~= 0 then error("revoked approver retained a projection") end
            mesh:close()
            return "feed_approval_empty"
        end
        if #items ~= 1 or page.owner_id ~= remote then error("incorrect approval snapshot") end
        local request = object(object(items[1]).value)
        local decided = mesh:call(owner, {operation_ref = "bee.approvals.binding:decide"}, {approval_id = request.approval_id,
            expected_revision = request.revision, proposal_digest = request.proposal_digest, decision = "approved"}, {timeout = "5s"})
        if not decided.ok or object(decided.value).ok ~= true then error("remote decision failed") end
        local changed = mesh:call(owner, {operation_ref = "bee.approvals.binding:feed_read_after"}, {workspace_id = "feed-workspace",
            cursor = page.cursor, expected_scope_revision = page.scope_revision}, {timeout = "5s"})
        if not changed.ok or object(changed.value).ok ~= true then error("approval catch-up failed") end
        local events = object(object(changed.value).value).events
        if type(events) ~= "table" or #events ~= 1 then error("missing approval transition") end
        local committed = object(object(object(events[1]).payload).request)
        if committed.decision ~= "approved" or committed.revision ~= 2 then error("wrong approval transition") end
        mesh:close()
        return "feed_approval"
    end
    local operation = "bee.node.binding:describe"
    local request: {[string]: unknown} = {}
    if command == "feed-write" or command == "feed-replay" or command == "feed-write-denied" then
        operation = "bee.node.binding:update_metadata"
        request = {expected_revision = 0, idempotency_key = "remote-write-1", metadata = {display_name = "Remote owner", labels = {purpose = "acceptance"}}}
    elseif command == "feed-snapshot" then operation = "bee.node.binding:snapshot" end
    local reply = mesh:call({node_id = remote, service_id = "bee.node.binding"}, {operation_ref = operation}, request, {timeout = "5s"})
    mesh:close()
    if command == "feed-denied" then
        if reply.ok or not reply.error or reply.error.code ~= "DENIED" then error("unmapped principal was not denied") end
        return "feed_denied"
    end
    if not reply.ok then error("Hive: " .. tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    local result = object(reply.value)
    if command == "feed-write-denied" then
        if result.ok ~= false or result.code ~= "DENIED" then error("read-only principal changed metadata") end
        return "feed_write_denied"
    end
    if result.ok ~= true then error("owner: " .. tostring(result.code) .. ": " .. tostring(result.message)) end
    local value = object(result.value)
    if command == "feed-read" then
        if value.node_id ~= remote or value.revision ~= 0 then error("wrong owner description") end
        return "feed_read"
    elseif command == "feed-write" or command == "feed-replay" then
        if command == "feed-replay" and result.replayed ~= true then error("retry not replayed") end
        return command == "feed-replay" and "feed_replay" or "feed_write"
    elseif command == "feed-snapshot" then
        if value.owner_id ~= remote or value.cursor ~= 1 then error("wrong snapshot owner/cursor") end
        local items = value.items
        if type(items) ~= "table" or #items ~= 1 then error("wrong snapshot items") end
        local projection = object(items[1])
        if object(projection.value).display_name ~= "Remote owner" then error("metadata did not commit") end
        return "feed_snapshot"
    end
    error("unknown feed command")
end
return {handle = handle}
