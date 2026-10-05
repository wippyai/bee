-- MIT. Deterministic correctness and timing inputs for the canonical encoder
-- performance experiment. This fixture has no runtime dependencies.
local M = {}

type Encode = (unknown) -> (string?, string?)
type Case = {name: string, value: unknown, encoded: string?, encode_error: string?}

local function verify(encode: Encode, name: string, value: unknown, expected: string?, expected_error: string?): string?
    local called, actual, actual_error = pcall(function() return encode(value) end)
    if not called then return name .. " raised " .. tostring(actual) end
    if actual ~= expected then
        return name .. " encoded as " .. tostring(actual) .. ", expected " .. tostring(expected)
    end
    if actual_error ~= expected_error then
        return name .. " returned error " .. tostring(actual_error) .. ", expected " .. tostring(expected_error)
    end
    return nil
end

local function nested_arrays(count: integer): unknown
    local value: unknown = 0
    for _ = 1, count do value = {value} end
    return value
end

function M.check(encode: Encode): (boolean, string?)
    local sparse: unknown = {[1] = "first", [3] = "third"}
    local mixed: {[string | number]: unknown} = {[1] = "first", name = "object"}
    local boolean_key: unknown = {[false] = "value"}
    local fractional_key: unknown = {[1.5] = "value"}
    local zero_key: unknown = {[0] = "value"}
    local cycle: {[string]: unknown} = {}
    cycle.self = cycle

    local cases: {Case} = {
        {name = "true", value = true, encoded = "true", encode_error = nil},
        {name = "false", value = false, encoded = "false", encode_error = nil},
        {name = "unicode", value = "snowman ☃, café, 日本語", encoded = '"snowman ☃, café, 日本語"', encode_error = nil},
        {name = "control characters", value = string.char(0, 8, 9, 10, 12, 13, 31, 127),
            encoded = '"\\u0000\\u0008\\u0009\\u000a\\u000c\\u000d\\u001f\\u007f"', encode_error = nil},
        {name = "quotes and slash", value = 'say "hello" \\ safely', encoded = '"say \\"hello\\" \\\\ safely"', encode_error = nil},
        {name = "integer formats", value = {0, -7, 9007199254740991, 9007199254740992},
            encoded = "[0,-7,9007199254740991,9007199254740992]", encode_error = nil},
        {name = "fractional formats", value = {1.25, 0.1, 1e20, 1e-7},
            encoded = "[1.25,0.10000000000000001,1e+20,9.9999999999999995e-08]", encode_error = nil},
        {name = "nested values", value = {{z = 1, a = "x"}, {b = {true, false}}},
            encoded = '[{"a":"x","z":1},{"b":[true,false]}]', encode_error = nil},
        {name = "sorted object keys", value = {z = 1, alpha = 2, middle = 3},
            encoded = '{"alpha":2,"middle":3,"z":1}', encode_error = nil},
        {name = "empty table", value = {}, encoded = "{}", encode_error = nil},
        {name = "sparse array", value = sparse, encoded = nil, encode_error = "list is not dense"},
        {name = "mixed keys", value = mixed, encoded = nil, encode_error = "table mixes list and object keys"},
        {name = "boolean key", value = boolean_key, encoded = nil, encode_error = "table key is not encodable"},
        {name = "fractional key", value = fractional_key, encoded = nil, encode_error = "table key is not encodable"},
        {name = "zero key", value = zero_key, encoded = nil, encode_error = "table key is not encodable"},
        {name = "NaN", value = 0 / 0, encoded = nil, encode_error = "number is not finite"},
        {name = "positive infinity", value = math.huge, encoded = nil, encode_error = "number is not finite"},
        {name = "negative infinity", value = -math.huge, encoded = nil, encode_error = "number is not finite"},
        {name = "unsupported value", value = function() end, encoded = nil, encode_error = "value is not encodable"},
        {name = "maximum depth", value = nested_arrays(31), encoded = string.rep("[", 31) .. "0" .. string.rep("]", 31), encode_error = nil},
        {name = "depth overflow", value = nested_arrays(32), encoded = nil, encode_error = "value nests deeper than 32"},
        {name = "cycle", value = cycle, encoded = nil, encode_error = "value nests deeper than 32"},
    }

    local ok, nil_error = pcall(function()
        local failure = verify(encode, "nil", nil, "null", nil)
        if failure then error(failure) end
    end)
    if not ok then return false, tostring(nil_error) end

    for _, item in ipairs(cases) do
        local failure = verify(encode, item.name, item.value, item.encoded, item.encode_error)
        if failure then return false, failure end
    end
    return true, nil
end

function M.benchmark_values(): {unknown}
    return {
        {schema_revision = "bee.thread-record@1", kind = "message", thread_id = "thread-performance",
            sequence = 42, body = {message_id = "message-performance", message_kind = "request",
                sender_id = "research", recipient_ids = {"worker-a", "worker-b"},
                content = {text = "Summarize the latest run ☃ and preserve its exact inputs."}}},
        {events = {{type = "text", operation = "append", text = "first segment"},
            {type = "tool.call", call_id = "call-2", tool_name = "search", input = {query = "canonical JSON"}},
            {type = "tool.result", call_id = "call-2", outcome = "succeeded", output = {count = 12}}},
            metadata = {attempt = 3, elapsed_seconds = 0.125, successful = true}},
        {keys = {zeta = {enabled = false, weight = 0.1}, alpha = {enabled = true, weight = 1.25}},
            labels = {"latency", "allocation", "correctness"}, note = "nested object and list"},
        {limits = {max_depth = 32, retries = 0, large_integer = 9007199254740991},
            ratios = {1 / 3, 0.1, 1e20, -1e-7}, payload = string.rep("bee-performance-", 32)},
    }
end

return M
