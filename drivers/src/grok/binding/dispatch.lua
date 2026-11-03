-- MIT. Grok dispatches through the shared method and adds its ACP launch.
local universal = require("universal")
local acp = require("acp")
return {handle = function(raw: unknown): unknown return acp.launch(raw, universal.dispatch) end}
