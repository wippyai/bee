-- MIT. Test support: the publication runner reports its filesystem fixture counters.
local homes = require("homes")
return {snapshot = function(): {[string]: unknown}
    return {publications = homes.publications, creations = homes.creations}
end}
