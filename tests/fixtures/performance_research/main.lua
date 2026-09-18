-- SPDX-License-Identifier: MIT
local funcs = require("funcs")
local channel = require("channel")
local time = require("time")
local json = require("json")
local io = require("io")
local process = require("process")

type Channel = channel.Channel
type Message = process.Message
type Object = {[string]: unknown}

local function progress_for(progress: Channel<Message>, run_id: string, timeout: string): Object?
    local deadline = time.after(timeout)
    while true do
        local selected = channel.select({progress:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then return nil end
        local message = selected.value
        local data: unknown = message:payload():data()
        if type(data) == "table" and data.run_id == run_id then
            local value = data :: Object
            assert(type(value.worker) == "string" and tostring(message:from()) == value.worker,
                "spin progress sender did not match its worker")
            assert(type(value.chunk) == "number" and value.chunk == math.floor(value.chunk),
                "spin progress did not carry an integer chunk")
            return value
        end
    end
end

local function continue(worker: string, run_id: string, chunk: integer)
    local sent, send_error = process.send(worker, "research.spin.continue", {run_id = run_id, chunk = chunk})
    if not sent then error("Could not continue spin worker: " .. tostring(send_error)) end
end

local function main()
    local progress = assert(process.listen("research.spin.progress", {message = true}))
    local caller = tostring(process.pid())

    -- Keep the original non-yielding CPU smoke distinct from the cooperative
    -- progress proof below. It only proves that all three workers start and
    -- that the caller can request cancellation while they are spinning.
    local started = assert(process.listen("research.spin.started", {message = true}))
    for _ = 1, 3 do
        local spinning, spin_error = funcs.async("bee.research_benchmark_probe:cpu_spin", caller)
        if not spinning then error(tostring(spin_error)) end
        local ready_timeout = time.after("1s")
        local ready = channel.select({started:case_receive(), ready_timeout:case_receive()})
        if not ready.ok or ready.channel == ready_timeout then
            spinning:cancel()
            error("non-yielding CPU probe did not start")
        end
        io.print("RESEARCH_SPIN_CPU_STARTED")
        time.sleep("30ms")
        spinning:cancel()
    end
    process.unlisten(started)

    -- A finite worker must complete four separately observed CPU chunks when
    -- its caller grants each continuation. This is the uncanceled control.
    local control_id = caller .. ":control"
    local control, control_error = funcs.async("bee.research_benchmark_probe:spin", caller, control_id, 4)
    if not control then error(tostring(control_error)) end
    local control_response = control:response()
    local control_worker = ""
    for chunk = 1, 4 do
        local update = progress_for(progress, control_id, "1s")
        if not update then error("uncanceled control did not report four chunks") end
        if update.chunk ~= chunk then error("uncanceled control skipped or reordered a chunk") end
        local worker = update.worker :: string
        if control_worker == "" then control_worker = worker
        elseif control_worker ~= worker then error("uncanceled control changed worker identity") end
        if chunk < 4 then continue(worker, control_id, chunk) end
    end
    local control_deadline = time.after("1s")
    local control_done = channel.select({control_response:case_receive(), control_deadline:case_receive()})
    if not control_done.ok or control_done.channel == control_deadline then error("uncanceled control did not complete") end
    local control_result, control_result_error = control:result()
    if not control_result then error("uncanceled control failed: " .. tostring(control_result_error)) end
    if control_result:data() ~= 4 then error("uncanceled control returned the wrong chunk count") end
    io.print("RESEARCH_SPIN_CONTROL chunks=4")

    -- This is cooperative checkpoint cancellation: the worker waits for a
    -- caller continuation between CPU chunks and also watches CANCEL events.
    -- Cancel after its first chunk, allow the event to be handled, then send
    -- the continuation it would need to produce a second chunk.
    local cancel_id = caller .. ":cancel"
    local spinning, spin_error = funcs.async("bee.research_benchmark_probe:spin", caller, cancel_id, 0)
    if not spinning then error(tostring(spin_error)) end
    local first = progress_for(progress, cancel_id, "1s")
    if not first or first.chunk ~= 1 then spinning:cancel(); error("cancel probe did not report its first chunk") end
    local canceled_worker = first.worker :: string
    spinning:cancel()

    -- The bounded wait gives the worker a chance to process cancellation. If
    -- it remains alive at its cooperative checkpoint, this late signal makes
    -- it emit another message on the same progress route.
    time.sleep("50ms")
    process.send(canceled_worker, "research.spin.continue", {run_id = cancel_id, chunk = 1})
    local drain = time.after("300ms")
    while true do
        local selected = channel.select({progress:case_receive(), drain:case_receive()})
        if not selected.ok then error("spin progress subscription closed during drain") end
        if selected.channel == drain then break end
        local message = selected.value
        local data: unknown = message:payload():data()
        if type(data) == "table" and data.run_id == cancel_id then
            error("canceled worker emitted progress after its bounded cancellation drain")
        end
    end
    process.unlisten(progress)
    io.print("RESEARCH_SPIN_COOPERATIVE_CANCELLED chunks=1")

    -- Normal work after cancellation proves the caller and runtime remain live.
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
