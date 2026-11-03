-- MIT. The shared driver methods a binding names when its descriptor says
-- everything about the CLI. Each request names that descriptor.
local universal = require("universal")
return {
    prepare = universal.prepare,
    dispatch = universal.dispatch,
    normalize = universal.normalize,
    configure = universal.plain_configure,
    locate = universal.locate,
}
