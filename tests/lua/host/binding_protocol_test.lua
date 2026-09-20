-- MIT. Pure coverage for the private broker-to-host binding wire contract.
local test = require("test")
local protocol = require("protocol")

local WORKSPACE = "0123456789abcdef0123456789abcdef"
local DIGEST = string.rep("a", 64)

local function prepare_value(): {[string]: unknown}
    return {instance_id = "instance", thread_id = "thread", definition_id = "bee.example:app",
        actor_id = "bee.application:" .. WORKSPACE .. ":instance", role = "participant", idempotency_key = "prepare-once",
        definition_revision = "revision-1", initiating_owner_id = "owner-1", gateway_binding_id = "gateway-binding-1",
        gateway_approval_id = "approval-1", gateway_proposal_digest = DIGEST, access = "observe_post", join_expected_revision = 7}
end

local function request(request_id: string, op: string, value: {[string]: unknown}): {[string]: unknown}
    return {version = 1, workspace_id = WORKSPACE, request_id = request_id, op = op, value = value}
end

local function binding(state: string, revision: integer, membership: integer?, pending: number, cleanup_revision: integer?): {[string]: unknown}
    return {instance_id = "instance", thread_id = "thread", definition_id = "bee.example:app",
        actor_id = "bee.application:" .. WORKSPACE .. ":instance", role = "participant", binding_revision = revision,
        state = state, idempotency_key = "prepare-once", definition_revision = "revision-1", initiating_owner_id = "owner-1",
        gateway_binding_id = "gateway-binding-1", gateway_approval_id = "approval-1", gateway_proposal_digest = DIGEST,
        access = "observe_post", join_expected_revision = 7, membership_revision = membership,
        cleanup_pending = pending, cleanup_expected_revision = cleanup_revision}
end

