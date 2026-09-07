-- Normalize the channel boundary to the runtime's typed input contract.
local tty = require("tty")
local M = {}
local function coordinate(value: unknown): integer?
    if type(value) ~= "number" or value ~= value or value < 1 or value > 2147483647
        or value ~= math.floor(value) then return nil end
    return math.floor(value)
end
function M.decode(value: unknown): tty.InputEvent?
    if type(value) ~= "table" then return nil end
    if value.ctrl ~= nil and type(value.ctrl) ~= "boolean" then return nil end
    if value.alt ~= nil and type(value.alt) ~= "boolean" then return nil end
    if value.shift ~= nil and type(value.shift) ~= "boolean" then return nil end
    if value.type == "key" then
        if type(value.key) ~= "string" or type(value.key_type) ~= "string"
            or (value.action ~= "press" and value.action ~= "release") then return nil end
        return {type = "key", key = value.key, key_type = value.key_type, action = value.action == "release" and "release" or "press",
            ctrl = value.ctrl == true, alt = value.alt == true, shift = value.shift == true}
    elseif value.type == "mouse" then
        local x, y = coordinate(value.x), coordinate(value.y)
        if not x or not y or type(value.button) ~= "string"
            or (value.action ~= "press" and value.action ~= "release" and value.action ~= "motion" and value.action ~= "wheel") then return nil end
        return {type = "mouse", x = x, y = y, button = value.button,
            action = value.action == "release" and "release" or (value.action == "motion" and "motion" or (value.action == "wheel" and "wheel" or "press")),
            ctrl = value.ctrl == true, alt = value.alt == true, shift = value.shift == true}
    elseif value.type == "start" or value.type == "resize" then
        local width, height = coordinate(value.width), coordinate(value.height)
        if not width or not height then return nil end
        if value.type == "start" then return {type = "start", width = width, height = height} end
        return {type = "resize", width = width, height = height}
    elseif value.type == "paste" and type(value.text) == "string" then
        return {type = "paste", text = value.text}
    elseif value.type == "focus" and type(value.focused) == "boolean" then
        return {type = "focus", focused = value.focused}
    elseif value.type == "visibility" and type(value.visible) == "boolean" then
        return {type = "visibility", visible = value.visible}
    elseif value.type == "close" then return {type = "close"} end
    return nil
end
return M
