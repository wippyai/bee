-- SPDX-License-Identifier: MIT
local display = require("display")
local delivery = require("delivery")
local M = {}
function M.session_id(_handle: unknown): string? return "viewer-fixture" end
function M.content(_handle: unknown, _width: integer, _height: integer): (display.Content?, string?)
    return {rows = {"remote frame"}, cursor = nil}, nil
end
function M.close(_handle: unknown): (boolean, string?)
    delivery.close("viewer-fixture")
    return true, nil
end
return M
