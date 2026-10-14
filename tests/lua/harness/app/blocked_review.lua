local process = require("process")
local function main(): {[string]: unknown}
    local release = assert(process.listen("bee.test.review_release", {message = true}))
    local observer = assert(process.registry.lookup("bee.test.blocked_review"))
    assert(process.send(observer, "bee.test.review_blocked", {}))
    release:receive()
    return {ok = true, value = {request = false}}
end
return {main = main}