local function define_tests()
    test.describe("Application thread binding host protocol", function()
        test.it("decodes every exact storage operation", function()
            local values = {
                prepare = prepare_value(),
                activate = {instance_id = "instance", expected_revision = 1, expected_state = "pending", membership_revision = 9},
                refresh_join = {instance_id = "instance", expected_revision = 1, expected_state = "pending", join_expected_revision = 10},
                begin_revoke = {instance_id = "instance", expected_revision = 2, expected_state = "active", cleanup_expected_revision = 12},
                refresh_cleanup = {instance_id = "instance", expected_revision = 3, expected_state = "revoked", cleanup_expected_revision = 13},
                finish_revoke = {instance_id = "instance", expected_revision = 4, expected_state = "revoked"},
            }
            for op, value in pairs(values) do
                local decoded = protocol.request(request("request-" .. op, op, value), WORKSPACE)
                if not decoded then error("valid operation rejected: " .. op) end
                test.eq(decoded.op, op)
            end
        end)

        test.it("rejects extras, wrong types, forged authority and provenance fields", function()
            local forged = request("request", "prepare", prepare_value())
            for _, field in ipairs({"pid", "execution_pid", "launch_token", "scope", "database_id", "sender", "source", "thread_owner"}) do
                local value = request("request", "prepare", prepare_value())
                value.value[field] = "forged"
                test.is_nil(protocol.request(value, WORKSPACE), field)
            end
            forged.value.actor_id = {id = "forged"}
            test.is_nil(protocol.request(forged, WORKSPACE))
            forged = request("request", "prepare", prepare_value())
            forged.value.actor_id = "bee.application:" .. WORKSPACE .. ":other-instance"
            test.is_nil(protocol.request(forged, WORKSPACE))
            forged = request("request", "prepare", prepare_value()); forged.value.gateway_proposal_digest = string.upper(DIGEST)
            test.is_nil(protocol.request(forged, WORKSPACE))
            forged = request("request", "prepare", prepare_value()); forged.value.role = "observer"
            test.is_nil(protocol.request(forged, WORKSPACE))
            forged = request("request", "prepare", prepare_value()); forged.value.access = "all"
            test.is_nil(protocol.request(forged, WORKSPACE))
            test.is_nil(protocol.request({version = 1, workspace_id = WORKSPACE, request_id = "request", op = "prepare", value = {}}, WORKSPACE))
            test.is_nil(protocol.request({version = 1, workspace_id = WORKSPACE, request_id = "request", op = "prepare", value = {1}}, WORKSPACE))
            test.is_nil(protocol.request({version = 1, workspace_id = string.rep("f", 32), request_id = "request", op = "prepare", value = prepare_value()}, WORKSPACE))
            test.is_nil(protocol.request({version = 1, workspace_id = WORKSPACE, request_id = "request", op = "get", value = {}}, WORKSPACE))
            test.is_nil(protocol.request({version = 1, workspace_id = WORKSPACE, request_id = "request", op = "get", value = {instance_id = "instance"}}, WORKSPACE))
        end)

        test.it("decodes full pending, active and cleanup-pending bindings", function()
            local pending = assert(protocol.binding(binding("pending", 1, nil, 0, nil)))
            test.is_nil(pending.membership_revision)
            local active = assert(protocol.binding(binding("active", 2, 9, 0, nil)))
            test.eq(active.membership_revision, 9)
            local revoked = assert(protocol.binding(binding("revoked", 3, 9, 1, 12)))
            test.eq(revoked.cleanup_pending, 1)
            test.eq(revoked.cleanup_expected_revision, 12)
            test.is_nil(protocol.binding(binding("pending", 1, 9, 0, nil)))
            test.is_nil(protocol.binding(binding("active", 2, 9, 1, 12)))
            test.is_nil(protocol.binding(binding("revoked", 3, 9, 0, 12)))
            test.is_nil(protocol.binding(binding("revoked", 3, 9, 1, nil)))
        end)

        test.it("accepts only bounded unfinished recovery bindings", function()
            local revoked = binding("revoked", 3, 9, 1, 12)
            revoked.instance_id = "instance-two"
            revoked.actor_id = "bee.application:" .. WORKSPACE .. ":instance-two"
            local recovered = assert(protocol.recovery({version = 1, workspace_id = WORKSPACE,
                items = {binding("pending", 1, nil, 0, nil), revoked}}, WORKSPACE))
            test.eq(#recovered.items, 2)
            local finished = binding("revoked", 3, 9, 0, nil)
            test.is_nil(protocol.recovery({version = 1, workspace_id = WORKSPACE, items = {finished}}, WORKSPACE))
            local duplicate = binding("active", 2, 9, 0, nil)
            test.is_nil(protocol.recovery({version = 1, workspace_id = WORKSPACE, items = {duplicate, duplicate}}, WORKSPACE))
            test.is_nil(protocol.recovery({version = 1, workspace_id = string.rep("f", 32), items = {}}, WORKSPACE))
            test.is_nil(protocol.recovery({version = 1, workspace_id = WORKSPACE, items = {}, forged = true}, WORKSPACE))
        end)

        test.it("accepts only the exact broker recovery acknowledgement", function()
            test.not_nil(protocol.recovered({version = 1, workspace_id = WORKSPACE}, WORKSPACE))
            test.is_nil(protocol.recovered({version = 1, workspace_id = WORKSPACE, items = {}}, WORKSPACE))
            test.is_nil(protocol.recovered({version = 2, workspace_id = WORKSPACE}, WORKSPACE))
            test.is_nil(protocol.recovered({version = 1, workspace_id = string.rep("f", 32)}, WORKSPACE))
        end)

        test.it("requires a binding success or bounded fault and preserves exact identity", function()
            local decoded_request = assert(protocol.request(request("request", "activate",
                {instance_id = "instance", expected_revision = 1, expected_state = "pending", membership_revision = 9}), WORKSPACE))
            local success = assert(protocol.success(decoded_request, binding("active", 2, 9, 0, nil)))
            local decoded = assert(protocol.reply(success, decoded_request))
            test.is_true(decoded.ok)
            test.eq(decoded.request_id, "request")
            test.eq(decoded.binding and decoded.binding.state, "active")
            local failure = assert(protocol.failure(decoded_request, "CONFLICT", "revision changed"))
            local refused = assert(protocol.reply(failure, WORKSPACE))
            test.is_false(refused.ok)
            test.eq(refused.error and refused.error.code, "CONFLICT")
            local malformed = protocol.failure(decoded_request, "CONFLICT", "revision changed")
            if not malformed then error("fault constructor refused valid fault") end
            malformed.error = {code = "CONFLICT", message = string.rep("x", 4097)}
            test.is_nil(protocol.reply(malformed, WORKSPACE))
            malformed = protocol.success(decoded_request, binding("active", 2, 9, 0, nil))
            if not malformed then error("success constructor refused valid binding") end
            malformed.binding.actor_id = {forged = true}
            test.is_nil(protocol.reply(malformed, WORKSPACE))
            malformed = protocol.success(decoded_request, binding("active", 2, 9, 0, nil))
            if not malformed then error("success constructor refused valid binding") end
            malformed.binding.actor_id = "bee.application:" .. WORKSPACE .. ":other-instance"
            test.is_nil(protocol.reply(malformed, WORKSPACE))
            malformed = protocol.success(decoded_request, binding("active", 2, 9, 0, nil))
            if not malformed then error("success constructor refused valid binding") end
            malformed.request_id = "other-request"
            test.is_nil(protocol.reply(malformed, decoded_request))
            malformed = protocol.success(decoded_request, binding("active", 2, 9, 0, nil))
            if not malformed then error("success constructor refused valid binding") end
            malformed.error = {code = "MIXED", message = "unexpected"}
            test.is_nil(protocol.reply(malformed, WORKSPACE))
        end)
    end)
end

return test.run_cases(define_tests)
