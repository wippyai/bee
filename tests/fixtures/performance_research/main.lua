-- SPDX-License-Identifier: MIT
local funcs = require("funcs")
local channel = require("channel")
local time = require("time")
local json = require("json")
local io = require("io")
local process = require("process")
local function main()
    -- Normal runtime shutdown after these cancellations is also checked by the
    -- external runner. A returned cancellation flag alone is insufficient.
    local started = process.listen("research.spin.started", {message = true})
    for index = 1, 3 do
        local spinning, spin_error = funcs.async("bee.research_benchmark_probe:spin", tostring(process.pid()))
        if not spinning then error(tostring(spin_error)) end
        local ready_timeout = time.after("1s")
        local ready = channel.select({started:case_receive(), ready_timeout:case_receive()})
        if ready.channel == ready_timeout then spinning:cancel(); error("CPU probe did not start") end
        io.print("RESEARCH_SPIN_STARTED")
        time.sleep("30ms")
        spinning:cancel()
    end
    process.unlisten(started)
    local pending, call_error = funcs.async("bee.research_benchmark_probe:benchmark")
    if not pending then error(tostring(call_error)) end
    local response = pending:response()
    local deadline = time.after("5s")
    local selected = channel.select({response:case_receive(), deadline:case_receive()})
    if selected.channel == deadline then pending:cancel(); error("benchmark exceeded five seconds") end
    local result, result_error = pending:result()
    if not result then error(tostring(result_error)) end
    local encoded, encode_error = json.encode(result:data())
    if not encoded then error(tostring(encode_error)) end
    io.print("RESEARCH_BASELINE " .. encoded)
end
return {main = main}
