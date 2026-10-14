-- MIT. The session owner supplies the terminal grant; the admitted placement
-- binding selects the window constructor, as in the Sessions app.
local runtime = require("runtime")
local windows = require("windows")
return {main = function(value: unknown, operation_key: string)
    return runtime.main(value, windows.constructors(), true, operation_key)
end}
