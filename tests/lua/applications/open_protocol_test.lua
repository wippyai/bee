local test = require("test")
local protocol = require("protocol")
local contract = require("contract")

local function gateway_context(workspace: string): {[string]: unknown}
    return {binding_id = "binding-1", thread_id = "thread-1", subject = "subject-1", action_id = "action-1", attempt_id = "attempt-1",
        workspace_id = workspace, origin_view = {view_id = "view-1", instance_id = "instance-1"}, application_runtime = {
            binding_id = "binding-1", thread_id = "thread-1", subject = "subject-1", initiating_owner = "subject-1",
            access_approval_id = "approval-1", access_proposal_digest = string.rep("a", 64), surface_revision = 2, surface_digest = string.rep("b", 64)}}
end

local function provenance(workspace: string): {[string]: unknown}
    local runtime = gateway_context(workspace).application_runtime
    if type(runtime) ~= "table" then error("fixture runtime provenance is absent") end
    return runtime :: {[string]: unknown}
end

local function define_tests()
    test.describe("Agent application open protocol", function()
        test.it("accepts only the bound workspace and bounded literal arguments", function()
            local workspace = string.rep("a", 32)
            local request = protocol.request({version = 1, workspace_id = workspace, request_id = "open-1",
                definition_id = "bee.example:app", arguments = {"one", "two"}, caller_token = "bee.application.open/abc-123", provenance = provenance(workspace)}, workspace)
            if not request then error("valid open request rejected") end
            test.eq(request.definition_id, "bee.example:app")
            test.eq(request.arguments[2], "two")
            test.is_nil(protocol.request({version = 1, workspace_id = workspace, request_id = "open-1",
                definition_id = "bee.example:app", arguments = {}, caller_token = "ordinary/app", provenance = provenance(workspace)}, workspace))
            test.is_nil(protocol.request({version = 1, workspace_id = workspace, request_id = "open-1",
                definition_id = "bee.example:app", arguments = {}, thread_id = "caller-selected",
                caller_token = "bee.application.open/abc-123", provenance = provenance(workspace)}, workspace))
            test.is_nil(protocol.request({version = 1, workspace_id = string.rep("b", 32), request_id = "open-1",
                definition_id = "bee.example:app", arguments = {}, caller_token = "bee.application.open/abc-123", provenance = provenance(workspace)}, workspace))
            test.is_nil(protocol.request({version = 1, workspace_id = workspace, request_id = "open-1",
                definition_id = "bee.example:app", arguments = {}, caller_token = "bee.application.open/abc-123", provenance = provenance(workspace), extra = true}, workspace))
            test.is_nil(protocol.request({version = 1, workspace_id = workspace, request_id = "open-1",
                definition_id = "bee.example:app", arguments = {string.rep("x", 1025)}, caller_token = "bee.application.open/abc-123", provenance = provenance(workspace)}, workspace))
        end)
        test.it("requires sealed runtime provenance and refuses mismatched identities", function()
            local workspace = string.rep("a", 32)
            local valid = gateway_context(workspace)
            local decoded = protocol.gateway_context(valid)
            if not decoded then error("valid gateway context rejected") end
            test.eq(decoded.provenance.access_approval_id, "approval-1")
            valid.application_runtime.thread_id = "foreign"
            test.is_nil(protocol.gateway_context(valid))
            valid = gateway_context(workspace)
            valid.application_runtime.surface_digest = "not-a-digest"
            test.is_nil(protocol.gateway_context(valid))
            valid = gateway_context(workspace)
            valid.application_runtime.untrusted = true
            test.is_nil(protocol.gateway_context(valid))
            local partial = provenance(workspace)
            partial.thread_id = nil
            test.is_nil(protocol.request({version = 1, workspace_id = workspace, request_id = "open-1", definition_id = "bee.example:app",
                arguments = {}, caller_token = "bee.application.open/abc-123", provenance = partial}, workspace))
            local extra = provenance(workspace)
            extra.workspace_id = "caller-selected"
            test.is_nil(protocol.request({version = 1, workspace_id = workspace, request_id = "open-1", definition_id = "bee.example:app",
                arguments = {}, caller_token = "bee.application.open/abc-123", provenance = extra}, workspace))
            local forwarded = protocol.request({version = 1, workspace_id = workspace, request_id = "open-2", definition_id = "bee.example:app",
                arguments = {}, caller_token = "bee.application.open/abc-123", provenance = provenance(workspace)}, workspace)
            if not forwarded then error("valid forwarded provenance rejected") end
            test.eq(forwarded.provenance.binding_id, "binding-1")
            test.eq(forwarded.provenance.access_proposal_digest, string.rep("a", 64))
        end)
        test.it("validates the forwarded broker reply against both identities", function()
            local workspace = string.rep("a", 32)
            local reply = contract.reply("open-1", "open")
            reply.workspace_id = workspace
            local wrapped = protocol.reply({version = 1, workspace_id = workspace, request_id = "open-1", reply = reply}, workspace)
            if not wrapped then error("valid open reply rejected") end
            test.eq(wrapped.request_id, "open-1")
            test.eq(wrapped.reply.op, "open")
            test.is_nil(protocol.reply({version = 1, workspace_id = workspace, request_id = "other", reply = reply}, workspace))
            test.is_nil(protocol.reply({version = 1, workspace_id = string.rep("b", 32), request_id = "open-1", reply = reply}, workspace))
        end)
        test.it("accepts only a complete literal origin view", function()
            local origin = protocol.origin({view_id = "view-1", instance_id = "instance-1"})
            if not origin then error("valid origin rejected") end
            test.eq(origin.view_id, "view-1")
            test.is_nil(protocol.origin({view_id = "view-1"}))
            test.is_nil(protocol.origin({view_id = "view-1", instance_id = ""}))
            test.is_nil(protocol.origin({view_id = "view-1", instance_id = "instance-1", display_id = "chosen"}))
        end)
    end)
end

return require("test").run_cases(define_tests)
