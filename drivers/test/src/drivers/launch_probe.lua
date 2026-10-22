-- Launches one driver under the caller's scope and reports the outcome, so a
-- test can run the library with exactly a host's grant.
local drivers = require("drivers")
local placements = require("placements")

local function run(driver_id: string): {[string]: any}
    local list, list_err = drivers.list()
    if not list then return {ok = false, error = "list: " .. tostring(list_err)} end
    local launch, err = drivers.launch(driver_id, {brief = "x", home = "/home/node", placement = placements.DOCKER, unattended = true})
    if not launch then return {ok = false, error = tostring(err)} end
    local reader, reader_err = drivers.reader(driver_id, false)
    if not reader then return {ok = false, error = "reader: " .. tostring(reader_err)} end
    return {ok = true, executable = launch.executable, drivers = #list}
end

return {run = run}
