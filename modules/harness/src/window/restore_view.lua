-- MIT. The short-lived Agent surface shown while a launch or continuation is admitted.
-- It has no process or workspace authority; it only renders bounded status.
local appearance = require("appearance")
local frame = require("frame")
local M = {}
local MIN_REVIEW_WIDTH = 32
local MIN_REVIEW_HEIGHT = 13

type ReviewPlan = {
    title: string,
    definition_ref: string,
    profile_id: string,
    placement_binding_ref: string,
    plan_digest: string,
}

function M.draw(width: integer, height: integer, preferences: appearance.Preferences, status: string,
    heading: string?, footer: string?): {rows: {string}}
    local painter = frame.new(width, height, preferences)
    frame.header(painter, "AGENT")
    frame.line(painter, 3, heading or "Restoring Agent", painter.theme.text)
    frame.line(painter, 5, status, painter.theme.text)
    if height >= 6 then frame.footer(painter, "", footer or "Esc or Ctrl+Q cancels recovery") end
    return {rows = frame.rows(painter)}
end

-- A saved window that cannot be resumed ends; the person reads why and closes it.
function M.unresumable(width: integer, height: integer, preferences: appearance.Preferences, reason: string): {rows: {string}}
    local painter = frame.new(width, height, preferences)
    frame.header(painter, "AGENT")
    frame.line(painter, 3, "This Agent window cannot be resumed", painter.theme.text)
    frame.line(painter, 5, "Bee restarted, and " .. reason .. ".", painter.theme.text)
    frame.line(painter, 6, "Open a new Agent from the Start menu to continue.", painter.theme.muted)
    if height >= 8 then frame.footer(painter, "", "Enter or Esc closes it") end
    return {rows = frame.rows(painter)}
end

function M.reviewable(width: integer, height: integer): boolean
    return width >= MIN_REVIEW_WIDTH and height >= MIN_REVIEW_HEIGHT
end

-- A changed checkpoint is held for an explicit user decision. Keep the
-- displayed values presentation-safe and bounded: this surface never renders
-- provider configuration, grants or executable details.
function M.review(width: integer, height: integer, preferences: appearance.Preferences, plan: ReviewPlan,
    previous_digest: string, status: string?, footer: string?): {rows: {string}}
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    frame.header(painter, "AGENT")
    frame.line(painter, 3, "Review Agent changes", theme.text)
    if not M.reviewable(width, height) then
        frame.line(painter, 5, "Resize to at least 32 × 13 to review safely", theme.text)
        if height >= 6 then frame.footer(painter, "", "Esc or Ctrl+Q cancels") end
        return {rows = frame.rows(painter)}
    end
    frame.line(painter, 5, "Definition: " .. plan.definition_ref, theme.text)
    frame.line(painter, 6, "Title: " .. plan.title, theme.text)
    frame.line(painter, 7, "Profile: " .. plan.profile_id, theme.text)
    frame.line(painter, 8, "Placement: " .. plan.placement_binding_ref, theme.text)
    frame.line(painter, 10, "Old plan digest: " .. previous_digest, theme.muted)
    frame.line(painter, 11, "Current plan digest: " .. plan.plan_digest, theme.text)
    frame.footer(painter, status or "", footer or "Enter confirms · Esc or Ctrl+Q cancels")
    return {rows = frame.rows(painter)}
end

return M
