-- SPDX-License-Identifier: MIT
local worker = require("worker")
local service = require("service")
local process = require("process")
local bounds = require("bounds")
local store = require("store")
local preparers = require("workdir_preparers")
local function dispatch(caller: string, raw: unknown)
    local value = bounds.object(raw)
    local id = value and bounds.id(value.request_id)
    local attempt_id = value and bounds.id(value.attempt_id)
    local after = value and bounds.count(value.after)
    if not id or not attempt_id or not after then return end
    local db = assert(store.open())
    local requests = db:query("SELECT sequence FROM bee_placement_evidence WHERE attempt_id = ? AND kind = 'workdir_preparer.cleanup_requested' AND detail = ?",
        {attempt_id, id .. ": " .. tostring(after)})
    local attempt, err = store.attempt(db, attempt_id)
    db:release()
    local ok = false
    if not requests or #requests ~= 1 then err = "cleanup request is not recorded"
    elseif attempt then ok, err = preparers.execute_cleanup(attempt, after) end
    process.send(caller, "bee.placement.preparer.reply", {request_id = id, ok = ok, error = err})
end
local function main()
    worker.run({name = service.SWEEPER_NAME, demand = true, active = service.pending, dispatch = dispatch,
        every = tostring(service.SWEEP_INTERVAL_MS) .. "ms", pass = function(): boolean
            return service.sweep().ok
        end})
end
return {main = main}
