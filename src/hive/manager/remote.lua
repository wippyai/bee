-- MIT. The Hive Manager's remote view of another node's workspace: the view
-- process's messages decoded strictly, the window it draws and the input it
-- forwards. The view process holds the owner's mount; this window only draws
-- the rows it is sent and forwards input while it controls the session.
local appearance = require("appearance")
local frame = require("frame")
local names = require("names")
local M = {}
M.MAX_ROWS = 200
M.MAX_ROW_BYTES = 32768
-- Alt+Q leaves the view; the native client keeps Ctrl+] for itself.
M.LEAVE_HINT = "Alt+Q leave"
type Mode = "control" | "observe"
type Cursor = {x: integer, y: integer, visible: boolean}
type View = {pid: string, node_id: string, node_label: string, workspace_id: string, desktop_id: string, mode: Mode,
    session_id: string, rows: {string}, cursor: Cursor?, leaving: boolean}
type Attached = {session_id: string, mode: Mode, workspace_id: string, desktop_id: string}
type Failed = {code: string, message: string}
local function line(value: unknown, limit: integer): string?
    if type(value) ~= "string" or #value > limit or value:find("[%c]") then return nil end
    return value
end
local function identity(value: unknown): string?
    if type(value) ~= "string" or #value ~= 32 or value:find("[^0-9a-f]") then return nil end
    return value
end
-- The view's one state message: attached, with the session it holds, or failed.
function M.state(value: unknown): (Attached?, Failed?)
    if type(value) ~= "table" or value.version ~= 1 then return nil, {code = "INVALID_STATE", message = "The remote view answered a malformed state"} end
    if value.state == "failed" then
        return nil, {code = line(value.code, 64) or "UNAVAILABLE", message = line(value.message, 400) or "Remote desktop unavailable"}
    end
    local session = line(value.session_id, 160)
    local workspace, desktop = identity(value.workspace_id), identity(value.desktop_id)
    local mode: Mode? = value.mode == "control" and "control" or (value.mode == "observe" and "observe" or nil)
    if value.state ~= "attached" or not session or session == "" or not workspace or not desktop or not mode then
        return nil, {code = "INVALID_STATE", message = "The remote view answered a malformed state"}
    end
    return {session_id = session, mode = mode, workspace_id = workspace, desktop_id = desktop}, nil
end
-- One rendered frame: bounded rows and an optional cursor.
function M.frame(value: unknown): ({string}?, Cursor?)
    if type(value) ~= "table" or value.version ~= 1 or type(value.rows) ~= "table" then return nil, nil end
    local rows: {string} = {}
    local count = 0
    for _ in pairs(value.rows) do count = count + 1 end
    if count > M.MAX_ROWS then return nil, nil end
    for index = 1, count do
        local row = value.rows[index]
        if type(row) ~= "string" or #row > M.MAX_ROW_BYTES then return nil, nil end
        rows[index] = row
    end
    local cursor: Cursor? = nil
    local raw = value.cursor
    if type(raw) == "table" then
        local x, y = raw.x, raw.y
        if type(x) == "number" and type(y) == "number" and x == math.floor(x) and y == math.floor(y) and x >= 0 and y >= 0 then
            cursor = {x = math.floor(x), y = math.floor(y), visible = raw.visible == true}
        end
    end
    return rows, cursor
end
-- What the window forwards for one input event: nothing, the leave request,
-- or the event itself, with a mouse row moved below the window's title row.
function M.forward(view: View, event: {[string]: unknown}): ("leave" | "forward" | "drop", {[string]: unknown}?)
    if event.type == "key" and event.alt == true and (event.key == "q" or event.key == "Q") and event.action ~= "release" then return "leave", nil end
    if view.mode ~= "control" or view.leaving then return "drop", nil end
    if event.type == "key" or event.type == "paste" or event.type == "focus" then return "forward", event end
    if event.type == "mouse" then
        local y = event.y
        if type(y) ~= "number" or y < 2 then return "drop", nil end
        local moved: {[string]: unknown} = {}
        for key, item in pairs(event) do moved[key] = item end
        moved.y = y - 1
        return "forward", moved
    end
    return "drop", nil
end
-- The window: one title row naming the node, the leave key, the mode and the
-- workspace, then the remote rows.
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, view: View): {rows: {string}, cursor: Cursor}
    local painter = frame.new(width, 1, preferences)
    local mode = view.mode == "control" and "Control" or "Observe"
    local state = view.leaving and "Leaving" or mode
    -- The summary is truncated from its end, so the leave hint comes first.
    frame.header(painter, "REMOTE · " .. view.node_label, M.LEAVE_HINT .. " · " .. state .. " · " .. names.label(view.workspace_id))
    local rows = frame.rows(painter)
    local drawn: {string} = {rows[1] or ""}
    for index = 1, height - 1 do drawn[#drawn + 1] = view.rows[index] or "" end
    local cursor: Cursor = {x = 1, y = 1, visible = false}
    local remote = view.cursor
    if remote and view.mode == "control" then cursor = {x = remote.x, y = remote.y + 1, visible = remote.visible} end
    return {rows = drawn, cursor = cursor}
end
return M
