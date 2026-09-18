-- MIT. The permission exchange adapter, pure: a definition decodes and
-- measures, a profile enables it only under the exact digest, a request
-- event yields a durable identity, the proposal binds the plan rather than
-- the carrier epoch, every key is qualified by owner, attempt and request,
-- responses take the adapter's shape, a transcript is checked for
-- consistency, a host acceptance record names what changed, and a
-- decision after settlement sends nothing.
local test = require("test")
local json = require("json")
local adapter = require("adapter")
local acceptance = require("acceptance")
local events = require("events")
local function definition(): {[string]: unknown}
    return {schema_revision = "bee.permission-adapter@2", event_name = "permission_request", event_revision = "probe-1",
        request = {correlation = "request_id", tool = "tool_name", input = "input", prompt = "message"},
        response = {envelope = {type = "control_response"}, correlation_field = "request_id", decision_field = "behavior", allow_value = "allow", deny_value = "deny", reason_field = "message", response_field = "updated_input"},
        acknowledgment = {mode = "correlation_echo", event_type = "extension", field = "request_id"}, deny_acknowledgment = {mode = "terminal_denial", event_type = "notice", field = "code", value = "permission_denied"},
        cancellation = "deny_before_close", proof_fixture = "permission_exchange"}
end
local function request_event(key: string, request_id: string, tool: string): {[string]: unknown}
    return events.extension(key, "permission_request", "probe-1", json.encode({request_id = request_id, tool_name = tool, input = {command = "ls"}, message = "Run ls?"}))
end
local function echo_event(key: string, request_id: string): {[string]: unknown}
    return events.extension(key, "permission_request", "probe-1", json.encode({request_id = request_id, tool_name = "Bash", input = {}, resolved = true}))
end
local function decoded_of(value: {[string]: unknown}): adapter.Adapter
    local decoded, err = adapter.decode("probe:permission", value)
    if not decoded then error(tostring(err)) end
    return decoded
end
local function request_of(decoded: adapter.Adapter, observation: {[string]: unknown}): adapter.Request
    local request, err = adapter.request(decoded, observation)
    if not request then error(tostring(err)) end
    return request
end
local function acceptance_record(): {[string]: unknown}
    return {schema_revision = "bee.permission-acceptance@2", binding_id = "fake:binding", profile_id = "session", binding_digest = string.rep("1", 64), profile_digest = string.rep("2", 64),
        adapter_ref = "probe:permission", adapter_digest = string.rep("3", 64), fixture_digest = string.rep("4", 64), executable_revision = "bee.executable-measurement@1", executable_kind = "elf", executable_digest = string.rep("7", 64), proof_revision = "bee.permission-proof@1",
        accepted_by = "bee.host.operator", accepted_at = "2026-09-09T00:00:00.000Z"}
