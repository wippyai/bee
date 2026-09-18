-- MIT. Interactive acceptance of a permission exchange over the live
-- fixture runner: the request is observed before any response is sent, the
-- input-write boundary is recorded, and the correlated continuation is
-- verified after it. Allow, deny, a wrong correlation and no response are
-- each exercised. This is the proof an acceptance record stands on; the
-- transcript checker alone is not.
local test = require("test")
local exec = require("exec")
local env = require("env")
local registry = require("registry")
local hash = require("hash")
local stream_json = require("stream_json")
local protocol = require("protocol")
local adapter = require("adapter")
local acceptance = require("acceptance")
local REQUEST_ID = "perm-1"
type Object = {[string]: unknown}
type Run = {observations: {Object}, boundary: integer, request: adapter.Request?, exit_code: integer, stderr: string}
local function fixture(): (string, string)
    local bin, bin_error = env.get("bee.harness.catalog:fixture_bin")
    if bin_error or type(bin) ~= "string" or bin == "" then error("BEE_FIXTURE_BIN is not set for the test runtime") end
    local streams, streams_error = env.get("bee.harness.catalog:fixture_streams")
    if streams_error or type(streams) ~= "string" or streams == "" then error("BEE_FIXTURE_STREAMS is not set for the test runtime") end
    return bin .. "/claude", streams .. "/claude/stream-json-2/permission.jsonl"
end
local function encoded(line: string?, err: string?): string
    if not line then error("encode response: " .. tostring(err)) end
    return line
end
local function fixture_adapter(): adapter.Adapter
    local entry = registry.get("bee.harness.catalog:permission_fixture_adapter")
    if not entry then error("fixture adapter entry") end
    local data = entry.data :: Object
    local decoded, err = adapter.decode("bee.harness.catalog:permission_fixture_adapter", data.adapter)
    if not decoded then error(tostring(err)) end
    return decoded
