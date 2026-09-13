-- MIT. Agent application checkpoint data is bounded identity, and checkpoint
-- acknowledgements are accepted only from the authenticated broker request.
local test = require("test")
local recovery = require("recovery")
local json = require("json")

local PLAN = string.rep("a", 64)
local SAVED: recovery.Saved = {definition_ref = "host:codex", plan_digest = PLAN,
    origin_request_id = "origin", previous_attempt_id = "attempt:origin", thread_id = "thread:codex"}

local function define_tests()
    test.describe("Agent application recovery", function()
        test.it("round trips exactly the five durable identity fields", function()
            local encoded, encode_error = recovery.encode(SAVED)
            if not encoded then error(tostring(encode_error)) end
            local decoded, decode_error = recovery.decode(json.decode(encoded))
            if not decoded then error(tostring(decode_error)) end
            test.eq(decoded.definition_ref, SAVED.definition_ref)
            test.eq(decoded.plan_digest, SAVED.plan_digest)
            test.eq(decoded.origin_request_id, SAVED.origin_request_id)
            test.eq(decoded.previous_attempt_id, SAVED.previous_attempt_id)
            test.eq(decoded.thread_id, SAVED.thread_id)
            for key in pairs(decoded :: {[string]: unknown}) do
                test.is_true(key == "definition_ref" or key == "plan_digest" or key == "origin_request_id"
                    or key == "previous_attempt_id" or key == "thread_id", "unexpected checkpoint field")
            end
        end)

        test.it("preserves a selected profile revision and refuses partial selection", function()
            local selected: {[string]: unknown} = {}
            for key, value in pairs(SAVED :: {[string]: unknown}) do selected[key] = value end
            selected.saved_profile_id = "profile:work"
            test.is_nil(recovery.decode(selected))
            selected.saved_profile_revision = 3
            local saved, err = recovery.decode(selected)
            if not saved then error(tostring(err)) end
            local encoded, encode_error = recovery.encode(saved)
            if not encoded then error(tostring(encode_error)) end
            local restored, restore_error = recovery.decode(json.decode(encoded))
            if not restored then error(tostring(restore_error)) end
            test.eq(restored.saved_profile_id, "profile:work")
            test.eq(restored.saved_profile_revision, 3)
            selected.saved_profile_revision = 0
            test.is_nil(recovery.decode(selected))
            selected.saved_profile_revision = 1.5
            test.is_nil(recovery.decode(selected))
            selected.saved_profile_revision = 3
            selected.saved_profile_id = nil
            test.is_nil(recovery.decode(selected))
        end)

        test.it("refuses malformed or authority bearing checkpoint data", function()
            local malformed: {[string]: unknown} = {}
            for key, value in pairs(SAVED :: {[string]: unknown}) do malformed[key] = value end
            malformed.plan_digest = string.rep("A", 64)
            test.is_nil(recovery.decode(malformed))
            malformed.plan_digest = PLAN
            malformed.grant_ref = "secret-grant"
            test.is_nil(recovery.decode(malformed))
        end)

        test.it("requires the broker and exact request for checkpoint acknowledgement", function()
            local launch = {broker_pid = "broker"}
            test.is_false(recovery.acknowledged(launch, "other", {version = 1, request_id = "request", error_code = "", error = ""}, "request"))
            test.is_false(recovery.acknowledged(launch, "broker", {version = 1, request_id = "stale", error_code = "", error = ""}, "request"))
            test.is_false(recovery.acknowledged(launch, "broker", {version = 1, request_id = "request", error_code = "denied", error = "refused"}, "request"))
            test.is_true(recovery.acknowledged(launch, "broker", {version = 1, request_id = "request", error_code = "", error = ""}, "request"))
        end)
    end)
end

return test.run_cases(define_tests)
