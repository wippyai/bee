-- SPDX-License-Identifier: MIT
local universal = require("universal")
local acp = require("acp")
local prepare = universal.prepare("bee.drivers.grok.descriptor:cli")
return {handle = function(raw: unknown): unknown return acp.launch(raw, prepare) end}
