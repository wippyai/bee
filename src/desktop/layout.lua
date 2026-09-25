-- Shared geometry for painting and pointer routing. No terminal handles or IO.
local model = require("model")
type Capture = {id: string, x: integer, y: integer, bounds: model.Rect, edge: string}
local M = {}
function M.contains(rect: model.Rect, x: integer, y: integer): boolean
    return x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height
end
function M.interior(win: model.Window, rect: model.Rect): model.Rect
    if win.mode == "fullscreen" or rect.width < 3 or rect.height < 3 then return rect end
    return {x = rect.x + 1, y = rect.y + 1, width = rect.width - 2, height = rect.height - 2}
end
function M.rectangle(scene: model.Scene, win: model.Window, capture: Capture?, preview: model.Rect?): model.Rect
    if capture and preview and capture.id == win.id then return preview end
    return model.bounds(scene, win)
end
type Control = {action: string, label: string, x: integer, y: integer, width: integer}
function M.controls(win: model.Window, rect: model.Rect): {Control}
    local controls: {Control} = {}
    if win.mode == "fullscreen" or rect.width < 5 then return controls end
    local actions: {string} = {"close"}
    local labels: {string} = {" × "}
    if rect.width >= 11 then
        table.insert(actions, 1, win.mode == "collapsed" and "restore" or "fullscreen")
        table.insert(labels, 1, win.mode == "collapsed" and " ◇ " or " □ ")
    end
    if rect.width >= 15 then table.insert(actions, 1, "minimize"); table.insert(labels, 1, " − ") end
    local x = rect.x + rect.width - 1 - #actions * 3
    for i, action in ipairs(actions) do
        controls[#controls + 1] = {action = action, label = labels[i], x = x, y = rect.y, width = 3}
        x = x + 3
    end
    return controls
end
function M.control_at(win: model.Window, rect: model.Rect, x: integer, y: integer): string?
    if y ~= rect.y then return nil end
    for _, control in ipairs(M.controls(win, rect)) do
        if x >= control.x and x < control.x + control.width then return control.action end
    end
    return nil
end
function M.edge(rect: model.Rect, x: integer, y: integer): string
    if not M.contains(rect, x, y) then return "" end
    local edge = ""
    if x == rect.x then edge = edge .. "l" elseif x == rect.x + rect.width - 1 then edge = edge .. "r" end
    if y == rect.y then edge = edge .. "t" elseif y == rect.y + rect.height - 1 then edge = edge .. "b" end
    if edge == "t" then return "move" end
    return edge
end
function M.drag(scene: model.Scene, capture: Capture, x: integer, y: integer): model.Rect?
    local start = capture.bounds
    local dx, dy = x - capture.x, y - capture.y
    local left, top = start.x, start.y
    local right, bottom = start.x + start.width - 1, start.y + start.height - 1
    if capture.edge == "move" then left, top, right, bottom = left + dx, top + dy, right + dx, bottom + dy
    else
        if capture.edge:find("l", 1, true) then left = math.floor(math.min(right - 2, left + dx)) end
        if capture.edge:find("r", 1, true) then right = math.floor(math.max(left + 2, right + dx)) end
        if capture.edge:find("t", 1, true) then top = math.floor(math.min(bottom - 2, top + dy)) end
        if capture.edge:find("b", 1, true) then bottom = math.floor(math.max(top + 2, bottom + dy)) end
    end
    local temporary = model.place(scene, capture.id, {x = left, y = top,
        width = math.floor(math.max(1, right - left + 1)), height = math.floor(math.max(1, bottom - top + 1))})
    for _, win in ipairs(temporary.windows) do if win.id == capture.id then return win.bounds end end
    return nil
end
return M
