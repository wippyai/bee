-- MIT. The short-lived Agent continuation surface shown while admission runs.
-- It has no process or workspace authority; it only renders bounded status.
local tty = require("tty")
local appearance = require("appearance")
local M = {}
local RESET = "\27[0m"
local MIN_REVIEW_WIDTH = 32
local MIN_REVIEW_HEIGHT = 13

type ReviewPlan = {
    title: string,
    definition_ref: string,
    profile_id: string,
    placement_binding_ref: string,
    plan_digest: string,
}

local function maximum(a: integer, b: integer): integer
    if a > b then return a end
    return b
end

local function line(canvas: tty.Canvas, width: integer, height: integer, y: integer,
    value: string, foreground: string, background: string)
    if y < 1 or y > height or width <= 2 then return end
    local clean = value:gsub("%c", " ")
    local room = maximum(0, width - 4)
    local shown = tty.text.truncate(clean, room, "…")
    local style = appearance.style(foreground, background)
    canvas:put(2, y, style .. shown .. RESET, room)
end

function M.draw(width: integer, height: integer, preferences: appearance.Preferences, status: string,
    heading: string?, footer: string?): {rows: {string}}
    local theme = appearance.theme(preferences.theme)
    local canvas = tty.canvas(width, height)
    canvas:clear(appearance.style(theme.text, theme.surface) .. " " .. RESET)
    line(canvas, width, height, 1, "AGENT", theme.text, theme.surface)
    line(canvas, width, height, 3, heading or "Restoring Agent", theme.text, theme.surface)
    line(canvas, width, height, 5, status, theme.accent, theme.surface)
    line(canvas, width, height, height - 1, footer or "Esc or Ctrl+Q cancels recovery", theme.muted, theme.surface)
    return {rows = canvas:rows()}
end

function M.reviewable(width: integer, height: integer): boolean
    return width >= MIN_REVIEW_WIDTH and height >= MIN_REVIEW_HEIGHT
end

-- A changed checkpoint is held for an explicit user decision. Keep the
-- displayed values presentation-safe and bounded: this surface never renders
-- provider configuration, grants or executable details.
function M.review(width: integer, height: integer, preferences: appearance.Preferences, plan: ReviewPlan,
    previous_digest: string, status: string?, footer: string?): {rows: {string}}
    local theme = appearance.theme(preferences.theme)
    local canvas = tty.canvas(width, height)
    canvas:clear(appearance.style(theme.text, theme.surface) .. " " .. RESET)
    line(canvas, width, height, 1, "AGENT", theme.text, theme.surface)
    line(canvas, width, height, 3, "Review Agent changes", theme.text, theme.surface)
    if not M.reviewable(width, height) then
        line(canvas, width, height, 5, "Resize to at least 32 × 13 to review safely", theme.accent, theme.surface)
        line(canvas, width, height, height - 1, "Esc or Ctrl+Q cancels", theme.muted, theme.surface)
        return {rows = canvas:rows()}
    end
    line(canvas, width, height, 5, "Definition: " .. plan.definition_ref, theme.text, theme.surface)
    line(canvas, width, height, 6, "Title: " .. plan.title, theme.text, theme.surface)
    line(canvas, width, height, 7, "Profile: " .. plan.profile_id, theme.text, theme.surface)
    line(canvas, width, height, 8, "Placement: " .. plan.placement_binding_ref, theme.text, theme.surface)
    line(canvas, width, height, 10, "Old plan digest: " .. previous_digest, theme.muted, theme.surface)
    line(canvas, width, height, 11, "Current plan digest: " .. plan.plan_digest, theme.accent, theme.surface)
    if status then line(canvas, width, height, 13, status, theme.accent, theme.surface) end
    line(canvas, width, height, height - 1, footer or "Enter confirms · Esc or Ctrl+Q cancels", theme.muted, theme.surface)
    return {rows = canvas:rows()}
end

return M
