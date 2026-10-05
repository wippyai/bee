-- SPDX-License-Identifier: MIT
local security = require("security")
return {check = function(): boolean
    return security.can("funcs.call", "bee.gov.binding:driver_bindings")
end}
