local test = require("test")
local native_fixture = require("native_fixture")
local protocol = require("protocol")
local store = require("store")
local process = require("process")
local channel = require("channel")
local time = require("time")
local function cases()
    test.describe("Runtime native supervision", function()
        test.it("starts and observes exit without persisting a shell fingerprint", function()
            local request = native_fixture.launch({"sh", "-c", "echo READY; read line"}, "direct_process")
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            local exits = assert(process.listen(protocol.TOPIC_EXIT, {message = true}))
            native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1})
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
            local ok, problem = pcall(function()
                local deadline = time.after("10s")
                while true do
                    local event = channel.select({outputs:case_receive(), deadline:case_receive()})
                    assert(event.ok and event.channel == outputs, "child did not publish readiness")
                    local data = event.value:payload():data()
                    if type(data) == "table" then
                        assert(process.send(tostring(event.value:from()), protocol.TOPIC_ACK, {generation = 1, consumed_through = data.sequence}))
                        if tostring(data.data):find("READY", 1, true) then break end
                    end
                end
                local db = assert(store.open())
                local row = assert(store.row(db, prepared.attempt_id))
                db:release()
                assert(native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = prepared.attempt_id, mode = "forced"}).ok)
                local event = channel.select({exits:case_receive(), deadline:case_receive()})
                assert(event.ok and event.channel == exits, "runtime exit did not reach the session")
                local ended = native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id}))
                test.eq(ended.attempt.execution_state, "exited")
                test.eq(ended.attempt.exit_source, "runner")
                local eof = 0
                while eof < 2 do
                    local output = channel.select({outputs:case_receive(), deadline:case_receive()})
                    assert(output.ok and output.channel == outputs, "output did not finish")
                    local data = output.value:payload():data()
                    if type(data) == "table" then
                        if data.eof then eof = eof + 1 end
                        assert(process.send(tostring(output.value:from()), protocol.TOPIC_ACK, {generation = 1, consumed_through = data.sequence}))
                    end
                end
                test.is_nil(row.start_ticks, "runtime handle must replace /proc start-time probes")
                test.is_nil(row.boot_id, "runtime handle must replace boot-id fingerprints")
            end)
            native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = prepared.attempt_id, mode = "forced"})
            process.unlisten(outputs); process.unlisten(exits)
            if not ok then error(tostring(problem)) end
        end)
    end)
end
return {run = native_fixture.suite(cases)}
