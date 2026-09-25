-- MIT. Runtime capability elevation: an agent asks for one catalog
-- capability with bounded parameters and a TTL; the request is measured
-- against the host catalog, worded for approval in the catalog's own text,
-- and bound to the thread and attempt that asked. Consumption writes one
-- resources grant row for the authenticated thread actor; a different
-- attempt, including any child, cannot consume or inherit it.
local test = require("test")
local capability = require("capability")
local bounds = require("bounds")

local function fixture(): {[string]: unknown}
    return {id = "bee:capability_catalog", kind = "registry.entry",
        meta = {type = "bee.capability_catalog"}, data = {revision = 1,
            never = {"exec"}, capabilities = {
                {id = "workspace.files.read", revision = 2, confirm = "standard",
                    parameters = {subpath = "relative_subpath"},
                    text = "Read workspace files under {subpath}",
                    policies = {{operation = "files.read", resource = "workspace", scope = {subpath = "$subpath"}}},
                    resources = {}},
                {id = "app.database", revision = 1, confirm = "standard",
                    parameters = {name = "name"},
                    text = "Use an isolated application database named {name}",
                    policies = {{operation = "database.use", resource = "$name", scope = {name = "$name"}}},
                    resources = {{kind = "db.sql.sqlite", mode = "dedicated", source = "$name"}}},
            }}}
end

local CONTEXT = {thread_id = "thread-1", attempt_id = "attempt-1", action_id = "action-1"}

