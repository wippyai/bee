-- MIT. Placement method measure_executable: a read-only measurement of one host path.
local operations = require("operations")
local function handle(request: unknown): operations.Reply
    return operations.measure_executable(request)
end
return {handle = handle}
