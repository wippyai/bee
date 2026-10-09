-- SPDX-License-Identifier: MIT
local channel = require("channel")
local function run(_ref: string, _digest: string, _network: string, _workspace: string, _recipient: string?, _cancel: channel.Channel<boolean>, _revoke: boolean): (string?, string?)
    return nil, "unused fixture operation"
end
return {run = run}