local function define_tests()
    test.describe("Capability elevation", function()
        test.it("decodes a bounded request and defaults the TTL", function()
            local decoded = fixture()
            local request = assert(capability.request(decoded, CONTEXT,
                {capability = "workspace.files.read", parameters = {subpath = "docs"}, idempotency_key = "req-1"}))
            test.eq(request.capability, "workspace.files.read")
            test.eq(request.template_revision, 2)
            test.eq(request.ttl_ms, capability.DEFAULT_TTL_MS)
            test.eq((request.parameters :: {[string]: unknown}).subpath, "docs")
            test.eq(#request.parameters_digest, 64)
        end)
        test.it("refuses unknown, never-listed and malformed requests", function()
            local decoded = fixture()
            local _, unknown = capability.request(decoded, CONTEXT,
                {capability = "nope", parameters = {}, idempotency_key = "req-1"})
            test.eq(unknown, "unknown capability or malformed parameters")
            local _, never = capability.request(decoded, CONTEXT,
                {capability = "exec", parameters = {}, idempotency_key = "req-1"})
            test.eq(never, "unknown capability or malformed parameters")
            local _, traversal = capability.request(decoded, CONTEXT,
                {capability = "workspace.files.read", parameters = {subpath = "../x"}, idempotency_key = "req-1"})
            test.eq(traversal, "unknown capability or malformed parameters")
            local _, ttl_zero = capability.request(decoded, CONTEXT,
                {capability = "workspace.files.read", parameters = {subpath = "docs"}, ttl_ms = 0, idempotency_key = "req-1"})
            test.eq(ttl_zero, "ttl_ms must be between 1 and " .. tostring(capability.MAX_TTL_MS))
            local _, ttl_big = capability.request(decoded, CONTEXT,
                {capability = "workspace.files.read", parameters = {subpath = "docs"}, ttl_ms = capability.MAX_TTL_MS + 1, idempotency_key = "req-1"})
            test.eq(ttl_big, "ttl_ms must be between 1 and " .. tostring(capability.MAX_TTL_MS))
            local _, no_key = capability.request(decoded, CONTEXT,
                {capability = "workspace.files.read", parameters = {subpath = "docs"}})
            test.eq(no_key, "idempotency_key is required")
        end)
        test.it("words the approval in the catalog's own text", function()
            local decoded = fixture()
            local request = assert(capability.request(decoded, CONTEXT,
                {capability = "workspace.files.read", parameters = {subpath = "docs"}, idempotency_key = "req-1"}))
            local wording = capability.wording(request)
            test.is_true(wording:find("Read workspace files under docs", 1, true) ~= nil)
            test.is_true(wording:find("attempt-1", 1, true) ~= nil)
            test.is_true(wording:find("thread-1", 1, true) ~= nil)
        end)
        test.it("binds the approval proposal to thread, attempt and measured parameters", function()
            local decoded = fixture()
            local request = assert(capability.request(decoded, CONTEXT,
                {capability = "workspace.files.read", parameters = {subpath = "docs"}, idempotency_key = "req-1"}))
            local proposal = capability.proposal(request)
            test.eq(proposal.kind, "capability")
            test.eq(proposal.ref, "attempt-1")
            local payload = bounds.object(proposal.payload)
            if not payload then error("proposal payload") end
            test.eq(payload.thread_id, "thread-1")
            test.eq(payload.capability, "workspace.files.read")
            test.eq(payload.template_revision, 2)
            test.eq(payload.parameters_digest, request.parameters_digest)
            test.eq(#tostring(payload.proposal_digest), 64)
            local other_thread = assert(capability.request(decoded,
                {thread_id = "thread-2", attempt_id = "attempt-1", action_id = "action-1"},
                {capability = "workspace.files.read", parameters = {subpath = "docs"}, idempotency_key = "req-1"}))
            local other_payload = bounds.object(capability.proposal(other_thread).payload)
            if not other_payload then error("other proposal payload") end
            test.neq(other_payload.proposal_digest, payload.proposal_digest)
        end)
        test.it("scopes idempotency keys to thread, attempt and measured request", function()
            local decoded = fixture()
            local request = assert(capability.request(decoded, CONTEXT,
                {capability = "workspace.files.read", parameters = {subpath = "docs"}, idempotency_key = "req-1"}))
            local same = assert(capability.request(decoded, CONTEXT,
                {capability = "workspace.files.read", parameters = {subpath = "docs"}, idempotency_key = "req-1"}))
            test.eq(capability.request_key(same), capability.request_key(request))
            test.eq(capability.effect_key(same), capability.effect_key(request))
            local child = assert(capability.request(decoded,
                {thread_id = "thread-1", attempt_id = "attempt-2", action_id = "action-9"},
                {capability = "workspace.files.read", parameters = {subpath = "docs"}, idempotency_key = "req-1"}))
            test.neq(capability.request_key(child), capability.request_key(request))
            test.neq(capability.effect_key(child), capability.effect_key(request))
        end)
        test.it("encodes a thread-actor grant write only for resource-backed capabilities", function()
            local decoded = fixture()
            local files = assert(capability.request(decoded, CONTEXT,
                {capability = "workspace.files.read", parameters = {subpath = "docs"}, idempotency_key = "req-1"}))
            local _, no_grant = capability.grant_write(files, "ws-1", "thread-actor-1")
            test.eq(no_grant, "capability names no workspace resource grant")
            local database = assert(capability.request(decoded, CONTEXT,
                {capability = "app.database", parameters = {name = "journal"}, ttl_ms = 60000, idempotency_key = "req-2"}))
            local write = assert(capability.grant_write(database, "ws-1", "thread-actor-1"))
            test.eq(write.subject, "thread-actor-1")
            test.eq(write.thread_id, "thread-1")
            test.eq(write.attempt_id, "attempt-1")
            test.eq(write.workspace_id, "ws-1")
            test.eq(write.name, "journal")
            test.eq(write.ttl_ms, 60000)
            test.eq(write.purpose, "session")
            test.eq(write.audience, "thread-actor-1")
        end)
        test.it("refuses consumption across attempts and for a changed approval", function()
            local decoded = fixture()
            local request = assert(capability.request(decoded, CONTEXT,
                {capability = "workspace.files.read", parameters = {subpath = "docs"}, idempotency_key = "req-1"}))
            local proposal = capability.proposal(request)
            local payload = bounds.object(proposal.payload)
            if not payload then error("proposal payload") end
            local digest = payload.proposal_digest :: string
            local approval = {approval_id = "approval-1", proposal_digest = digest, thread_id = "thread-1",
                attempt_id = "attempt-1", capability = "workspace.files.read", template_revision = 2,
                parameters_digest = request.parameters_digest}
            local ok, ok_error = capability.check_consumption(request, approval)
            test.is_nil(ok_error)
            test.eq(ok, true)
            local _, moved = capability.check_consumption(request, {approval_id = "approval-1", proposal_digest = digest,
                thread_id = "thread-1", attempt_id = "attempt-2", capability = "workspace.files.read",
                template_revision = 2, parameters_digest = request.parameters_digest})
            test.eq(moved, "approval does not belong to this thread and attempt")
            local _, changed = capability.check_consumption(request, {approval_id = "approval-1", proposal_digest = digest,
                thread_id = "thread-1", attempt_id = "attempt-1", capability = "workspace.files.read",
                template_revision = 3, parameters_digest = request.parameters_digest})
            test.eq(changed, "approval proposal differs from the requested capability")
            local _, tampered = capability.check_consumption(request, {approval_id = "approval-1", proposal_digest = string.rep("0", 64),
                thread_id = "thread-1", attempt_id = "attempt-1", capability = "workspace.files.read",
                template_revision = 2, parameters_digest = request.parameters_digest})
            test.eq(tampered, "approval proposal differs from the requested capability")
        end)
    end)
end
return test.run_cases(define_tests)
