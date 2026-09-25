-- MIT. Peer-bound actor assertions and bounded forwarding lifetimes.
local test = require("test")
local types = require("types")
local admission = require("admission")
local peers = require("peers")
local catalog = require("catalog")
local time = require("time")
local FORMAT = "2006-01-02T15:04:05.000Z07:00"
local function now(): time.Time
    local value, err = time.parse(FORMAT, "2026-09-08T12:00:00.000Z")
    if not value then error(tostring(err)) end
    return value
end
local function request(): types.Request
    local digest = types.digest({})
    if not digest then error("digest") end
    local value: types.Request = {protocol_revision = types.REVISION, request_id = "exchange", idempotency_key = "retry",
        caller_node_id = "alpha", caller_incarnation = "alpha-inc", owner_ref = {node_id = "beta", service_id = "bee.hive.telemetry"},
        operation_ref = "bee.hive.telemetry:stats", operation_revision = "1", input = {}, input_digest = digest,
        principal_ref = {issuer = "alpha", subject_id = "{alpha@bee:workers|a1}"},
        principal_assertion = {method = types.ASSERTION_METHOD, audience = "beta", issued_at = "2026-09-08T12:00:00.000Z",
            expires_at = "2026-09-08T12:00:30.000Z"}, delegation_refs = {}, deadline = "2026-09-08T12:00:30.000Z"}
    return value
end
local PEER: peers.Peer = {node_id = "alpha", pid = "{alpha@bee.hive_host:supervisor_host|s1}",
    supervisor_incarnation = "alpha-inc", established_at = 0, answer_on_retry = false}
local function rejected(value: unknown, expected: string, sender: string?)
    local result, fault = admission.accept("beta", PEER, sender or PEER.pid, value, now())
    test.is_nil(result)
    if not fault then error("expected refusal") end
    test.eq(fault.code, expected)
end
local function define_tests()
    test.describe("Hive request admission", function()
        test.it("accepts the established peer's actor assertion only", function()
            local accepted, err = admission.accept("beta", PEER, PEER.pid, request(), now())
            test.is_nil(err)
            if not accepted then error("valid assertion denied") end
            test.eq(accepted.principal_ref.subject_id, "{alpha@bee:workers|a1}")
            local absent, fault = admission.accept("beta", nil, PEER.pid, request(), now())
            test.is_nil(absent)
            test.eq(fault and fault.code, "DENIED")
            rejected(request(), "DENIED", "{alpha@bee.hive_host:supervisor_host|s2}")
            local stale = request(); stale.caller_incarnation = "retired"
            rejected(stale, "DENIED")
        end)
        test.it("refuses issuer, subject and destination substitution", function()
            local issuer = request(); issuer.principal_ref.issuer = "admin"
            rejected(issuer, "DENIED")
            local subject = request(); subject.principal_ref.subject_id = "{gamma@bee:workers|a1}"
            rejected(subject, "DENIED")
            local destination = request(); destination.owner_ref.node_id = "gamma"
            destination.principal_assertion.audience = "gamma"
            rejected(destination, "DENIED")
        end)
        test.it("rejects future, expired, impossible and unbounded timestamps", function()
            local future = request(); future.principal_assertion.issued_at = "2026-09-08T12:00:01.000Z"
            rejected(future, "DENIED")
            local expired = request(); expired.principal_assertion.issued_at = "2026-09-08T11:59:00.000Z"
            expired.principal_assertion.expires_at = "2026-09-08T12:00:00.000Z"
            rejected(expired, "DEADLINE_EXCEEDED")
            local impossible = request(); impossible.principal_assertion.issued_at = "2026-02-30T12:00:00.000Z"
            rejected(impossible, "INVALID_ARGUMENT")
            local long = request(); long.deadline = "2026-09-08T12:01:00.000Z"
            rejected(long, "INVALID_ARGUMENT")
            local old = request(); old.principal_assertion.issued_at = "2026-09-08T11:59:59.999Z"
            rejected(old, "INVALID_ARGUMENT")
        end)
        test.it("derives the origin and shortens the deadline when forwarding", function()
            local original = request()
            local operation: catalog.Operation = {operation_ref = original.operation_ref, revision = "1", mode = "open",
                input_schema = {}, output_schema = {}, limits = {max_input_bytes = 100, max_output_bytes = 100},
                measured = "measurement", title = "Statistics"}
            local resolved: catalog.ResolvedCall = {operation = operation, input = {}, input_digest = original.input_digest, generation = 1}
            local call: types.Call = {protocol_revision = types.REVISION, request_id = "client-owned", idempotency_key = "stable",
                owner_ref = original.owner_ref, target = {operation_ref = original.operation_ref}, input = {}, deadline = "2026-09-08T12:00:05.000Z"}
            local forwarded, err = admission.forward("alpha", "alpha-inc", "{alpha@bee:workers|a1}", "supervisor-owned", call, resolved, now())
            test.is_nil(err)
            if not forwarded then error("forward") end
            test.eq(forwarded.request_id, "supervisor-owned")
            test.eq(forwarded.idempotency_key, "stable")
            test.eq(forwarded.deadline, call.deadline)
            test.eq(forwarded.principal_assertion.expires_at, call.deadline)
            local invalid, fault = admission.forward("alpha", "alpha-inc", "{gamma@bee:workers|a1}", "other", call, resolved, now())
            test.is_nil(invalid); test.eq(fault and fault.code, "DENIED")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
