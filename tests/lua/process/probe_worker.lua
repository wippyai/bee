-- MIT. A worker that reports each pass to the process that started it; its
-- second pass asks for a retry.
local process = require("process")
local worker = require("worker")
local function main(parent: string)
    local passes = 0
    worker.run({name = "bee.test.probe_worker", wake = "bee.test.probe_wake", pass = function(): boolean
        passes = passes + 1
        process.send(parent, "bee.test.probe_pass", passes)
        return passes ~= 2
    end})
    process.send(parent, "bee.test.probe_done", passes)
end
return {main = main}
