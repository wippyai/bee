-- Typed, bounded commands accepted by the desktop session.
--
-- The session is a process boundary.  Keep all coercion and admission here so
-- that its reducer only receives a finite command vocabulary with normalized
-- integer geometry and validated appearance values.
local appearance = require("appearance")
local contract = require("contract")

local M = {}

local MAX_REQUEST_ID = 80
local MAX_ID = 160
local MAX_INSTANCE_ID = 160
local MAX_TITLE = 240
local MAX_APPEARANCE_VALUE = 80
local MAX_COORDINATE = 2147483647

type Header = {version: integer, request_id: string?}
type Screen = Header & {op: "screen", width: integer, height: integer}
type Add = Header & {op: "add", id: string, instance_id: string, workspace_id: string?, title: string, icon: string}
type Focus = Header & {op: "focus", id: string}
type Fullscreen = Header & {op: "fullscreen", id: string}
type Maximize = Header & {op: "maximize", id: string}
type Minimize = Header & {op: "minimize", id: string}
type Collapse = Header & {op: "collapse", id: string}
type Restore = Header & {op: "restore", id: string}
type Remove = Header & {op: "remove", id: string}
type Snap = Header & {op: "snap", id: string, side: "left" | "right"}
type Place = Header & {op: "place", id: string, x: integer, y: integer, width: integer, height: integer}
type Announce = Header & {op: "announce", id: string, instance_id: string, title: string}
type Personalize = Header & {op: "personalize", id: string, user_title: string, accent: string}
type Appearance = Header & {op: "appearance", theme: string, background: string,
    taskbar: "icons" | "labels", expected_revision: integer?}
type Snapshot = Header & {op: "snapshot"}
type Shutdown = Header & {op: "shutdown"}
type Command = Screen | Add | Focus | Fullscreen | Maximize | Minimize | Collapse | Restore | Remove
    | Snap | Place | Announce | Personalize | Appearance | Snapshot | Shutdown

local function integer(value: unknown, minimum: integer, maximum: integer): integer?
    if type(value) ~= "number" or value ~= value or value ~= math.floor(value) then return nil end
    if value < minimum or value > maximum then return nil end
    return math.floor(value)
end

local function text(value: unknown, maximum: integer, required: boolean): string?
    if type(value) ~= "string" or #value > maximum or value:find("%c") then return nil end
    if required and #value == 0 then return nil end
    return value
end

local function accent(value: unknown): string?
    if value == "" or value == "amber" or value == "cyan" or value == "green"
        or value == "rose" or value == "violet" then
        return value
    end
    return nil
end

local function header(value: table): {version: integer, request_id: string?}?
    if value.version ~= 1 then return nil end
    local request_id: string? = nil
    if value.request_id ~= nil then
        request_id = text(value.request_id, MAX_REQUEST_ID, false)
        if request_id == nil then return nil end
    end
    return {version = 1, request_id = request_id}
end

function M.decode(value: unknown): Command?
    if type(value) ~= "table" or type(value.op) ~= "string" then return nil end
    local base = header(value)
    if not base then return nil end

    if value.op == "screen" then
        local width = integer(value.width, 1, MAX_COORDINATE)
        local height = integer(value.height, 1, MAX_COORDINATE)
        if not width or not height then return nil end
        return {version = base.version, request_id = base.request_id, op = "screen", width = width, height = height}
    elseif value.op == "add" then
        local id = text(value.id, MAX_ID, true)
        local instance_id = text(value.instance_id, MAX_INSTANCE_ID, true)
        local workspace_id = contract.workspace_id(value.workspace_id)
        if value.workspace_id ~= nil and not workspace_id then return nil end
        local title = text(value.title, MAX_TITLE, false)
        local icon = value.icon == nil and "" or text(value.icon, 8, false)
        if not icon then return nil end
        if not id or not instance_id or not title then return nil end
        return {version = base.version, request_id = base.request_id, op = "add", id = id,
            instance_id = instance_id, workspace_id = workspace_id, title = title, icon = icon}
    elseif value.op == "focus" or value.op == "fullscreen" or value.op == "maximize" or value.op == "minimize"
        or value.op == "collapse" or value.op == "restore" or value.op == "remove" then
        local id = text(value.id, MAX_ID, value.op ~= "focus")
        if not id then return nil end
        if value.op == "focus" then return {version = base.version, request_id = base.request_id, op = "focus", id = id} end
        if value.op == "fullscreen" then return {version = base.version, request_id = base.request_id, op = "fullscreen", id = id} end
        if value.op == "maximize" then return {version = base.version, request_id = base.request_id, op = "maximize", id = id} end
        if value.op == "minimize" then return {version = base.version, request_id = base.request_id, op = "minimize", id = id} end
        if value.op == "collapse" then return {version = base.version, request_id = base.request_id, op = "collapse", id = id} end
        if value.op == "restore" then return {version = base.version, request_id = base.request_id, op = "restore", id = id} end
        return {version = base.version, request_id = base.request_id, op = "remove", id = id}
    elseif value.op == "snap" then
        local id = text(value.id, MAX_ID, true)
        if not id then return nil end
        local side: "left" | "right"
        if value.side == "left" then side = "left"
        elseif value.side == "right" then side = "right"
        else return nil end
        return {version = base.version, request_id = base.request_id, op = "snap", id = id, side = side}
    elseif value.op == "place" then
        local id = text(value.id, MAX_ID, true)
        local x = integer(value.x, -MAX_COORDINATE, MAX_COORDINATE)
        local y = integer(value.y, -MAX_COORDINATE, MAX_COORDINATE)
        local width = integer(value.width, 1, MAX_COORDINATE)
        local height = integer(value.height, 1, MAX_COORDINATE)
        if not id or not x or not y or not width or not height then return nil end
        return {version = base.version, request_id = base.request_id, op = "place", id = id, x = x, y = y,
            width = width, height = height}
    elseif value.op == "announce" then
        local id = text(value.id, MAX_ID, true)
        local instance_id = text(value.instance_id, MAX_INSTANCE_ID, true)
        local title = text(value.title, 80, true)
        if not id or not instance_id or not title then return nil end
        return {version = base.version, request_id = base.request_id, op = "announce", id = id,
            instance_id = instance_id, title = title}
    elseif value.op == "personalize" then
        local id = text(value.id, MAX_ID, true)
        local user_title = text(value.user_title, MAX_APPEARANCE_VALUE, false)
        local selected_accent = accent(value.accent)
        if not id or not user_title or selected_accent == nil then return nil end
        return {version = base.version, request_id = base.request_id, op = "personalize", id = id,
            user_title = user_title, accent = selected_accent}
    elseif value.op == "appearance" then
        local theme = text(value.theme, MAX_APPEARANCE_VALUE, true)
        local background = text(value.background, MAX_APPEARANCE_VALUE, true)
        local expected_revision: integer? = nil
        if value.expected_revision ~= nil then
            expected_revision = integer(value.expected_revision, 0, MAX_COORDINATE)
            if not expected_revision then return nil end
        end
        if not theme or not background then return nil end
        if not appearance.decode({theme = theme, background = background, taskbar = value.taskbar}) then return nil end
        return {version = base.version, request_id = base.request_id, op = "appearance", theme = theme,
            background = background, taskbar = value.taskbar == "icons" and "icons" or "labels", expected_revision = expected_revision}
    elseif value.op == "snapshot" then
        return {version = base.version, request_id = base.request_id, op = "snapshot"}
    elseif value.op == "shutdown" then
        return {version = base.version, request_id = base.request_id, op = "shutdown"}
    end
    return nil
end

return M
