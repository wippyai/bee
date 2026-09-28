-- SPDX-License-Identifier: MIT
-- Reference: command palette, confirmation modal and toast.
-- Demonstrates the overlay stack of an application: one model with a single
-- active overlay, the typed query and choice of the palette (frame.ranked
-- filters and orders the commands), a two-button confirmation and a toast
-- that expires after a number of ticks. Esc dismisses every overlay; while
-- an overlay is open it owns all input.
--
-- Library calls: frame.ranked, frame.palette, frame.modal, frame.button,
-- frame.toast.
local frame = require("frame")

local M = {}

type Model = {kind: string, query: string, choice: integer, toast: string?, toast_ticks: integer}

function M.new(): Model return {kind = "", query = "", choice = 1, toast = nil, toast_ticks = 0} end

function M.open(model: Model, kind: string)
    model.kind, model.query, model.choice = kind, "", 1
end

-- Shows text as a toast for ticks calls of tick.
function M.notify(model: Model, text: string, ticks: integer)
    model.toast, model.toast_ticks = text, ticks
end

-- Counts one tick down and returns whether the toast just expired.
function M.tick(model: Model): boolean
    if not model.toast then return false end
    model.toast_ticks = model.toast_ticks - 1
    if model.toast_ticks > 0 then return false end
    model.toast = nil
    return true
end

local function is_escape(name: unknown): boolean return name == "esc" or name == "escape" end

-- Routes one tty event to the active overlay. Returns the chosen command
-- (palette) or "confirm" (modal) when the user commits, otherwise nil.
function M.key(model: Model, event: {[string]: unknown}, commands: {string}): string?
    if event.type ~= "key" or event.action == "release" then return nil end
    local name = event.key_type
    if is_escape(name) then M.open(model, ""); return nil end
    if model.kind == "confirm" then
        if name == "enter" then M.open(model, ""); return "confirm" end
        return nil
    end
    if model.kind ~= "palette" then return nil end
    local found = frame.ranked(model.query, commands)
    if name == "up" then model.choice = math.max(1, model.choice - 1)
    elseif name == "down" then model.choice = math.min(math.max(1, #found), model.choice + 1)
    elseif name == "enter" then
        local picked = found[model.choice]
        M.open(model, "")
        return picked and picked.label or nil
    elseif name == "backspace" then model.query, model.choice = string.sub(model.query, 1, -2), 1
    elseif type(event.key) == "string" and #event.key == 1 and event.key ~= " " then
        model.query, model.choice = model.query .. event.key, 1
    end
    return nil
end

-- Routes a resolved frame.hit: a palette row (hit.key is the command) or a modal button.
function M.click(model: Model, hit: frame.Hit): string?
    if hit.kind == "choice" then M.open(model, ""); return hit.key end
    if hit.kind == "confirm" then M.open(model, ""); return "confirm" end
    if hit.kind == "dismiss" then M.open(model, "") end
    return nil
end

-- Draws the active overlay and the toast over the finished screen.
function M.draw(painter: frame.Painter, model: Model, commands: {string}, confirm_title: string, confirm_text: string)
    if model.kind == "palette" then
        local choices = frame.ranked(model.query, commands)
        frame.palette(painter, 50, 12, {query = model.query, choices = choices,
            selected = math.floor(math.max(1, math.min(#choices, model.choice))), offset = 0})
    elseif model.kind == "confirm" then
        local inner = frame.modal(painter, 46, 6, confirm_title)
        if inner.height >= 3 then
            frame.put(painter, inner.x, inner.y, confirm_text, inner.width)
            local y = inner.y + inner.height - 1
            local x = frame.button(painter, inner.x, y, {kind = "confirm", key = "Enter", label = "Confirm", enabled = true, primary = true})
            frame.button(painter, x, y, {kind = "dismiss", key = "Esc", label = "Cancel", enabled = true})
        end
    end
    if model.toast then frame.toast(painter, painter.height - 1, {text = model.toast, role = "ok"}) end
end

return M
