-- Pure desktop scene state.  The scene owns placement and focus; application
-- lifecycle and terminal attachments belong to the host and presenter.

type Rect = { x: integer, y: integer, width: integer, height: integer }
type Mode = "floating" | "fullscreen" | "minimized" | "collapsed"
type RestoreMode = "floating" | "fullscreen" | "collapsed"
type Window = {
    id: string,
    instance_id: string,
    workspace_id: string?,
    title: string,
    user_title: string?,
    accent: string?,
    icon: string?,
    bounds: Rect,
    normal_bounds: Rect,
    mode: Mode,
    restore_mode: RestoreMode,
}
type Scene = {
    width: integer,
    height: integer,
    revision: integer,
    focus: string,
    windows: {Window},
}

local M = {}

local DEFAULT_WIDTH = 64
local DEFAULT_HEIGHT = 20
local CASCADE_X = 4
local CASCADE_Y = 2

local function at_least_one(value: integer): integer
    if value < 1 then return 1 end
    return value
end

local function copy_rect(value: Rect): Rect
    return { x = value.x, y = value.y, width = value.width, height = value.height }
end

local function copy_window(value: Window): Window
    return {
        id = value.id,
        instance_id = value.instance_id, workspace_id = value.workspace_id,
        title = value.title, user_title = value.user_title, accent = value.accent, icon = value.icon,
        bounds = copy_rect(value.bounds),
        normal_bounds = copy_rect(value.normal_bounds),
        mode = value.mode,
        restore_mode = value.restore_mode,
    }
end

local function copy_windows(values: {Window}): {Window}
    local result: {Window} = {}
    for index = 1, #values do
        result[index] = copy_window(values[index])
    end
    return result
end

-- One copy boundary for all scene consumers; new window fields stay intact.
function M.copy(scene: Scene): Scene
    return {width = scene.width, height = scene.height, revision = scene.revision,
        focus = scene.focus, windows = copy_windows(scene.windows)}
end

local function workspace(width: integer, height: integer): Rect
    -- Reserve one shared application/status bar. Tiny screens use all rows.
    if height >= 3 then
        return { x = 1, y = 2, width = width, height = height - 1 }
    end
    return { x = 1, y = 1, width = width, height = height }
end

local function clamp(value: Rect, area: Rect): Rect
    local width = value.width
    if width < 1 then
        width = 1
    elseif width > area.width then
        width = area.width
    end

    local height = value.height
    if height < 1 then
        height = 1
    elseif height > area.height then
        height = area.height
    end

    local x = value.x
    local max_x = area.x + area.width - width
    if x < area.x then
        x = area.x
    elseif x > max_x then
        x = max_x
    end

    local y = value.y
    local max_y = area.y + area.height - height
    if y < area.y then
        y = area.y
    elseif y > max_y then
        y = max_y
    end

    return { x = x, y = y, width = width, height = height }
end

local function collapsed_bounds(value: Rect, area: Rect): Rect
    return clamp({ x = value.x, y = value.y, width = value.width, height = 1 }, area)
end

local function same_rect(left: Rect, right: Rect): boolean
    return left.x == right.x and left.y == right.y
        and left.width == right.width and left.height == right.height
end

