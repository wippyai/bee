-- MIT. Runs one preparer cleanup in its own process and reports the outcome.
local process = require("process")
local workdir_preparers = require("workdir_preparers")
local types = require("types")
return {main = function(attempt: types.Attempt, reporter: string)
    local ok, err = workdir_preparers.cleanup(attempt)
    process.send(reporter, "bee.test.cleanup.result", {ok = ok, err = err})
end}
