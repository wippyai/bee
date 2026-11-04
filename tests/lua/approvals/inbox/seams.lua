-- SPDX-License-Identifier: MIT
-- A window spawned with the ctx key bee.test.inbox.review holds its first
-- detail draw for that controller and reports each decision to it. A window
-- spawned with bee.test.settings.area offers that one area in the edit form.
local ctx = require("ctx")
local process = require("process")
local held = false
return {
    ["bee.approvals.inbox.app.draw"] = function(payload: unknown?): unknown
        local controller = ctx.get("bee.test.inbox.review")
        if held or type(controller) ~= "string" or type(payload) ~= "table" or payload.detail ~= true then return nil end
        held = true
        return {controller = controller, report = "bee.test.inbox.review", release = "bee.test.inbox.display", payload = {}}
    end,
    ["bee.approvals.inbox.app.act"] = function(payload: unknown?): unknown
        local controller = ctx.get("bee.test.inbox.review")
        if type(controller) == "string" then assert(process.send(controller, "bee.test.inbox.decide", payload)) end
        return nil
    end,
    ["bee.apps.settings.app.edit_areas"] = function(): unknown
        local area = ctx.get("bee.test.settings.area")
        if type(area) ~= "string" then return nil end
        return {{id = area, title = "Test area"}}
    end,
}
