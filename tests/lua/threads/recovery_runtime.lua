-- SPDX-License-Identifier: MIT
local process = require("process")
local M = {opened = 0, released = 0, reads = 0, settled = 0, announced = 0,
    cancelled = false, cancel_on_settle = false, query_error = false, settle_error = false}
M.controller = nil :: string?
type Head = {thread_id: string, head_sequence: integer}
type DB = {query: (DB, string, {string}) -> ({Head}?, string?), release: (DB) -> ()}
M.DB = DB
function M.reset()
    M.opened, M.released, M.reads, M.settled, M.announced = 0, 0, 0, 0, 0
    M.controller = nil
    M.cancelled, M.cancel_on_settle, M.query_error, M.settle_error = false, false, false, false
end
function M.active(): boolean return not M.cancelled end
function M.open(): (DB?, string?)
    M.opened = M.opened + 1
    return {
        query = function(_db: DB, _query: string, _args: {string}): ({Head}?, string?)
            M.reads = M.reads + 1
            if M.query_error then return nil, "injected read failure" end
            return {{thread_id = "first", head_sequence = 1}, {thread_id = "second", head_sequence = 2}}, nil
        end,
        release = function(_db: DB) M.released = M.released + 1 end,
    }, nil
end
function M.fire(_db: DB, _thread: string): string?
    M.settled = M.settled + 1
    if M.controller then
        local controller = M.controller
        M.controller = nil
        local resume = assert(process.listen("bee.test.recovery.resume", {message = true}))
        assert(process.send(controller, "bee.test.recovery.held", {}))
        assert((resume:receive()))
        process.unlisten(resume)
    end
    if M.cancel_on_settle then M.cancelled = true end
    if M.settle_error then return "injected settlement failure" end
    return nil
end
function M.send(_system: string, _kind: string, _path: string, _data: {sequence: number}): boolean
    M.announced = M.announced + 1
    return true
end
return M
