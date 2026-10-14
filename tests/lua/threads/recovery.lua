-- SPDX-License-Identifier: MIT
local sql = require("runtime")
local database = sql
local notices = sql
local eventbus = sql
local logger = require("logger")
local commits = require("commits")
local function with_store(action: (sql.DB) -> ())
    local db, err = database.open()
    if not db then
        logger:warn("Threads store unavailable", {error = err})
        return
    end
    local handled, problem = pcall(action, db)
    db:release()
    if not handled then error(problem) end
end

local function recover_commits(active: () -> boolean): boolean
    if not active() then return false end
    with_store(function(db: sql.DB)
        local cursor = ""
        while active() do
            local heads, read_error = db:query([[SELECT thread_id, head_sequence FROM bee_thread_heads
                WHERE thread_id > ? ORDER BY thread_id LIMIT 128]], {cursor})
            if not active() then return end
            if not heads then error("read committed thread heads: " .. tostring(read_error)) end
            for _, head in ipairs(heads) do
                if not active() then return end
                local thread_id = tostring(head.thread_id)
                local problem = notices.fire(db, thread_id)
                if not active() then return end
                if problem then error("settle recovered thread commits: " .. problem) end
                local sequence = assert(tonumber(head.head_sequence))
                if sequence > 0 then
                    assert(eventbus.send(commits.system(thread_id), commits.KIND, thread_id, {sequence = sequence}))
                end
                cursor = thread_id
            end
            if #heads < 128 then return end
        end
    end)
    return active()
end

return {recover = recover_commits}
