-- MIT. The session owner supplies the native terminal grant.
local runtime = require("runtime")
local window = require("window")
return {main = function(value: unknown, operation_key: string)
    return runtime.main(value, {["bee.placement.native.binding:binding"] = window.open}, true, operation_key)
end}
