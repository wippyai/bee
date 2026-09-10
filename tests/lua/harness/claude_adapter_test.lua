-- MIT. The real Claude permission adapter, pure: it decodes from its
-- entry, the Claude profiles pin its exact digest, the captured control
-- request is recognized with the request id as the response correlation
-- and the tool use id as what the harness echoes back, responses take the
-- control_response shape the executable reads, a correlated tool result
-- acknowledges an allow and a correlated failed tool result acknowledges
-- a deny, and the capture is consistent with a continuing exchange.
local test = require("test")
local exec = require("exec")
local env = require("env")
local registry = require("registry")
local json = require("json")
local catalog = require("catalog")
local adapter = require("adapter")
local stream_json = require("stream_json")
local protocol = require("protocol")
local events = require("events")
local ADAPTER = "bee.driver.claude:permission_adapter"
local BINDING = "bee.driver.claude:binding"
type Object = {[string]: unknown}
local function capture_path(): string
    local streams, streams_error = env.get("bee.harness.catalog:fixture_streams")
    if streams_error or type(streams) ~= "string" or streams == "" then error("BEE_FIXTURE_STREAMS is not set for the test runtime") end
    return streams .. "/claude/stream-json-2/control.jsonl"
end
local function read_file(path: string): string
    local executor = assert(exec.get("bee.placement.native:executor"))
    local proc = assert(executor:exec("cat " .. path))
    local stdout = proc:stdout_stream()
    assert(proc:start())
    local content = ""
    while true do
        local chunk: unknown = stdout:read(65536)
        if type(chunk) ~= "string" or chunk == "" then break end
        content = content .. (chunk :: string)
    end
    proc:wait()
    stdout:close()
    executor:release()
    return content
end
local function real_adapter(): adapter.Adapter
    local entry = registry.get(ADAPTER)
    if not entry then error("adapter entry") end
    local decoded, err = adapter.decode(ADAPTER, (entry.data :: Object).adapter)
    if not decoded then error(tostring(err)) end
    return decoded
end
local function observations_of(content: string): {Object}
    local decoder = stream_json.new(65536)
    local state = protocol.new(false)
    local out: {Object} = {}
    for _, envelope in ipairs(stream_json.feed(decoder, content)) do
        local step = protocol.normalize(state, envelope.index, envelope.value)
        for _, observation in ipairs(step.observations) do out[#out + 1] = observation :: Object end
    end
    return out
end
local function define_tests()
    test.describe("Claude permission adapter", function()
        local pinned = real_adapter()
        test.it("is pinned by the Claude profiles at its measured digest", function()
            local snapshot = assert(catalog.snapshot())
            local found = false
            for _, binding in ipairs(snapshot.bindings) do
                if binding.binding_id == BINDING then
                    found = true
                    for _, profile in ipairs(binding.profiles) do
                        if not profile.permission.eligible or profile.permission.adapter_ref ~= ADAPTER then
                            error("profile " .. profile.id .. " does not pin " .. ADAPTER .. " at digest " .. pinned.digest .. ": " .. table.concat(binding.diagnostics, "; "))
                        end
                        test.eq(profile.permission.proof_fixture, "control")
                    end
                end
            end
            test.is_true(found)
        end)
        test.it("recognizes the captured control request and acknowledges through the tool use id", function()
            local observations = observations_of(read_file(capture_path()))
            local request: adapter.Request? = nil
            local request_index = 0
            for index, observation in ipairs(observations) do
                if not request then
                    local found, err = adapter.request(pinned, observation)
                    if err then error(err) end
                    if found then request, request_index = found, index end
                end
            end
            if not request then error("the capture has no permission request") end
            test.eq(request.tool_name, "Bash")
            test.eq(request.acknowledgment_id, "toolu_bee_1")
            test.neq(request.correlation_id, request.acknowledgment_id)
            test.eq(request.prompt, "leave a marker")
            test.eq((request.input :: Object).command, "touch proof.txt")
            local echo = 0
            for index = request_index + 1, #observations do
                if adapter.acknowledged(pinned, request, observations[index]) then echo = index break end
            end
            test.is_true(echo > request_index)
            test.eq((observations[echo].data :: Object).call_id, "toolu_bee_1")
            local consistent, err = adapter.transcript_consistent(pinned, observations, request_index)
            if not consistent then error(tostring(err)) end
            local denial = events.tool_result("probe", "toolu_bee_1", "failed", "decision denied", events.fault("tool_error", "decision denied", false))
            test.is_true(adapter.deny_acknowledged(pinned, request, denial))
            local other = events.tool_result("probe", "toolu_other", "failed", "decision denied", events.fault("tool_error", "decision denied", false))
            test.is_false(adapter.deny_acknowledged(pinned, request, other))
            test.is_false(adapter.deny_acknowledged(pinned, request, observations[echo]))
            local allow = assert(adapter.allow(pinned, request, nil))
            local decoded = json.decode(allow) :: Object
            test.eq(decoded.type, "control_response")
            local response = decoded.response :: Object
            test.eq(response.subtype, "success")
            test.eq(response.request_id, request.correlation_id)
            test.eq((response.response :: Object).behavior, "allow")
            local deny = json.decode(assert(adapter.deny(pinned, request, "decision denied"))) :: Object
            local denied = (deny.response :: Object).response :: Object
            test.eq(denied.behavior, "deny")
            test.eq(denied.message, "decision denied")
        end)
    end)
end
return test.run_cases(define_tests)
