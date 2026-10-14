-- MIT. The session owner supplies the terminal grant; the admitted placement
-- binding selects the window constructor, as in the Agents app.
local runtime = require("runtime")
local windows = require("windows")
local admission = require("admission")
return {main = function(value: unknown, operation_key: string, admitted: admission.Admitted?)
    return runtime.main(value, windows.constructors(), true, operation_key, admitted)
end}
