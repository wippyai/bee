-- MIT. Private supervisor-owned grants for a retained virtual desktop.
local tty = require("tty")
local attachment = require("attachment")
type State = {view: tty.Viewport, controller: attachment.Record?, observers: {[string]: string}}
type Mode = "control" | "observe"
type Result = {mount: string, error_code: string, error: string}
local M = {}

-- The caller retains the viewport's lifetime and admits each recipient before
-- calling this library. These records are capabilities, never persisted state.
function M.new(view: tty.Viewport): State
    local observers: {[string]: string} = {}
    return {view = view, controller = nil, observers = observers}
end

function M.attach(state: State, recipient: string, mode: Mode): Result
    if recipient == "" then return {mount = "", error_code = "invalid_argument", error = "Desktop recipient required"} end
    if mode == "observe" then
        if state.controller and state.controller.recipient == recipient then
            return {mount = "", error_code = "mode_conflict", error = "Detach controller before observing"}
        end
        return attachment.observe(state.view, state.observers, recipient)
    end
    if mode ~= "control" then
        return {mount = "", error_code = "invalid_argument", error = "Invalid desktop attachment mode"}
    end
    if state.observers[recipient] then
        return {mount = "", error_code = "mode_conflict", error = "Detach observer before controlling"}
    end
    if state.controller and state.controller.recipient ~= recipient then
        return {mount = "", error_code = "busy", error = "Desktop already has a controller"}
    end
    local result = attachment.replace(state.view, state.controller, recipient)
    state.controller = result.attachment
    return {mount = result.error_code == "" and attachment.reference(result.attachment) or "",
        error_code = result.error_code, error = result.error}
end

function M.detach(state: State, recipient: string): Result
    local controlled = attachment.remove_recipient(state.view, state.controller, recipient)
    state.controller = controlled.attachment
    if controlled.error_code ~= "" then
        return {mount = "", error_code = controlled.error_code, error = controlled.error}
    end
    local removed, err = attachment.remove_observer(state.view, state.observers, recipient)
    if not removed then return {mount = "", error_code = "revoke_failed", error = err or "Observer revocation failed"} end
    return {mount = "", error_code = "", error = ""}
end
return M
