local process = require("process")
local json = require("json")
local model = require("model")
local client = require("client")
local function main(owner: string, thread: string, run: string)
    local function encode(value: unknown): string
        local text, err = json.encode(value)
        if not text then error(tostring(err)) end
        return text
    end
    local function emit(key: string, kind: string, body: string)
        local reply = client.call(owner, "append", thread, run .. "/" .. key, kind, body, 0)
        assert(reply.error == "", reply.error)
        local retry = client.call(owner, "append", thread, run .. "/" .. key, kind, body, 0)
        assert(retry.error == "" and retry.seq == reply.seq, "Retry duplicated an event")
        local conflict = client.call(owner, "append", thread, run .. "/" .. key, kind, "{}", 0)
        assert(conflict.error ~= "", "Conflicting retry accepted")
    end
    emit("start", "test.run.started", '{"run":' .. encode(run) .. '}')
    local scene = model.new(80, 24)
    assert(scene.width == 80 and scene.height == 24 and #scene.windows == 0)
    emit("empty", "test.case.passed", '{"run":' .. encode(run) .. ',"name":"empty scene"}')
    local tiny = model.new(0, 0)
    assert(tiny.width >= 1 and tiny.height >= 1)
    emit("tiny", "test.case.passed", '{"run":' .. encode(run) .. ',"name":"minimum screen bounds"}')
    emit("finish", "test.run.finished", '{"run":' .. encode(run) .. ',"passed":2}')
    assert(process.send(owner, "bee.thread_demo.request", {version = 1, op = "producer_done", thread = thread}))
end
return {main = main}
