-- SPDX-License-Identifier: MIT
local pass = require("pass")
local service = require("service")
local function pending(): boolean return pass.pending() or service.following_pending() end
return {pending = pending}