end
local function define_tests()
    test.describe("Permission exchange adapter", function()
        test.it("decodes an exact definition, measures it and pins profiles to that digest", function()
            local decoded, err = adapter.decode("probe:permission", definition())
            if not decoded then error(tostring(err)) end
            test.eq(#decoded.digest, 64)
            test.is_nil(adapter.pinned(decoded, {mode = "adapter", adapter_ref = "probe:permission", adapter_digest = decoded.digest}))
            test.eq(adapter.pinned(decoded, {mode = "none"}), "the profile does not enable a permission exchange")
            test.not_nil(adapter.pinned(decoded, {mode = "adapter", adapter_ref = "probe:permission", adapter_digest = string.rep("0", 64)}))
            test.not_nil(adapter.pinned(decoded, {mode = "adapter", adapter_ref = "other:permission", adapter_digest = decoded.digest}))
            local changed = definition()
            changed.cancellation = "unsupported"
            local other = decoded_of(changed)
            test.neq(other.digest, decoded.digest)
            local unknown = definition()
            unknown.timeout_ms = 5
            local _, unknown_error = adapter.decode("probe:permission", unknown)
            test.eq(unknown_error, "adapter: unknown field timeout_ms")
            local overlap = definition()
            overlap.response = {envelope = {behavior = "allow"}, correlation_field = "request_id", decision_field = "behavior", allow_value = "allow", deny_value = "deny"}
            local _, overlap_error = adapter.decode("probe:permission", overlap)
            test.eq(overlap_error, "adapter response envelope overlaps its fields")
            local unproven = definition()
            unproven.proof_fixture = nil
            local _, unproven_error = adapter.decode("probe:permission", unproven)
            test.eq(unproven_error, "adapter proof_fixture names the capture that proves the harness keeps waiting")
            local unnamed = definition()
            unnamed.deny_acknowledgment = {mode = "terminal_denial"}
            local _, unnamed_error = adapter.decode("probe:permission", unnamed)
            test.eq(unnamed_error, "adapter terminal_denial names the observation event_type, field and value that report the denial")
            local asked = request_of(decoded, request_event("3:req", "perm-1", "Bash"))
            test.is_true(adapter.deny_acknowledged(decoded, asked, events.notice("4:denied", "warning", "permission_denied", "Bash")))
            test.is_false(adapter.deny_acknowledged(decoded, asked, events.notice("4:info", "info", "informational", "Bash")))
            local unproven = definition()
            unproven.deny_acknowledgment = {mode = "unproven"}
            test.is_false(adapter.deny_acknowledged(decoded_of(unproven), asked, events.notice("4:denied", "warning", "permission_denied", "Bash")))
            local blind = definition()
            blind.acknowledgment = {mode = "correlation_echo"}
            local _, blind_error = adapter.decode("probe:permission", blind)
            test.eq(blind_error, "adapter correlation_echo names the observation event_type and field that echo the correlation")
        end)
        test.it("takes nested response paths, a separate acknowledgment id and a correlated terminal denial", function()
            local nested = definition()
            nested.request = {correlation = "request_id", tool = "request.tool_name", input = "request.input", prompt = "request.description", acknowledgment = "request.tool_use_id"}
            nested.response = {envelope = {type = "control_response", response = {subtype = "success"}}, correlation_field = "response.request_id", decision_field = "response.response.behavior",
                allow_value = "allow", deny_value = "deny", reason_field = "response.response.message"}
            nested.acknowledgment = {mode = "correlation_echo", event_type = "tool.result", field = "call_id"}
            nested.deny_acknowledgment = {mode = "terminal_denial", event_type = "tool.result", field = "outcome", value = "failed", correlation_field = "call_id"}
            local decoded = decoded_of(nested)
            local asked = request_of(decoded, events.extension("7:req", "permission_request", "probe-1", json.encode({request_id = "req-7", request = {tool_name = "Bash", input = {command = "touch proof.txt"}, description = "leave a marker", tool_use_id = "toolu-7"}})))
            test.eq(asked.correlation_id, "req-7")
            test.eq(asked.acknowledgment_id, "toolu-7")
            test.eq(asked.prompt, "leave a marker")
            local allow = json.decode(assert(adapter.allow(decoded, asked, nil))) :: {[string]: unknown}
            test.eq(allow.type, "control_response")
            local response = allow.response :: {[string]: unknown}
            test.eq(response.subtype, "success")
            test.eq(response.request_id, "req-7")
            test.eq((response.response :: {[string]: unknown}).behavior, "allow")
            local deny = json.decode(assert(adapter.deny(decoded, asked, "decision denied"))) :: {[string]: unknown}
            local inner = (deny.response :: {[string]: unknown}).response :: {[string]: unknown}
            test.eq(inner.behavior, "deny")
            test.eq(inner.message, "decision denied")
            test.is_true(adapter.acknowledged(decoded, asked, events.tool_result("8:res", "toolu-7", "succeeded", "", nil)))
            test.is_false(adapter.acknowledged(decoded, asked, events.tool_result("8:res", "req-7", "succeeded", "", nil)))
            test.is_true(adapter.deny_acknowledged(decoded, asked, events.tool_result("8:res", "toolu-7", "failed", "decision denied", events.fault("tool_error", "decision denied", false))))
            test.is_false(adapter.deny_acknowledged(decoded, asked, events.tool_result("8:res", "toolu-9", "failed", "decision denied", events.fault("tool_error", "decision denied", false))))
            test.is_false(adapter.deny_acknowledged(decoded, asked, events.tool_result("8:res", "toolu-7", "succeeded", "", nil)))
            local missing = adapter.request(decoded, events.extension("9:req", "permission_request", "probe-1", json.encode({request_id = "req-9", request = {tool_name = "Bash", input = {}}})))
            test.is_nil(missing)
            local _, missing_error = adapter.request(decoded, events.extension("9:req", "permission_request", "probe-1", json.encode({request_id = "req-9", request = {tool_name = "Bash", input = {}}})))
            test.eq(missing_error, "permission request has no request.tool_use_id")
            local crossing = definition()
            crossing.response = {envelope = {type = "control_response", response = "flat"}, correlation_field = "response.request_id", decision_field = "behavior", allow_value = "allow", deny_value = "deny"}
            local _, cross_error = adapter.decode("probe:permission", crossing)
            test.eq(cross_error, "adapter response envelope overlaps its fields")
            local prefixed = definition()
            prefixed.response = {envelope = {type = "control_response"}, correlation_field = "response", decision_field = "response.behavior", allow_value = "allow", deny_value = "deny"}
            local _, prefix_error = adapter.decode("probe:permission", prefixed)
            test.eq(prefix_error, "adapter response fields overlap: response and response.behavior")
            local deep = definition()
            deep.response = {envelope = {}, correlation_field = "a.b.c.d.e.f.g.h.i", decision_field = "behavior", allow_value = "allow", deny_value = "deny"}
            local _, deep_error = adapter.decode("probe:permission", deep)
            test.eq(deep_error, "response.correlation_field must be a dotted path of at most 8 segments")
            local empty = definition()
            empty.request = {correlation = "request..id", tool = "tool_name", input = "input"}
            local _, empty_error = adapter.decode("probe:permission", empty)
            test.eq(empty_error, "request.correlation must be a dotted path of at most 8 segments")
            local old = definition()
            old.schema_revision = "bee.permission-adapter@1"
            local _, old_error = adapter.decode("probe:permission", old)
            test.eq(old_error, "adapter schema_revision must be bee.permission-adapter@2")
        end)
        test.it("recognizes a request with a durable identity and binds the proposal to the plan, not the epoch", function()
            local decoded = decoded_of(definition())
            local request, err = adapter.request(decoded, request_event("7:request", "req-1", "Bash"))
            if not request then error(tostring(err)) end
            test.eq(request.permission_request_id, "7:request")
            test.eq(request.correlation_id, "req-1")
            test.eq(request.tool_name, "Bash")
            test.eq(request.prompt, "Run ls?")
            test.eq(#request.input_digest, 64)
            local none, none_error = adapter.request(decoded, events.notice("8:notice", "warning", "permission_denied", "Bash"))
            test.is_nil(none)
            test.is_nil(none_error)
            local broken = events.extension("9:request", "permission_request", "probe-1", json.encode({tool_name = "Bash"}))
            local _, broken_error = adapter.request(decoded, broken)
            test.eq(broken_error, "permission request has no request_id")
            local proposal = adapter.proposal(decoded, {action_id = "a1", attempt_id = "t1", plan_digest = string.rep("b", 64)}, request)
            test.eq(proposal.kind, "attempt")
            test.eq(proposal.ref, "t1")
            test.eq(proposal.revision, string.rep("b", 64))
            test.eq(proposal.action_id, "a1")
            test.eq(proposal.input_digest, request.input_digest)
            local payload = proposal.payload :: {[string]: unknown}
            test.eq(payload.permission_request_id, "7:request")
            test.eq(payload.adapter_digest, decoded.digest)
            test.is_nil(payload.carrier_epoch)
            local identity = {owner_id = "node-a", attempt_id = "t1", permission_request_id = "7:request"}
            test.eq(adapter.idempotency_key(identity), adapter.idempotency_key({owner_id = "node-a", attempt_id = "t1", permission_request_id = "7:request"}))
            test.neq(adapter.idempotency_key(identity), adapter.idempotency_key({owner_id = "node-a", attempt_id = "t2", permission_request_id = "7:request"}))
            test.neq(adapter.effect_key(identity), adapter.idempotency_key(identity))
            test.neq(adapter.write_id(identity), adapter.effect_key(identity))
            test.eq(adapter.write_id(identity):sub(1, 17), "permission-write-")
            local pending: {adapter.Request} = {request}
            local same_again = request_of(decoded, request_event("7:request", "req-1", "Bash"))
            test.is_true(adapter.admit_pending(pending, same_again))
            local reused = request_of(decoded, request_event("9:request", "req-1", "Read"))
            local admitted, ambiguity = adapter.admit_pending(pending, reused)
            test.is_false(admitted)
            test.eq(ambiguity, "correlation req-1 is already pending as 7:request")
            test.is_true(adapter.admit_pending(pending, request_of(decoded, request_event("9:request", "req-2", "Read"))))
        end)
        test.it("encodes allow and deny in the adapter's response shape", function()
            local decoded = decoded_of(definition())
            local request = request_of(decoded, request_event("7:request", "req-1", "Bash"))
            local allow = assert(adapter.allow(decoded, request, {command = "ls -la"}))
            test.eq(allow:sub(-1), "\n")
            local allowed = json.decode(allow) :: {[string]: unknown}
            test.eq(allowed.type, "control_response")
            test.eq(allowed.request_id, "req-1")
            test.eq(allowed.behavior, "allow")
            test.eq((allowed.updated_input :: {[string]: unknown}).command, "ls -la")
            local denied = json.decode(assert(adapter.deny(decoded, request, "denied by the owner"))) :: {[string]: unknown}
            test.eq(denied.behavior, "deny")
            test.eq(denied.message, "denied by the owner")
            test.is_nil(denied.updated_input)
        end)
        test.it("checks a transcript for consistency with a continuing exchange and refuses one that ends or never acknowledges", function()
            local decoded = decoded_of(definition())
            local waiting = {events.session("1:session", "started", nil), request_event("2:request", "req-1", "Bash"), echo_event("3:echo", "req-1"),
                events.tool_result("4:result", "req-1", "succeeded", "ok", nil), events.session("5:session", "ended", nil)}
            local proven, err = adapter.transcript_consistent(decoded, waiting, 2)
            if not proven then error(tostring(err)) end
            test.eq(proven.correlation_id, "req-1")
            local ended = {events.session("1:session", "started", nil), request_event("2:request", "req-1", "Bash"), events.session("3:session", "ended", nil)}
            local _, ended_error = adapter.transcript_consistent(decoded, ended, 3)
            test.eq(ended_error, "the harness ended before the response")
            local silent = {request_event("1:request", "req-1", "Bash"), events.session("2:session", "ended", nil)}
            local _, silent_error = adapter.transcript_consistent(decoded, silent, 1)
            test.eq(silent_error, "the harness ended without acknowledging the response")
            local none = {events.session("1:session", "started", nil), events.notice("2:notice", "warning", "permission_denied", "Bash")}
            local _, none_error = adapter.transcript_consistent(decoded, none, 2)
            test.eq(none_error, "the transcript has no permission request")
            local nested = definition()
            nested.acknowledgment = {mode = "correlation_echo", event_type = "tool.result", field = "call_id"}
            local by_tool = decoded_of(nested)
            local tool_ack = {request_event("1:request", "req-1", "Bash"), events.tool_result("2:result", "req-1", "succeeded", "ok", nil)}
            test.not_nil(adapter.transcript_consistent(by_tool, tool_ack, 1))
            test.is_false(adapter.acknowledged(by_tool, request_of(by_tool, tool_ack[1]), events.tool_result("3:result", "req-9", "succeeded", "ok", nil)))
            local continued = definition()
            continued.acknowledgment = {mode = "continued_output"}
            local loose = decoded_of(continued)
            local output = {request_event("1:request", "req-1", "Bash"), events.tool_result("2:result", "req-1", "succeeded", "ok", nil)}
            test.not_nil(adapter.transcript_consistent(loose, output, 1))
            test.is_false(adapter.acknowledged(loose, request_of(loose, output[1]), events.session("3:session", "ended", nil)))
        end)
        test.it("decodes a host acceptance record and names the measurement that changed", function()
            local record, err = acceptance.decode("fake:acceptance", acceptance_record())
            if not record then error(tostring(err)) end
            local measured = {binding_id = "fake:binding", profile_id = "session", binding_digest = string.rep("1", 64), profile_digest = string.rep("2", 64),
                adapter_ref = "probe:permission", adapter_digest = string.rep("3", 64), fixture_digest = string.rep("4", 64)}
            test.is_nil(acceptance.matches(record, measured))
            measured.adapter_digest = string.rep("5", 64)
            test.eq(acceptance.matches(record, measured), "adapter measurement changed since acceptance")
            measured.adapter_digest = string.rep("3", 64)
            measured.fixture_digest = string.rep("6", 64)
            test.eq(acceptance.matches(record, measured), "proof fixture changed since acceptance")
            measured.fixture_digest = string.rep("4", 64)
            measured.profile_id = "batch"
            test.eq(acceptance.matches(record, measured), "acceptance covers profile session, not batch")
            measured.profile_id = "session"
            measured.executable_digest = string.rep("8", 64)
            test.eq(acceptance.matches(record, measured), "executable measurement changed since acceptance")
            measured.executable_digest = string.rep("7", 64)
            test.is_nil(acceptance.matches(record, measured))
            measured.executable_kind = "script"
            test.eq(acceptance.matches(record, measured), "executable kind changed since acceptance")
            measured.executable_kind = nil
            measured.executable_revision = "bee.executable-measurement@0"
            test.eq(acceptance.matches(record, measured), "executable measurement revision changed since acceptance")
            measured.executable_revision = nil
            local launcher = acceptance_record()
            launcher.executable_kind = "launcher"
            local _, launcher_error = acceptance.decode("fake:acceptance", launcher)
            test.eq(launcher_error, "acceptance executable_kind must be elf, script or other")
            local unmeasured = acceptance_record()
            unmeasured.executable_digest = nil
            local _, unmeasured_error = acceptance.decode("fake:acceptance", unmeasured)
            test.eq(unmeasured_error, "acceptance executable_digest must be a sha256 hex digest")
            local stale = acceptance_record()
            stale.proof_revision = "bee.permission-proof@0"
            local _, stale_error = acceptance.decode("fake:acceptance", stale)
            test.eq(stale_error, "acceptance proof_revision must be bee.permission-proof@1")
            local loose = acceptance_record()
            loose.fixture_digest = "permission"
            local _, loose_error = acceptance.decode("fake:acceptance", loose)
            test.eq(loose_error, "acceptance fixture_digest must be a sha256 hex digest")
        end)
        test.it("sends nothing after settlement and denies only while the exchange still waits", function()
            local decoded = decoded_of(definition())
            test.eq(adapter.outcome(decoded, "approved", true, false), "allow")
            test.eq(adapter.outcome(decoded, "approved", false, false), "none")
            test.eq(adapter.outcome(decoded, "approved", true, true), "none")
            test.eq(adapter.outcome(decoded, "denied", true, false), "deny")
            test.eq(adapter.outcome(decoded, "expired", true, false), "deny")
            test.eq(adapter.outcome(decoded, "cancelled", false, false), "none")
            local unsupported = definition()
            unsupported.cancellation = "unsupported"
            local fixed = decoded_of(unsupported)
            test.eq(adapter.outcome(fixed, "expired", true, false), "none")
            test.eq(adapter.outcome(fixed, "denied", true, false), "deny")
        end)
    end)
end
return test.run_cases(define_tests)
