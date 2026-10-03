-- MIT. The Hive Manager's remote view of another node's workspace: the view
-- process's messages decoded strictly, the window it draws and the input it
-- forwards. The view process holds the owner's mount; this window only draws
-- the rows it is sent and forwards input while it controls the session.
local appearance = require("appearance")
local bounds = require("bounds")
local frame = require("frame")
local names = require("names")
local M = {}
M.MAX_ROWS = 200
M.MAX_ROW_BYTES = 32768
M.MAX_FRAME_BYTES = 1048576
-- Alt+Q leaves the view; the native client keeps Ctrl+] for itself.
M.LEAVE_HINT = "Alt+Q leave"
type Mode = "control" | "observe"
type Cursor = {x: integer, y: integer, visible: boolean}
type View = {pid: string, node_id: string, node_label: string, workspace_id: string, desktop_id: string, mode: Mode,
    session_id: string, rows: {string}, cursor: Cursor?, leaving: boolean}
type Attached = {session_id: string, mode: Mode, workspace_id: string, desktop_id: string, owner_execution: string}
type Failed = {code: string, message: string}
type State = {kind: "attached", attached: Attached} | {kind: "failed", failure: Failed}
type Frame = {rows: {string}, cursor: Cursor}
type FrameResult = {kind: "valid", frame: Frame} | {kind: "invalid", error: string}
local function line(value: unknown, limit: integer): string?
    if type(value) ~= "string" or #value > limit or value:find("[%c]") then return nil end
    return value
end
local function identity(value: unknown): string?
    if type(value) ~= "string" or #value ~= 32 or value:find("[^0-9a-f]") then return nil end
    return value
end
local function failed(code: string, message: string): State
    return {kind = "failed", failure = {code = code, message = message}}
end
-- The view's one state message: attached, with the session it holds, or failed.
function M.state(value: unknown): State
    local object = bounds.object(value)
    if not object or object.version ~= 1 then return failed("INVALID_STATE", "The remote view answered a malformed state") end
    if object.state == "failed" then
        if bounds.fields(object, {"version", "state", "code", "message"}) then
            return failed("INVALID_STATE", "The remote view answered a malformed state")
        end
        local code, message = line(object.code, 64), line(object.message, 400)
        if not code or not message then return failed("INVALID_STATE", "The remote view answered a malformed state") end
        return failed(code, message)
    end
    if object.state == "uncertain" then
        if bounds.fields(object, {"version", "state", "code", "message"}) then
            return failed("INVALID_STATE", "The remote view answered a malformed state")
        end
        local code, message = line(object.code, 64), line(object.message, 400)
        if code ~= "UNCERTAIN" or not message then return failed("INVALID_STATE", "The remote view answered a malformed state") end
        return failed(code, message)
    end
    if object.state ~= "attached" or bounds.fields(object, {"version", "state", "session_id", "mode", "workspace_id", "desktop_id", "owner_execution"}) then
        return failed("INVALID_STATE", "The remote view answered a malformed state")
    end
    local session = line(object.session_id, 160)
    local workspace, desktop = identity(object.workspace_id), identity(object.desktop_id)
    local owner_execution = identity(object.owner_execution)
    local mode: Mode? = object.mode == "control" and "control" or (object.mode == "observe" and "observe" or nil)
    if not session or session == "" or not workspace or not desktop or not owner_execution or not mode then
        return failed("INVALID_STATE", "The remote view answered a malformed state")
    end
    local attached: Attached = {session_id = session, mode = mode, workspace_id = workspace, desktop_id = desktop, owner_execution = owner_execution}
    return {kind = "attached", attached = attached}
end
-- One rendered frame: bounded in count, total bytes and viewport coordinates.
function M.frame(value: unknown, width: integer, height: integer): FrameResult
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"version", "rows", "cursor"}) or object.version ~= 1 then return {kind = "invalid", error = "Invalid frame envelope or version"} end
    local raw_rows = bounds.array(object.rows, M.MAX_ROWS)
    if not raw_rows then return {kind = "invalid", error = "Invalid frame row array"} end
    local rows: {string} = {}
    local total_bytes = 0
    for index, raw in ipairs(raw_rows) do
        if type(raw) ~= "string" or #raw > M.MAX_ROW_BYTES then return {kind = "invalid", error = "Invalid frame row or row byte limit exceeded"} end
        local unstyled = raw:gsub("\27%[[0-9;:]*m", "")
        if unstyled:find("%c") then return {kind = "invalid", error = "Frame row contains a control outside ANSI styling"} end
        total_bytes = total_bytes + #raw
        if total_bytes > M.MAX_FRAME_BYTES then return {kind = "invalid", error = "Frame byte limit exceeded"} end
        rows[index] = raw
    end
    local cursor: Cursor = {x = 0, y = 0, visible = false}
    if object.cursor ~= nil then
        local raw_cursor = bounds.object(object.cursor)
        if not raw_cursor or bounds.fields(raw_cursor, {"x", "y", "visible"}) then return {kind = "invalid", error = "Invalid frame cursor"} end
        local x, y = bounds.integer(raw_cursor.x), bounds.integer(raw_cursor.y)
        if not x or not y or x < 0 or y < 0 or x >= width or y >= height or type(raw_cursor.visible) ~= "boolean" then
            return {kind = "invalid", error = "Invalid frame cursor coordinates or visibility"}
        end
        cursor = {x = x, y = y, visible = raw_cursor.visible}
    end
    return {kind = "valid", frame = {rows = rows, cursor = cursor}}
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
