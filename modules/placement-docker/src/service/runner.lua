-- SPDX-License-Identifier: MIT
local runner = require("runner")
local execution = require("execution")
return {main = function(attempt_id: string, starter: string, reply_topic: string, gateway_binding: string?, materialization_key: string?, control_token: string)
    return runner.main(attempt_id, starter, reply_topic, gateway_binding, materialization_key, control_token, execution.backend())
end}