-- A new window takes three quarters of the display, never less than the
-- default size the display can hold.
local function default_bounds(area: Rect, index: integer): Rect
    local width = area.width * 3 // 4
    if width < DEFAULT_WIDTH then width = DEFAULT_WIDTH end
    if width > area.width then width = area.width end
    local height = area.height * 3 // 4
    if height < DEFAULT_HEIGHT then height = DEFAULT_HEIGHT end
    if height > area.height then height = area.height end

    local last_x = area.x + area.width - width
    local last_y = area.y + area.height - height
    local first_x = area.x
    local first_y = area.y
    if first_x < last_x then first_x = first_x + 1 end
    if first_y < last_y then first_y = first_y + 1 end

    local columns = (last_x - first_x) // CASCADE_X + 1
    local rows = (last_y - first_y) // CASCADE_Y + 1
    if columns < 1 then columns = 1 end
    if rows < 1 then rows = 1 end

    local slot = index - 1
    return clamp({
        x = first_x + (slot % columns) * CASCADE_X,
        y = first_y + ((slot // columns) % rows) * CASCADE_Y,
        width = width,
        height = height,
    }, area)
end

local function find_index(values: {Window}, id: string): integer?
    for index = 1, #values do
        if values[index].id == id then return index end
    end
    return nil
end

local function layer(mode: Mode): string
    if mode == "fullscreen" then return "fullscreen" end
    return "floating"
end

local function restore_mode(value: Window): RestoreMode
    if value.restore_mode == "fullscreen" then return "fullscreen" end
    if value.restore_mode == "collapsed" then return "collapsed" end
    return "floating"
end

local function restore_window(value: Window, area: Rect)
    local mode = restore_mode(value)
    if mode == "fullscreen" then
        value.bounds = copy_rect(area)
    elseif mode == "collapsed" then
        value.bounds = collapsed_bounds(value.normal_bounds, area)
    else
        value.bounds = clamp(value.normal_bounds, area)
    end
    value.mode = mode
    value.restore_mode = mode
end

local function commit(
    scene: Scene,
    width: integer,
    height: integer,
    focus_id: string,
    windows: {Window}
): Scene
    return {
        width = width,
        height = height,
        revision = scene.revision + 1,
        focus = focus_id,
        windows = windows,
    }
end

local function fallback_focus(values: {Window}): string
    for index = #values, 1, -1 do
        if values[index].mode ~= "minimized" then return values[index].id end
    end
    return ""
end

function M.new(width: integer, height: integer): Scene
    local scene_width = at_least_one(width)
    local scene_height = at_least_one(height)
    return {
        width = scene_width,
        height = scene_height,
        revision = 0,
        focus = "",
        windows = {},
    }
end

function M.add(scene: Scene, id: string, instance_id: string, title: string, icon: string?, workspace_id: string?): Scene
    if find_index(scene.windows, id) ~= nil then return scene end

    local area = workspace(scene.width, scene.height)
    local rect = default_bounds(area, #scene.windows + 1)
    local added: Window = {
        id = id,
        instance_id = instance_id, workspace_id = workspace_id,
        title = title, icon = icon,
        bounds = copy_rect(rect),
        normal_bounds = copy_rect(rect),
        mode = "floating",
        restore_mode = "floating",
    }
    local windows = copy_windows(scene.windows)
    windows[#windows + 1] = added
    return commit(scene, scene.width, scene.height, id, windows)
end

function M.display_title(window: Window): string
    if window.user_title ~= nil and window.user_title ~= "" then return window.user_title end
    return window.title
end

-- The broker supplies the current app title; a user label remains independent.
function M.announce(scene: Scene, id: string, instance_id: string, title: string): Scene
    local index = find_index(scene.windows, id)
    if not index then return scene end
    local current = scene.windows[index]
    if current.instance_id ~= instance_id or current.title == title then return scene end
    local windows = copy_windows(scene.windows)
    windows[index].title = title
    return commit(scene, scene.width, scene.height, scene.focus, windows)
end

function M.personalize(scene: Scene, id: string, user_title: string, accent: string): Scene
    local index = find_index(scene.windows, id)
    if index == nil then return scene end

    local next_user_title: string? = user_title
    if user_title == "" then next_user_title = nil end
    local next_accent: string? = accent
    if accent == "" then next_accent = nil end
    local current = scene.windows[index]
    if current.user_title == next_user_title and current.accent == next_accent then return scene end

    local windows = copy_windows(scene.windows)
    windows[index].user_title = next_user_title
    windows[index].accent = next_accent
    return commit(scene, scene.width, scene.height, scene.focus, windows)
end

function M.focus(scene: Scene, id: string): Scene
    if id == "" then
        if scene.focus == "" then return scene end
        return commit(scene, scene.width, scene.height, "", copy_windows(scene.windows))
    end
    local index = find_index(scene.windows, id)
    if index == nil then return scene end
    local current: Window = scene.windows[index]
    if current.mode ~= "minimized" and scene.focus == id then return scene end

    local area = workspace(scene.width, scene.height)
    local selected_mode = current.mode
    if selected_mode == "minimized" then selected_mode = restore_mode(current) end

    -- Focus changes keyboard ownership and raises within the selected layer.
    -- Fullscreen and floating windows keep separate ordering histories.
    local selected_layer = layer(selected_mode)
    local windows: {Window} = {}
    local selected: Window? = nil
    for source_index = 1, #scene.windows do
        local window = scene.windows[source_index]
        if source_index == index then
            selected = copy_window(window)
            if selected.mode == "minimized" then restore_window(selected, area) end
        else
            windows[#windows + 1] = copy_window(window)
        end
    end
    local insert_at = #windows + 1
    for source_index = #windows, 1, -1 do
        if layer(windows[source_index].mode) == selected_layer then
            insert_at = source_index + 1
            break
        end
    end
    if selected ~= nil then
        table.insert(windows, insert_at, selected)
    end
    return commit(scene, scene.width, scene.height, id, windows)
end

function M.resize_screen(scene: Scene, width: integer, height: integer): Scene
    local scene_width = at_least_one(width)
    local scene_height = at_least_one(height)
    if scene.width == scene_width and scene.height == scene_height then return scene end

    local area = workspace(scene_width, scene_height)
    local windows = copy_windows(scene.windows)
    for index = 1, #windows do
        local window = windows[index]
        if window.mode == "fullscreen" then
            window.bounds = copy_rect(area)
        elseif window.mode == "collapsed" then
            window.bounds = collapsed_bounds(window.normal_bounds, area)
        elseif window.mode == "minimized" and restore_mode(window) == "fullscreen" then
            window.bounds = copy_rect(area)
        elseif window.mode == "minimized" and restore_mode(window) == "collapsed" then
            window.bounds = collapsed_bounds(window.normal_bounds, area)
        else
            window.bounds = clamp(window.normal_bounds, area)
        end
    end
    return commit(scene, scene_width, scene_height, scene.focus, windows)
end

function M.place(scene: Scene, id: string, rect: Rect): Scene
    local index = find_index(scene.windows, id)
    if index == nil then return scene end

    local current = scene.windows[index]
    if current.mode == "collapsed" then
        -- A collapsed title bar moves the saved window without resizing its
        -- producer or replacing the remembered expanded dimensions.
        local placed = collapsed_bounds({x = rect.x, y = rect.y, width = current.bounds.width, height = 1},
            workspace(scene.width, scene.height))
        if same_rect(current.bounds, placed) then return scene end
        local windows = copy_windows(scene.windows)
        windows[index].bounds = placed
        windows[index].normal_bounds.x = placed.x
        windows[index].normal_bounds.y = placed.y
        return commit(scene, scene.width, scene.height, scene.focus, windows)
    end
    if current.mode ~= "floating" then return scene end

    local placed = clamp(rect, workspace(scene.width, scene.height))
    if same_rect(current.bounds, placed) and same_rect(current.normal_bounds, placed) then
        return scene
    end

    local windows = copy_windows(scene.windows)
    windows[index].bounds = copy_rect(placed)
    windows[index].normal_bounds = copy_rect(placed)
    windows[index].restore_mode = "floating"
    return commit(scene, scene.width, scene.height, scene.focus, windows)
end

function M.snap(scene: Scene, id: string, side: string): Scene
    if side ~= "left" and side ~= "right" then return scene end

    local index = find_index(scene.windows, id)
    if index == nil then return scene end
    if scene.windows[index].mode ~= "floating" then return scene end

    local area = workspace(scene.width, scene.height)
    local left_width = area.width // 2
    if left_width < 1 then left_width = 1 end

    local target: Rect
    if area.width < 2 then
        target = copy_rect(area)
    elseif side == "left" then
        target = { x = area.x, y = area.y, width = left_width, height = area.height }
    else
        target = { x = area.x + left_width, y = area.y,
            width = area.width - left_width, height = area.height }
    end

    local placed = clamp(target, area)
    local current = scene.windows[index]
    if same_rect(current.bounds, placed) and same_rect(current.normal_bounds, placed) then
        return scene
    end

    local windows = copy_windows(scene.windows)
    windows[index].bounds = copy_rect(placed)
    windows[index].normal_bounds = copy_rect(placed)
    windows[index].restore_mode = "floating"
    return commit(scene, scene.width, scene.height, scene.focus, windows)
end

function M.collapse(scene: Scene, id: string): Scene
    local index = find_index(scene.windows, id)
    if index == nil then return scene end
    if scene.windows[index].mode ~= "floating" then return scene end

    local area = workspace(scene.width, scene.height)
    local windows = copy_windows(scene.windows)
    local window = windows[index]
    window.bounds = collapsed_bounds(window.bounds, area)
    window.mode = "collapsed"
    window.restore_mode = "collapsed"
    return commit(scene, scene.width, scene.height, scene.focus, windows)
end

function M.restore(scene: Scene, id: string): Scene
    local index = find_index(scene.windows, id)
    if index == nil then return scene end

    local current = scene.windows[index]
    if current.mode ~= "minimized" and current.mode ~= "collapsed" then return scene end

    local area = workspace(scene.width, scene.height)
    local windows = copy_windows(scene.windows)
    if current.mode == "collapsed" then
        windows[index].bounds = clamp(windows[index].normal_bounds, area)
        windows[index].mode = "floating"
        windows[index].restore_mode = "floating"
    else
        restore_window(windows[index], area)
    end
    return commit(scene, scene.width, scene.height, scene.focus, windows)
end

function M.minimize(scene: Scene, id: string): Scene
    local index = find_index(scene.windows, id)
    if index == nil then return scene end

    local current = scene.windows[index]
    if current.mode == "minimized" then return scene end

    local windows = copy_windows(scene.windows)
    local window = windows[index]
    if window.mode == "fullscreen" then
        window.restore_mode = "fullscreen"
    elseif window.mode == "collapsed" then
        window.restore_mode = "collapsed"
    else
        window.restore_mode = "floating"
    end
    window.mode = "minimized"

    local focus_id = scene.focus
    if focus_id == id then focus_id = fallback_focus(windows) end
    return commit(scene, scene.width, scene.height, focus_id, windows)
end

function M.toggle_fullscreen(scene: Scene, id: string): Scene
    local index = find_index(scene.windows, id)
    if index == nil then return scene end

    local area = workspace(scene.width, scene.height)
    local windows = copy_windows(scene.windows)
    local window = windows[index]
    if window.mode == "fullscreen" then
        local restored = clamp(window.normal_bounds, area)
        window.bounds = copy_rect(restored)
        window.mode = "floating"
        window.restore_mode = "floating"
    elseif window.mode == "floating" then
        window.bounds = copy_rect(area)
        window.mode = "fullscreen"
        window.restore_mode = "fullscreen"
    else
        return scene
    end
    return commit(scene, scene.width, scene.height, scene.focus, windows)
end

function M.remove(scene: Scene, id: string): Scene
    local index = find_index(scene.windows, id)
    if index == nil then return scene end

    local windows: {Window} = {}
    for source_index = 1, #scene.windows do
        if source_index ~= index then
            windows[#windows + 1] = copy_window(scene.windows[source_index])
        end
    end
    local focus_id = scene.focus
    if focus_id == id then focus_id = fallback_focus(windows) end
    return commit(scene, scene.width, scene.height, focus_id, windows)
end

function M.visible(scene: Scene): {Window}
    local result: {Window} = {}

    -- A fullscreen layer paints one window. Focus explicitly selects a
    -- fullscreen window; otherwise the last fullscreen entry is selected.
    local fullscreen_index: integer? = nil
    for index = 1, #scene.windows do
        local window = scene.windows[index]
        if window.mode == "fullscreen" then
            fullscreen_index = index
            if scene.focus == window.id then break end
        end
    end

    if fullscreen_index ~= nil then
        result[#result + 1] = copy_window(scene.windows[fullscreen_index])
        -- Ordinary floating apps cannot obscure a focused fullscreen app.
        -- Dialog/modal layering will be explicit when that capability is added.
        if scene.windows[fullscreen_index].id == scene.focus then return result end
    end

    local focused_floating: Window? = nil
    for index = 1, #scene.windows do
        local window = scene.windows[index]
        if window.mode ~= "minimized" and window.mode ~= "fullscreen" then
            if scene.focus == window.id then
                focused_floating = window
            else
                result[#result + 1] = copy_window(window)
            end
        end
    end
    if focused_floating ~= nil then
        result[#result + 1] = copy_window(focused_floating)
    end
    return result
end

function M.bounds(scene: Scene, window: Window): Rect
    if window.mode == "fullscreen" then
        return workspace(scene.width, scene.height)
    end
    if window.mode == "collapsed" then
        return collapsed_bounds(window.bounds, workspace(scene.width, scene.height))
    end
    return clamp(window.bounds, workspace(scene.width, scene.height))
end

return M