end
-- drive runs the fixture once; respond decides what to write when the
-- request is observed and returns the line, or nil to stay silent.
local function drive(pinned: adapter.Adapter, respond: (adapter.Request) -> string?): Run
    local executable, stream = fixture()
    local executor = assert(exec.get("bee.placement.native:executor"))
    local proc, exec_error = executor:exec(executable, {env = {BEE_FIXTURE_STREAM = stream, BEE_FIXTURE_PERMISSION = REQUEST_ID, BEE_FIXTURE_PERMISSION_TIMEOUT = "1"}})
    if not proc then error("exec fixture: " .. tostring(exec_error)) end
    local stdout = proc:stdout_stream()
    local stderr = proc:stderr_stream()
    assert(proc:start())
    local decoder = stream_json.new(65536)
    local state = protocol.new(false)
    local run: Run = {observations = {}, boundary = 0, request = nil, exit_code = -1, stderr = ""}
    local responded = false
    while true do
        local chunk: unknown = stdout:read(4096)
        if type(chunk) ~= "string" or chunk == "" then break end
        local data = chunk :: string
        local envelopes = stream_json.feed(decoder, data)
        for _, envelope in ipairs(envelopes) do
            local step = protocol.normalize(state, envelope.index, envelope.value)
            for _, observation in ipairs(step.observations) do
                run.observations[#run.observations + 1] = observation :: Object
                if not run.request then
                    local found = adapter.request(pinned, observation)
                    if found then run.request = found end
                end
            end
        end
        if run.request and not responded then
            responded = true
            run.boundary = #run.observations
            local line = respond(run.request)
            if line then
                local written, write_error = proc:write_stdin(line)
                if not written then error("write_stdin: " .. tostring(write_error)) end
            end
        end
    end
    local errors = stderr:read(4096)
    run.stderr = tostring(errors or "")
    local code = proc:wait()
    run.exit_code = math.floor(tonumber(code) or -1)
    stdout:close()
    stderr:close()
    executor:release()
    return run
end
local function first_after(run: Run, kind: string, predicate: ((Object) -> boolean)?): integer
    for index = run.boundary + 1, #run.observations do
        local observation = run.observations[index]
        if observation.type == kind and (not predicate or predicate(observation)) then return index end
    end
    return 0
end
local function turn_outcome(run: Run): string
    for _, observation in ipairs(run.observations) do
        local data = observation.data :: Object
        if observation.type == "turn.signal" and data.phase == "ended" then return tostring(data.reported_outcome) end
    end
    return ""
end
local function define_tests()
    test.describe("Permission exchange acceptance", function()
        local pinned = fixture_adapter()
        test.it("allow: the response is written after the request is observed and the correlated tool result follows the write boundary", function()
            local run = drive(pinned, function(request: adapter.Request): string?
                return encoded(adapter.allow(pinned, request, nil))
            end)
            local request = run.request
            if not request then error("no permission request observed") end
            test.eq(request.correlation_id, REQUEST_ID)
            test.eq(request.tool_name, "Bash")
            test.is_true(run.boundary >= 1)
            local echo = first_after(run, "tool.result", function(observation: Object): boolean
                return (observation.data :: Object).call_id == REQUEST_ID
            end)
            test.is_true(echo > run.boundary)
            test.is_true(adapter.acknowledged(pinned, request, run.observations[echo]))
            test.eq(turn_outcome(run), "succeeded")
            test.eq(run.exit_code, 0)
            local consistent, err = adapter.transcript_consistent(pinned, run.observations, run.boundary)
            if not consistent then error(tostring(err)) end
        end)
        test.it("deny: the harness reports the denial after the write boundary and never runs the tool", function()
            local run = drive(pinned, function(request: adapter.Request): string?
                return encoded(adapter.deny(pinned, request, "denied by the owner"))
            end)
            test.not_nil(run.request)
            test.eq(first_after(run, "tool.result"), 0)
            local denied = first_after(run, "notice", function(observation: Object): boolean
                return (observation.data :: Object).code == "permission_denied"
            end)
            test.is_true(denied > run.boundary)
            test.eq(turn_outcome(run), "failed")
            local _, err = adapter.transcript_consistent(pinned, run.observations, run.boundary)
            test.eq(err, "the harness ended without acknowledging the response")
        end)
        test.it("wrong correlation: the harness keeps waiting and times out without acting", function()
            local run = drive(pinned, function(request: adapter.Request): string?
                local other: adapter.Request = {permission_request_id = request.permission_request_id, correlation_id = "perm-9", acknowledgment_id = "perm-9", tool_name = request.tool_name,
                    input_digest = request.input_digest, input = request.input, prompt = request.prompt}
                return encoded(adapter.allow(pinned, other, nil))
            end)
            test.not_nil(run.request)
            test.eq(first_after(run, "tool.result"), 0)
            test.is_true(run.stderr:find("uncorrelated:", 1, true) ~= nil)
            test.eq(turn_outcome(run), "failed")
            test.eq(run.exit_code, 2)
        end)
        test.it("no response: silence past the timeout ends the turn as failed, never as allowed", function()
            local run = drive(pinned, function(request: adapter.Request): string?
                return nil
            end)
            test.not_nil(run.request)
            test.eq(first_after(run, "tool.result"), 0)
            test.eq(turn_outcome(run), "failed")
            test.eq(run.exit_code, 2)
        end)
        test.it("measures the fixture for an acceptance record and refuses a record for another fixture", function()
            local _, stream = fixture()
            local executor = assert(exec.get("bee.placement.native:executor"))
            local proc = assert(executor:exec("cat " .. stream))
            local stdout = proc:stdout_stream()
            assert(proc:start())
            local content = ""
            while true do
                local chunk = stdout:read(65536)
                if not chunk or chunk == "" then break end
                content = content .. chunk
            end
            proc:wait()
            stdout:close()
            executor:release()
            local fixture_digest = assert(hash.sha256(content))
            local record, err = acceptance.decode("bee.harness.catalog:permission_fixture_acceptance", {schema_revision = "bee.permission-acceptance@2", binding_id = "bee.driver.claude:binding", profile_id = "session",
                binding_digest = string.rep("1", 64), profile_digest = string.rep("2", 64), adapter_ref = "bee.harness.catalog:permission_fixture_adapter", adapter_digest = pinned.digest,
                fixture_digest = fixture_digest, executable_revision = "bee.executable-measurement@1", executable_kind = "script", executable_digest = string.rep("7", 64), proof_revision = "bee.permission-proof@1", accepted_by = "bee.test.operator", accepted_at = "2026-09-09T00:00:00.000Z"})
            if not record then error(tostring(err)) end
            local measured = {binding_id = "bee.driver.claude:binding", profile_id = "session", binding_digest = string.rep("1", 64), profile_digest = string.rep("2", 64),
                adapter_ref = "bee.harness.catalog:permission_fixture_adapter", adapter_digest = pinned.digest, fixture_digest = fixture_digest}
            test.is_nil(acceptance.matches(record, measured))
            measured.fixture_digest = assert(hash.sha256(content .. "\n"))
            test.eq(acceptance.matches(record, measured), "proof fixture changed since acceptance")
        end)
    end)
end
return test.run_cases(define_tests)
