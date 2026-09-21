-- MIT. The host-admitted staging facade owns persistence; callers receive no
-- database, registry, overlay, filesystem, or publication authority.
local test = require("test")
local funcs = require("funcs")
local security = require("security")

local TARGET = "bee.governance:overlay_call"
local DIRECT_STORE = "bee.governance:direct_store_probe"
local POLICY = "bee.governance:authoring_client_policy"
local APP_BOUNDARY = "bee:ordinary_app_subsystem_boundary"

type Reply = {ok: boolean, code: string?, message: string?, value: {[string]: unknown}?, replayed: boolean}

local function scope(ordinary: boolean): security.Scope
    local policies: {security.Policy} = {}
    local names = {POLICY}
    if ordinary then
        names[#names + 1] = APP_BOUNDARY
        names[#names + 1] = "bee:app_boundary_policy"
    end
    for _, name in ipairs(names) do
        local policy, policy_error = security.policy(name)
        if not policy then error("authoring test policy " .. name .. ": " .. tostring(policy_error)) end
        policies[#policies + 1] = policy
    end
    return security.new_scope(policies)
end

local function call(actor_id: string, request: unknown, ordinary: boolean): Reply
    local result, call_error = funcs.new():with_actor(security.new_actor(actor_id)):with_scope(scope(ordinary)):call(TARGET, request)
    if call_error then error("workspace call: " .. tostring(call_error)) end
    return result :: Reply
end

local function successful(actor_id: string, request: unknown): Reply
    local reply = call(actor_id, request, true)
    if not reply.ok then error(tostring(reply.code) .. ": " .. tostring(reply.message)) end
    return reply
end

local function define_tests()
    test.describe("Governance authoring boundary", function()
        test.it("requires current operation and exact workspace permission even for the stored author", function()
            local owner = "bee.test.governance.scoped-owner"
            for _, id in ipairs({"governance-scoped-read", "governance-scoped-other"}) do
                local created = successful(owner, {operation = "create", overlay_id = id, expected_revision = 0, idempotency_key = "create"})
                test.eq(created.value and created.value.overlay_id, id)
                test.is_nil(created.value and created.value.workspace_id)
            end
            local policies: {security.Policy} = {}
            for _, name in ipairs({"bee.governance:authoring_call_only_policy", "bee.governance:authoring_exact_read_policy", APP_BOUNDARY, "bee:app_boundary_policy"}) do
                local policy, policy_error = security.policy(name)
                if not policy then error("scoped authoring policy: " .. tostring(policy_error)) end
                policies[#policies + 1] = policy
            end
            local executor = funcs.new():with_actor(security.new_actor(owner)):with_scope(security.new_scope(policies))
            local read, read_error = executor:call(TARGET, {operation = "list", overlay_id = "governance-scoped-read"})
            if read_error then error(tostring(read_error)) end
            test.is_true((read :: Reply).ok)
            local other, other_error = executor:call(TARGET, {operation = "list", overlay_id = "governance-scoped-other"})
            if other_error then error(tostring(other_error)) end
            test.is_false((other :: Reply).ok)
            test.eq((other :: Reply).code, "DENIED")
            local write, write_error = executor:call(TARGET, {operation = "put", overlay_id = "governance-scoped-read",
                expected_revision = 1, idempotency_key = "denied-write", path = "entry.lua", content = "return true"})
            if write_error then error(tostring(write_error)) end
            test.is_false((write :: Reply).ok)
            test.eq((write :: Reply).code, "DENIED")
            local unchanged = successful(owner, {operation = "list", overlay_id = "governance-scoped-read"})
            test.eq(unchanged.value and unchanged.value.revision, 1)
        end)

        test.it("lets an ordinary app stage binary snapshots while direct storage and backend execution stay denied", function()
            local workspace_id = "governance-authoring-boundary"
            local owner = "bee.test.governance.owner"
            local direct, direct_error = funcs.new():with_actor(security.new_actor(owner)):with_scope(scope(true)):call(DIRECT_STORE, {})
            if direct_error then error("direct database probe: " .. tostring(direct_error)) end
            test.is_false((direct :: {opened: boolean}).opened)
            local executor = funcs.new():with_actor(security.new_actor(owner)):with_scope(scope(true))
            local private, private_error = executor:call("bee.governance:workspace_backend_call", {operation = "list", workspace_id = workspace_id})
            if private_error then error(tostring(private_error)) end
            test.eq((private :: Reply).code, "DENIED")
            local created = successful(owner, {operation = "create", overlay_id = workspace_id, expected_revision = 0, idempotency_key = "create"})
            test.eq(created.value and created.value.revision, 1)
            test.eq(created.value and created.value.overlay_id, workspace_id)
            test.is_nil(created.value and created.value.workspace_id)

            local put = successful(owner, {operation = "put", overlay_id = workspace_id, expected_revision = 1, idempotency_key = "binary", path = "assets/agent.wasm", content_base64 = "AP8="})
            test.eq(put.value and put.value.revision, 2)
            local replay = successful(owner, {operation = "put", overlay_id = workspace_id, expected_revision = 1, idempotency_key = "binary", path = "assets/agent.wasm", content_base64 = "AP8="})
            test.is_true(replay.replayed)
            test.eq(replay.value and replay.value.revision, 2)

            local frozen = successful(owner, {operation = "freeze", overlay_id = workspace_id, expected_revision = 2, idempotency_key = "freeze"})
            local digest = frozen.value and frozen.value.digest
            if type(digest) ~= "string" then error("freeze returned no snapshot digest") end
            successful(owner, {operation = "put", overlay_id = workspace_id, expected_revision = 2, idempotency_key = "replace", path = "assets/agent.wasm", content = "later"})

            local retained = successful(owner, {operation = "read", overlay_id = workspace_id, path = "assets/agent.wasm", snapshot_digest = digest})
            test.eq(retained.value and retained.value.content_base64, "AP8=")
            test.eq(retained.value and retained.value.overlay_id, workspace_id)
            test.is_nil(retained.value and retained.value.workspace_id)
            local foreign = call("bee.test.governance.other", {operation = "list", overlay_id = workspace_id}, false)
            test.is_false(foreign.ok)
            test.eq(foreign.code, "DENIED")
            local after, after_error = executor:call(DIRECT_STORE, {})
            if after_error then error(tostring(after_error)) end
            test.is_false((after :: {opened: boolean}).opened)
            local private_after, private_after_error = executor:call("bee.governance:workspace_backend_call", {operation = "list", workspace_id = workspace_id})
            if private_after_error then error(tostring(private_after_error)) end
            test.eq((private_after :: Reply).code, "DENIED")
        end)

        test.it("accepts the total byte limit when independently padded files reach it", function()
            local workspace_id = "governance-base64-total-bound"
            local owner = "bee.test.governance.padding-owner"
            local file = string.rep("x", 4 * 1024 * 1024)
            successful(owner, {operation = "create", overlay_id = workspace_id, expected_revision = 0, idempotency_key = "create"})
            for index = 1, 4 do
                local put = successful(owner, {operation = "put", overlay_id = workspace_id, expected_revision = index,
                    idempotency_key = "put-" .. tostring(index), path = "part-" .. tostring(index), content = file})
                test.eq(put.value and put.value.revision, index + 1)
            end
            local frozen = successful(owner, {operation = "freeze", overlay_id = workspace_id, expected_revision = 5, idempotency_key = "freeze"})
            test.eq(frozen.value and frozen.value.file_count, 4)
            test.eq(frozen.value and frozen.value.total_bytes, 16 * 1024 * 1024)
            local overflow = call(owner, {operation = "put", overlay_id = workspace_id, expected_revision = 5,
                idempotency_key = "overflow", path = "extra", content = "x"}, false)
            test.is_false(overflow.ok)
            local unchanged = successful(owner, {operation = "list", overlay_id = workspace_id})
            test.eq(unchanged.value and unchanged.value.revision, 5)
        end)
    end)
end

return test.run_cases(define_tests)
