-- SPDX-License-Identifier: MIT
local process = require("process")
local channel = require("channel")
local M = {}
M.OWNER = "bee.test.docker.owner"
M.REQUEST = "bee.test.docker.request"
M.REPLY = "bee.test.docker.reply"
type Profile = {ref: string, digest: string, profile: {network: string}}
function M.authorized_request(_id: string, sender: string): (Profile?, string?, string?, string?, string?)
    return {ref = "fixture", digest = string.rep("0", 64), profile = {network = "none"}}, nil, sender, nil, nil
end
function M.build(_profile: Profile, recipient: string?, cancel: channel.Channel<boolean>): (string?, string?, string?)
    local releases = assert(process.listen("bee.test.docker.release", {message = true}))
    assert(process.send(assert(recipient), "bee.test.docker.blocked", {}))
    local selected = channel.select({releases:case_receive(), cancel:case_receive()})
    process.unlisten(releases)
    if selected.channel == cancel then return nil, nil, "cancelled" end
    return "sha256:" .. string.rep("0", 64), "fixture:route", nil
end
return M
