-- MIT. Display handover decoding and asynchronous result types.
local tty = require("tty")
local channel = require("channel")
local appearance = require("appearance")
local client = require("client")
local model = require("model")
local M = {}
type Binding = {ok: boolean, problem: string?}
-- generation is the connection a result belongs to; a result from an earlier
-- connection (another node, or before the owner came back) is dropped.
type Result = {kind: string, problem: string?, state: client.State?, id: string?, title: string?,
    view: tty.Viewport?, desktop: string?, node: string?, generation: integer?, fullscreen: boolean?,
    following: string?, bound: channel.Channel<Binding>?}
-- A command bee runs with: the app command name and the words after it.
type Launch = {name: string, arguments: {string}}
type SavedWindow = {id: string, handle: string}
type Saved = {target: string, origin: string, owner: string?, supervisor: string?, desktop: string,
    scenes: {[string]: model.Scene}, orders: {[string]: {string}}, windows: {SavedWindow}, welcomed: boolean,
    appearance: appearance.Preferences?}
local function window_mode(value: unknown): model.Mode?
    if value == "floating" then return "floating" end
    if value == "fullscreen" then return "fullscreen" end
    if value == "minimized" then return "minimized" end
    if value == "collapsed" then return "collapsed" end
    return nil
end

local function restore_mode(value: unknown): model.RestoreMode?
    if value == "floating" then return "floating" end
    if value == "fullscreen" then return "fullscreen" end
    if value == "collapsed" then return "collapsed" end
    return nil
end

local function whole(value: unknown): integer?
    if type(value) ~= "number" then return nil end
    return math.tointeger(value)
end

local function optional_string(value: unknown): (string?, boolean)
    if value == nil then return nil, true end
    if type(value) ~= "string" then return nil, false end
    return value, true
end

local function saved_rect(value: unknown): model.Rect?
    if type(value) ~= "table" then return nil end
    local x, y, width, height = whole(value.x), whole(value.y), whole(value.width), whole(value.height)
    if not x or not y or not width or not height then return nil end
    return {x = x, y = y, width = width, height = height}
end

local function saved_window(value: unknown): model.Window?
    if type(value) ~= "table" or type(value.id) ~= "string" or type(value.instance_id) ~= "string"
        or type(value.title) ~= "string" then
        return nil
    end
    local mode, restore = window_mode(value.mode), restore_mode(value.restore_mode)
    if not mode or not restore then return nil end
    local bounds, normal_bounds = saved_rect(value.bounds), saved_rect(value.normal_bounds)
    if not bounds or not normal_bounds then return nil end
    local workspace_id, workspace_ok = optional_string(value.workspace_id)
    local user_title, user_title_ok = optional_string(value.user_title)
    local accent, accent_ok = optional_string(value.accent)
    local icon, icon_ok = optional_string(value.icon)
    local snap_side, snap_side_ok = optional_string(value.snap_side)
    if not workspace_ok or not user_title_ok or not accent_ok or not icon_ok or not snap_side_ok then return nil end
    local snap_ratio = value.snap_ratio
    if snap_ratio ~= nil and type(snap_ratio) ~= "number" then return nil end
    return {id = value.id, instance_id = value.instance_id, workspace_id = workspace_id, title = value.title,
        user_title = user_title, accent = accent, icon = icon, bounds = bounds, normal_bounds = normal_bounds,
        mode = mode, restore_mode = restore, snap_side = snap_side, snap_ratio = snap_ratio}
end

local function saved_scene(value: unknown): model.Scene?
    if type(value) ~= "table" or type(value.focus) ~= "string" or type(value.windows) ~= "table" then return nil end
    local width, height, revision = whole(value.width), whole(value.height), whole(value.revision)
    if not width or not height or not revision then return nil end
    local windows: {model.Window} = {}
    for _, item in ipairs(value.windows) do
        local window = saved_window(item)
        if not window then return nil end
        windows[#windows + 1] = window
    end
    return {width = width, height = height, revision = revision, focus = value.focus, windows = windows}
end

local function saved_handover(value: unknown): Saved?
    if type(value) ~= "table" or type(value.target) ~= "string" or type(value.origin) ~= "string"
        or type(value.desktop) ~= "string" or type(value.scenes) ~= "table" or type(value.orders) ~= "table"
        or type(value.windows) ~= "table" or type(value.welcomed) ~= "boolean" then
        return nil
    end
    local owner, owner_ok = optional_string(value.owner)
    local supervisor, supervisor_ok = optional_string(value.supervisor)
    if not owner_ok or not supervisor_ok then return nil end
    local scenes: {[string]: model.Scene} = {}
    for desktop, item in pairs(value.scenes) do
        local scene = type(desktop) == "string" and saved_scene(item) or nil
        if not scene then return nil end
        scenes[desktop] = scene
    end
    local orders: {[string]: {string}} = {}
    for desktop, item in pairs(value.orders) do
        if type(desktop) ~= "string" or type(item) ~= "table" then return nil end
        local order: {string} = {}
        for _, id in ipairs(item) do
            if type(id) ~= "string" then return nil end
            order[#order + 1] = id
        end
        orders[desktop] = order
    end
    local windows: {SavedWindow} = {}
    for _, item in ipairs(value.windows) do
        if type(item) ~= "table" or type(item.id) ~= "string" or type(item.handle) ~= "string" then return nil end
        windows[#windows + 1] = {id = item.id, handle = item.handle}
    end
    return {target = value.target, origin = value.origin, owner = owner, supervisor = supervisor, desktop = value.desktop,
        scenes = scenes, orders = orders, windows = windows, welcomed = value.welcomed,
        appearance = appearance.decode(value.appearance)}
end

M.window_mode = window_mode
M.restore_mode = restore_mode
M.whole = whole
M.optional_string = optional_string
M.saved_rect = saved_rect
M.saved_window = saved_window
M.saved_scene = saved_scene
M.saved_handover = saved_handover
return M
