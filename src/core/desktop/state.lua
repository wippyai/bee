-- Authoritative desktop projection owned by the session process.
--
-- model.Scene keeps layout and stacking order.  This module owns the other
-- committed desktop fields, and joins them only when producing a value
-- envelope for a presenter or an acknowledgement.
local model = require("model")
local appearance = require("appearance")
local commands = require("commands")

type State = {
    scene: model.Scene,
    tabs: {string},
    preferences: appearance.Preferences,
}
type Envelope = {scene: model.Scene, tabs: {string}, preferences: appearance.Preferences}

local M = {}
local MAX_WINDOWS = 16

local function copy_rect(value: model.Rect): model.Rect
    return {x = value.x, y = value.y, width = value.width, height = value.height}
end

local function copy_window(value: model.Window): model.Window
    return {
        id = value.id,
        instance_id = value.instance_id,
        title = value.title, user_title = value.user_title, accent = value.accent, icon = value.icon,
        bounds = copy_rect(value.bounds),
        normal_bounds = copy_rect(value.normal_bounds),
        mode = value.mode,
        restore_mode = value.restore_mode,
    }
end

local function copy_scene(value: model.Scene): model.Scene
    local windows: {model.Window} = {}
    for index = 1, #value.windows do windows[index] = copy_window(value.windows[index]) end
    return {
        width = value.width,
        height = value.height,
        revision = value.revision,
        focus = value.focus,
        windows = windows,
    }
end

local function copy_tabs(value: {string}): {string}
    local tabs: {string} = {}
    for index = 1, #value do tabs[index] = value[index] end
    return tabs
end

local function copy_preferences(value: appearance.Preferences): appearance.Preferences
    return {theme = value.theme, background = value.background, taskbar = value.taskbar}
end

local function next_state(value: State, scene: model.Scene, tabs: {string}?): State
    return {
        scene = scene,
        tabs = copy_tabs(tabs or value.tabs),
        preferences = copy_preferences(value.preferences),
    }
end

function M.new(width: integer, height: integer, preferences: appearance.Preferences?): State
    return {scene = model.new(width, height), tabs = {}, preferences = preferences or appearance.defaults()}
end

-- Reduce one already decoded command.  Invalid command fields are treated as
-- no-ops here; the process boundary admission is commands.decode().
function M.reduce(value: State, command: commands.Command): State
    if command.op == "screen" then
        if not command.width or not command.height then return value end
        local scene = model.resize_screen(value.scene, command.width, command.height)
        if scene == value.scene then return value end
        return next_state(value, scene)
    elseif command.op == "add" then
        if not command.id or not command.instance_id or not command.title then return value end
        if #value.scene.windows >= MAX_WINDOWS then return value end
        local scene = model.add(value.scene, command.id, command.instance_id, command.title, command.icon)
        if scene == value.scene then return value end
        local tabs = copy_tabs(value.tabs)
        tabs[#tabs + 1] = command.id
        return next_state(value, scene, tabs)
    elseif command.op == "announce" then
        if not command.id or not command.instance_id or not command.title then return value end
        local scene = model.announce(value.scene, command.id, command.instance_id, command.title)
        if scene == value.scene then return value end
        return next_state(value, scene)
    elseif command.op == "personalize" then
        if not command.id or command.user_title == nil or command.accent == nil then return value end
        local scene = model.personalize(value.scene, command.id, command.user_title, command.accent)
        if scene == value.scene then return value end
        return next_state(value, scene)
    elseif command.op == "focus" then
        if not command.id then return value end
        local scene = model.focus(value.scene, command.id)
        if scene == value.scene then return value end
        return next_state(value, scene)
    elseif command.op == "fullscreen" then
        if not command.id then return value end
        local scene = model.toggle_fullscreen(value.scene, command.id)
        if scene == value.scene then return value end
        return next_state(value, scene)
    elseif command.op == "minimize" then
        if not command.id then return value end
        local scene = model.minimize(value.scene, command.id)
        if scene == value.scene then return value end
        return next_state(value, scene)
    elseif command.op == "collapse" then
        if not command.id then return value end
        local scene = model.collapse(value.scene, command.id)
        if scene == value.scene then return value end
        return next_state(value, scene)
    elseif command.op == "restore" then
        if not command.id then return value end
        local scene = model.restore(value.scene, command.id)
        if scene == value.scene then return value end
        return next_state(value, scene)
    elseif command.op == "snap" then
        if not command.id or not command.side then return value end
        local scene = model.snap(value.scene, command.id, command.side)
        if scene == value.scene then return value end
        return next_state(value, scene)
    elseif command.op == "place" then
        if not command.id or not command.x or not command.y or not command.width or not command.height then
            return value
        end
        local scene = model.place(value.scene, command.id, {
            x = command.x, y = command.y, width = command.width, height = command.height,
        })
        if scene == value.scene then return value end
        return next_state(value, scene)
    elseif command.op == "remove" then
        if not command.id then return value end
        local scene = model.remove(value.scene, command.id)
        if scene == value.scene then return value end
        local tabs: {string} = {}
        for index = 1, #value.tabs do
            if value.tabs[index] ~= command.id then tabs[#tabs + 1] = value.tabs[index] end
        end
        return next_state(value, scene, tabs)
    elseif command.op == "appearance" then
        if not command.theme or not command.background then return value end
        if command.expected_revision ~= nil and command.expected_revision ~= value.scene.revision then return value end
        local preferences = appearance.decode({theme = command.theme, background = command.background, taskbar = command.taskbar})
        if not preferences then return value end
        if preferences.theme == value.preferences.theme and preferences.background == value.preferences.background and preferences.taskbar == value.preferences.taskbar then
            return value
        end
        local scene = copy_scene(value.scene)
        scene.revision = scene.revision + 1
        return {
            scene = scene,
            tabs = copy_tabs(value.tabs),
            preferences = copy_preferences(preferences),
        }
    end
    return value
end

function M.envelope(value: State): Envelope
    return {
        scene = copy_scene(value.scene),
        tabs = copy_tabs(value.tabs),
        preferences = copy_preferences(value.preferences),
    }
end

-- A named alias makes call sites explicit when they are sending a snapshot.
M.snapshot = M.envelope

return M
