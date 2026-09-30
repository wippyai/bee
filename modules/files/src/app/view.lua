-- MIT. View renderer for Files application.
-- Draws split file tree and syntax highlighted preview on responsive layouts.
-- Honors shared frame conventions: headers, action bar, reserved hints,
-- More options menu, and ? help overlay. Tested at 120x36 and 80x24.
local tty = require("tty")
local frame = require("frame")
local appearance = require("appearance")
local syntax = require("syntax")
local model = require("model")

local M = {}

local HINTS = frame.hints({
    {key = "↑↓", verb = "move"},
    {key = "Enter", verb = "open"},
    {key = "Tab", verb = "pane"},
    {key = "/", verb = "search"},
    {key = "G", verb = "jump"},
    {key = "M", verb = "more"},
    {key = "?", verb = "help"},
    {key = "Esc", verb = "close"},
})

local MORE_ITEMS: {string} = {
    "Search files by name (/)",
    "Jump to line number (G)",
    "Switch active pane (Tab)",
    "Show keyboard shortcuts (?)",
    "Close this menu (Esc)",
}

type RenderResult = {
    rows: {string},
    hits: {frame.Hit},
    tree_window: frame.Window?,
    preview_window: frame.Window?,
}

function M.render(state: model.State, width: integer, height: integer, preferences: appearance.Preferences): RenderResult
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme

    -- Title summary
    local summary = ""
    if state.current_path then
        summary = state.current_path
        local doc = state.doc :: any
        if doc then
            summary = summary .. " · line " .. tostring(state.preview_selected) .. " of " .. tostring(doc.total_lines)
            if doc.language then
                summary = summary .. " · " .. doc.language
            end
        end
    else
        summary = "No file open"
    end

    frame.header(painter, "FILES", summary)

    local is_split = width >= 80 and height >= 10
    local work_first = 2
    local work_last = height - 2
    if height < 4 then
        work_last = height
    end

    local tree_window: frame.Window? = nil
    local preview_window: frame.Window? = nil

    if is_split then
        -- Split layout: Tree on left, Preview on right
        local tree_width = math.floor(math.max(22, math.min(32, width // 4)))
        local divider_x = tree_width + 1
        local preview_x = tree_width + 2
        local preview_width = math.floor(math.max(0, width - preview_x + 1))
        local work_height = math.floor(math.max(0, work_last - work_first + 1))

        -- Vertical divider
        for y = work_first, work_last do
            frame.put(painter, divider_x, y, "│", 1, theme.border)
        end

        -- Draw Tree on left pane
        local tree_area: frame.Rect = {
            x = 2,
            y = work_first,
            width = tree_width - 1,
            height = work_height,
        }
        tree_window = frame.tree(painter, work_first, work_last, {
            rows = state.tree_rows,
            selected = state.tree_selected,
            offset = state.tree_offset,
            focused = state.active_pane == "tree",
            area = tree_area,
        })
        state.tree_offset = tree_window.offset

        -- Draw Preview on right pane
        local preview_area: frame.Rect = {
            x = preview_x,
            y = work_first,
            width = preview_width,
            height = work_height,
        }

        if state.doc then
            local doc: model.Document = state.doc
            local total_lines = doc.total_lines
            local off, cap = syntax.window(total_lines, work_height, state.preview_selected, state.preview_offset)
            state.preview_offset = off
            preview_window = {offset = off, capacity = cap}

            for slot = 1, cap do
                local line_num = off + slot
                if line_num > total_lines then break end
                local y = work_first + slot - 1
                local line_content = doc.lines[line_num] or ""
                local is_selected_line = line_num == state.preview_selected and state.active_pane == "preview"

                if is_selected_line then
                    -- Put selection marker before preview column
                    frame.put(painter, preview_x - 1, y, "›", 1, theme.accent)
                end

                -- Clip and paint line
                painter.canvas:put(preview_x, y, line_content, preview_width)
                frame.add_hit(painter, "preview_line", line_num, tostring(line_num), preview_x, y, preview_width, 1)
            end
        elseif state.preview_error then
            frame.put(painter, preview_x, work_first + 1, "Error: " .. state.preview_error, preview_width, theme.error)
        else
            frame.put(painter, preview_x, work_first + 1, "Select a file from the tree to preview.", preview_width, theme.muted)
        end
    else
        -- Narrow / Compact layout: Tabs on row 2, single pane filling work area
        local tabs: {frame.Tab} = {
            {kind = "tree", label = "Tree", short = "T"},
            {kind = "preview", label = "Preview", short = "P"},
        }
        frame.tabs(painter, 2, tabs, state.tab)
        local single_first = 3
        local single_last = work_last
        local single_height = math.floor(math.max(0, single_last - single_first + 1))
        local single_area: frame.Rect = {
            x = 2,
            y = single_first,
            width = width - 2,
            height = single_height,
        }

        if state.tab == "tree" then
            tree_window = frame.tree(painter, single_first, single_last, {
                rows = state.tree_rows,
                selected = state.tree_selected,
                offset = state.tree_offset,
                focused = true,
                area = single_area,
            })
            state.tree_offset = tree_window.offset
        else
            if state.doc then
                local doc: model.Document = state.doc
                local total_lines = doc.total_lines
                local off, cap = syntax.window(total_lines, single_height, state.preview_selected, state.preview_offset)
                state.preview_offset = off
                preview_window = {offset = off, capacity = cap}

                for slot = 1, cap do
                    local line_num = off + slot
                    if line_num > total_lines then break end
                    local y = single_first + slot - 1
                    local line_content = doc.lines[line_num] or ""
                    painter.canvas:put(2, y, line_content, width - 2)
                    frame.add_hit(painter, "preview_line", line_num, tostring(line_num), 2, y, width - 2, 1)
                end
            elseif state.preview_error then
                frame.line(painter, single_first + 1, "  Error: " .. state.preview_error, theme.error)
            else
                frame.line(painter, single_first + 1, "  Select a file from the tree to preview.", theme.muted)
            end
        end
    end

    -- Action bar (penultimate row)
    if height >= 4 then
        local action_y = height - 1
        local has_doc = state.doc ~= nil
        local buttons: {frame.Button} = {
            {kind = "open", label = "Open", key = "Enter", enabled = true, primary = true},
            {kind = "search", label = "Search", key = "/", enabled = true},
            {kind = "jump", label = "Jump", key = "G", enabled = has_doc},
            {kind = "pane", label = state.active_pane == "tree" and "Preview" or "Tree", key = "Tab", enabled = true},
            {kind = "more", label = "More", key = "M", enabled = true},
            {kind = "help", label = "? Help", key = "?", enabled = true},
        }
        if width < 100 then
            for _, button in ipairs(buttons) do button.key = nil end
        end
        frame.actions(painter, action_y, buttons)
    end

    -- Footer (final row)
    local status_text = state.status ~= "" and state.status or "Ready"
    local hints = HINTS
    if tty.text.width(status_text) + tty.text.width(hints) + 6 > width then
        hints = frame.hints({{key = "↑↓", verb = "move"}, {key = "Enter", verb = "open"},
            {key = "?", verb = "help"}})
    end
    if tty.text.width(status_text) + tty.text.width(hints) + 6 > width then
        frame.footer(painter, "", hints)
    else
        frame.footer(painter, status_text, hints)
    end

    -- Modals / Overlays
    if state.modal == "help" then
        local mw = math.floor(math.min(64, width - 2))
        local mh = math.floor(math.min(18, height - 2))
        local inner = frame.modal(painter, mw, mh, "Help")
        if inner.width > 0 and inner.height > 0 then
            local y = inner.y
            frame.put(painter, inner.x, y, "Keyboard Shortcuts:", inner.width, theme.accent)
            y = y + 1
            local help_lines = {
                "  ↑ / ↓       Move selection in active pane",
                "  PgUp / PgDn Scroll page up / down",
                "  Enter       Expand/collapse dir or open file preview",
                "  Tab         Switch focus between Tree and Preview",
                "  /           Search files by name",
                "  G           Jump to line number in preview",
                "  M           More actions menu",
                "  ?           Show this help dialog",
                "  Esc         Close modal / back to view",
            }
            for _, hl in ipairs(help_lines) do
                if y <= inner.y + inner.height - 1 then
                    frame.put(painter, inner.x, y, hl, inner.width, theme.text)
                    y = y + 1
                end
            end
        end
    elseif state.modal == "more" then
        local mw = math.floor(math.min(50, width - 2))
        local mh = math.floor(math.min(12, height - 2))
        local inner = frame.modal(painter, mw, mh, "More Options")
        if inner.width > 0 and inner.height > 0 then
            local y = inner.y
            for idx, item in ipairs(MORE_ITEMS) do
                if y <= inner.y + inner.height - 1 then
                    local is_sel = idx == state.more_selected
                    if is_sel then
                        frame.put(painter, inner.x, y, "› " .. item, inner.width, theme.accent)
                    else
                        frame.put(painter, inner.x, y, "  " .. item, inner.width, theme.text)
                    end
                    frame.add_hit(painter, "more_item", idx, item, inner.x, y, inner.width, 1)
                    y = y + 1
                end
            end
        end
    elseif state.modal == "search" then
        local mw = math.floor(math.min(60, width - 2))
        local mh = math.floor(math.min(14, height - 2))
        local inner = frame.modal(painter, mw, mh, "Search Files by Name")
        if inner.width > 0 and inner.height > 0 then
            local y = inner.y
            frame.put(painter, inner.x, y, "Search: " .. state.search_query .. "█", inner.width, theme.accent)
            y = y + 2
            local count = 0
            for idx, row in ipairs(state.tree_rows) do
                if not row.expandable and y <= inner.y + inner.height - 1 then
                    count = count + 1
                    local label = row.key or row.label
                    local is_sel = idx == state.tree_selected
                    if is_sel then
                        frame.put(painter, inner.x, y, "› " .. label, inner.width, theme.accent)
                    else
                        frame.put(painter, inner.x, y, "  " .. label, inner.width, theme.text)
                    end
                    frame.add_hit(painter, "search_item", idx, label, inner.x, y, inner.width, 1)
                    y = y + 1
                end
            end
            if count == 0 and y <= inner.y + inner.height - 1 then
                frame.put(painter, inner.x, y, "  No files found matching query.", inner.width, theme.muted)
            end
        end
    elseif state.modal == "jump" then
        local mw = math.floor(math.min(44, width - 2))
        local mh = math.floor(math.min(8, height - 2))
        local inner = frame.modal(painter, mw, mh, "Jump to Line")
        if inner.width > 0 and inner.height > 0 then
            local y = inner.y + 1
            frame.put(painter, inner.x, y, "Line number: " .. state.jump_input .. "█", inner.width, theme.accent)
            y = y + 2
            frame.put(painter, inner.x, y, "Press Enter to jump, Esc to cancel", inner.width, theme.muted)
        end
    end

    return {
        rows = frame.rows(painter),
        hits = painter.hits,
        tree_window = tree_window,
        preview_window = preview_window,
    }
end

return M
