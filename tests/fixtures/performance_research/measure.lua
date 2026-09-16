-- SPDX-License-Identifier: MIT
local time = require("time")
local corpus = require("corpus")
local function run(encode: (unknown) -> (string?, string?)): {[string]: unknown}
    local correct, correctness_error = corpus.check(encode)
    local values = corpus.benchmark_values()
    local samples: {number} = {}
    local checksum = 0
    local iterations = 200
    for sample = 1, 7 do
        local started = time.now():unix_nano()
        for iteration = 1, iterations do
            for _, value in ipairs(values) do
                local encoded, encode_error = encode(value)
                if not encoded then error(tostring(encode_error)) end
                checksum = checksum + #encoded
            end
        end
        samples[sample] = (time.now():unix_nano() - started) / (iterations * #values)
    end
    return {schema = "bee.research.measurement@1", benchmark = "canonical-json@1",
        units = "ns/op", samples = samples, iterations = iterations, corpus_size = #values,
        checksum = checksum, correct = correct, correctness_error = correctness_error,
        outcome = correct and "passed" or "invalid"}
end
return {run = run}
