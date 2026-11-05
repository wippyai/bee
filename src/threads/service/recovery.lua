-- MIT. Durable recovery of thread commits and the store access it shares with
-- the Threads service.
local logger = require("logger")

-- Store is how recovery reaches the thread store: open a handle, settle the
-- notices watching a thread, and announce a recovered head.
type Store = {
    open: () -> (any, string?),
    fire: (any, string) -> string?,
    announce: (string, number) -> nil,
}

local M = {}

-- with_store runs action on an opened handle and releases it afterwards.
function M.with_store(open: () -> (any, string?), action: (any) -> ())
    local db, err = open()
    if not db then
        logger:warn("Threads store unavailable", {error = err})
        return
    end
    local handled, problem = pcall(action, db)
    db:release()
    if not handled then error(problem) end
end

-- CDC is a bounded live feed. Reopening it precedes this durable scan so
-- commits during the scan remain observable. Each captured head is announced
-- only after its notices settle, including records lost with an old stream.
function M.recover(active: () -> boolean, store: Store): boolean
    if not active() then return false end
    M.with_store(store.open, function(db: any)
        local cursor = ""
        while active() do
            local heads, read_error = db:query([[SELECT thread_id, head_sequence FROM bee_thread_heads
                WHERE thread_id > ? ORDER BY thread_id LIMIT 128]], {cursor})
            if not active() then return end
            if not heads then error("read committed thread heads: " .. tostring(read_error)) end
            for _, head in ipairs(heads) do
                if not active() then return end
                local thread_id = tostring(head.thread_id)
                local problem = store.fire(db, thread_id)
                if not active() then return end
                if problem then error("settle recovered thread commits: " .. problem) end
                local sequence = assert(tonumber(head.head_sequence))
                if sequence > 0 then store.announce(thread_id, sequence) end
                cursor = thread_id
            end
            if #heads < 128 then return end
        end
    end)
    return active()
end

return M
