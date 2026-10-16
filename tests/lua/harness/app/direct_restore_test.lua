local test = require("test")
local bounds = require("bounds")
local direct = require("direct")
local admission = require("admission")
local WORKSPACE = "0123456789abcdef0123456789abcdef"
local DIGEST = string.rep("a", 64)
local function request(): admission.Request
    return {request_id = "resume-1", definition_ref = "bee.driver.claude.profiles:default_window", workspace_id = WORKSPACE,
        brief = "", mode = "window", saved_profile_id = "saved", saved_profile_revision = 2, overrides = {model = "fixture"},
        expected_plan_digest = DIGEST, continuation = {origin_request_id = "origin", previous_attempt_id = "attempt:origin", thread_id = "thread:origin"}}
end
return test.run_cases(function()
    test.describe("Agent window restore", function()
        test.it("runs the host setup of the saved launch before admitting its continuation", function()
            local order: {string} = {}
            local setup_request: {[string]: unknown}? = nil
            local admitted_key: string? = nil
            local function call(target: string, input: unknown): (unknown, string?)
                order[#order + 1] = target
                setup_request = bounds.object(input)
                return {ok = true, resources = {"session"}, credentials = {}}, nil
            end
            local function admit(candidate: admission.Request, operation_key: string?): (admission.Admitted?, admission.Reply?)
                order[#order + 1] = "admit"
                admitted_key = operation_key
                test.eq(candidate.request_id, "resume-1")
                return nil, {ok = false, error = {code = "CONFLICT", message = "fixture stops here"}, value = nil}
            end
            local _, refused = direct.restore(request(), "window-session:origin", call, admit)
            test.eq(order[1], "bee.harness.binding:setup")
            test.eq(order[2], "admit")
            test.eq(admitted_key, "window-session:origin")
            test.eq(refused and refused.error and refused.error.message, "fixture stops here")
            local sent = assert(setup_request)
            test.eq(sent.workspace_id, WORKSPACE)
            test.eq(sent.definition_ref, "bee.driver.claude.profiles:default_window")
            test.eq(sent.expected_plan_digest, DIGEST)
            test.eq(sent.saved_profile_id, "saved")
            test.eq(sent.saved_profile_revision, 2)
            test.eq((assert(bounds.object(sent.overrides))).model, "fixture")
        end)
        test.it("refuses the continuation with the setup's reason and admits nothing", function()
            local admitted = false
            local function call(target: string, input: unknown): (unknown, string?)
                return {ok = false, error = "host setup has no root for session"}, nil
            end
            local function admit(candidate: admission.Request, operation_key: string?): (admission.Admitted?, admission.Reply?)
                admitted = true
                return nil, nil
            end
            local choice, refused = direct.restore(request(), nil, call, admit)
            test.is_nil(choice)
            test.is_false(admitted)
            test.eq(refused and refused.error and refused.error.message, "host setup has no root for session")
        end)
    end)
end)
