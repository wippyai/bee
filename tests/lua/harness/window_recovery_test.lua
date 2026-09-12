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
