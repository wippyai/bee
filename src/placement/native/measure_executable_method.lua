-- MIT. Placement method measure_executable: a read-only measurement of one host path.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.measure_executable(request)
end
return {handle = handle}
