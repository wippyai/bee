-- MIT. Test-only carrier entry: the production run with a barrier that
-- stops the process after a named step, so recovery is proven from real
-- crash points. Excluded from packs.
local process = require("process")
local carrier = require("carrier_process")
local machine = require("machine")
-- crash_after ends the process at a step; pause_after holds it there until
-- the controller sends bee.carrier.continue, so a second carrier can act
-- in between. The controller hears bee.carrier.paused with the step name
-- once the process holds there.
local function main(request: unknown, mode: string, controller: string?, crash_after: string?, batch: number?, pause_after: string?): {[string]: unknown}
    local chosen: "open" | "resume" = "open"
    if mode == "resume" then chosen = "resume" end
    if batch and batch >= 1 then machine.MAX_RECORDS_PER_COMMIT = math.floor(batch) end
    local continues = assert(process.listen("bee.carrier.continue", {message = true}))
    local function after(step: string)
        if crash_after and step == crash_after then error("crash after " .. step) end
        if pause_after and step == pause_after then
            pause_after = nil
            if controller then process.send(controller, "bee.carrier.paused", step) end
            continues:receive()
        end
    end
    return carrier.run(request :: machine.Request, chosen, controller, after)
end
return {main = main}
