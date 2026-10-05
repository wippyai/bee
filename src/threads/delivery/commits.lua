-- MIT. The event that announces a commit on a thread. The Threads service
-- sends it for every record the store commits; a wait subscribes to the
-- threads it waits on, so it hears no other thread's commits.
local channel = require("channel")
local time = require("time")
local events = require("events")
local M = {}
M.KIND = "committed"
M.MAX_WAIT_MS = 60000
M.BUDGET_MARGIN_MS = 1000
function M.system(thread_id: string): string
    return "bee.threads/" .. thread_id
end
-- Effective wait: the request, the 60 s ceiling, and the transport budget
-- minus a margin. A caller can only shorten its budget.
function M.effective_wait(wait_ms: integer, budget_ms: integer?): integer
    local effective = math.min(wait_ms, M.MAX_WAIT_MS)
    if budget_ms then effective = math.min(effective, math.max(0, budget_ms - M.BUDGET_MARGIN_MS)) end
    return math.floor(effective)
end
local function now_ms(): integer
    return math.floor(time.now():unix_nano() / 1000000)
end
-- await runs check until pending reports false: once after subscribing to
-- the commits of every thread, again after each commit, and finally at the
-- deadline. The subscriptions precede the first check, so a commit between a
-- caller's earlier read and this call is seen. An event is a hint; check
-- decides. A failed subscription is returned through failed.
function M.await<T>(thread_ids: {string}, wait_ms: integer, pending: (T) -> boolean, check: (boolean) -> T,
    failed: (string) -> T): T
    local deadline_at = now_ms() + wait_ms
    local subscriptions = {}
    local function close()
        for _, subscription in ipairs(subscriptions) do subscription:close() end
    end
    for _, thread_id in ipairs(thread_ids) do
        local subscription, subscribe_err = events.subscribe(M.system(thread_id), M.KIND)
        if not subscription then
            close()
            return failed("subscribe to commits: " .. tostring(subscribe_err))
        end
        subscriptions[#subscriptions + 1] = subscription
    end
    local outcome = check(false)
    while pending(outcome) do
        local remaining = deadline_at - now_ms()
        if remaining <= 0 then
            outcome = check(true)
            break
        end
        local timer = time.after(tostring(remaining) .. "ms")
        local selected_cases = {timer:case_receive()}
        for _, subscription in ipairs(subscriptions) do selected_cases[#selected_cases + 1] = subscription:channel():case_receive() end
        local selected = channel.select(selected_cases)
        if selected.channel ~= timer then
            if not selected.ok then
                outcome = failed("commit subscription closed")
                break
            end
            outcome = check(false)
        end
    end
    close()
    return outcome
end
return M
