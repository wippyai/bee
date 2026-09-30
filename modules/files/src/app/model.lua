-- MIT. State model and reducers for Files application.
-- Coordinates file tree browsing, lazy expansion, syntax-highlighted preview,
-- search by name, jump to line, and agent navigation requests.
local tree = require("tree")
local syntax = require("syntax")
local protocol = require("protocol")

local M = {}

type Range = {
    start_line: integer,
    end_line: integer,
}

type Document = {
    lines: {string},
    raw_lines: {string},
    total_lines: integer,
    language: string?,
}

type State = {
    volume: unknown,
    root_path: string,

    -- Tree state
    tree: tree.Tree,
    tree_rows: {tree.TreeRow},
    tree_selected: integer,
    tree_offset: integer,

    -- Preview state
    current_path: string?,
    doc: Document?,
    preview_selected: integer,
    preview_offset: integer,
    highlight_range: Range?,
    preview_error: string?,

    -- Layout & Focus
    active_pane: "tree" | "preview",
    tab: "tree" | "preview",

    -- Modals
    modal: "none" | "help" | "more" | "search" | "jump",
    search_query: string,
    jump_input: string,
    more_selected: integer,

    -- Feedback
    status: string,
}

function M.refresh_tree_rows(state: State)
    state.tree_rows = tree.flatten(state.tree, state.modal == "search" and state.search_query ~= "" and state.search_query or nil)
    if state.modal == "search" then
        local matches: {tree.TreeRow} = {}
        for _, row in ipairs(state.tree_rows) do
            if not row.expandable then matches[#matches + 1] = row end
        end
        state.tree_rows = matches
    end
    if state.tree_selected > #state.tree_rows then
        state.tree_selected = math.floor(math.max(1, #state.tree_rows))
    end
end

function M.open_file(state: State, path: string, range: Range?): boolean
    local clean, path_err = protocol.verify_path(path)
    if not clean or path_err then
        state.preview_error = path_err or "Invalid file path"
        state.status = state.preview_error
        return false
    end

    local vol = state.volume :: any
    if not vol or not vol.readfile then
        state.preview_error = "Filesystem volume is unavailable"
        state.status = state.preview_error
        return false
    end

    -- Check if file exists and is not a directory
    if vol.isdir and vol:isdir(clean) then
        state.preview_error = clean .. " is a directory"
        state.status = state.preview_error
        return false
    end

    local raw_content, read_err = vol:readfile(clean)
    if type(raw_content) ~= "string" or read_err then
        state.preview_error = "Could not read " .. clean .. ": " .. tostring(read_err or "not found")
        state.status = state.preview_error
        return false
    end
    local content: string = raw_content

    -- Check for binary null byte
    if content:find("\0", 1, true) then
        state.preview_error = clean .. " is a binary file; preview is disabled"
        state.status = state.preview_error
        state.doc = nil
        state.current_path = clean
        return false
    end

    local lang = syntax.detect_language(clean)
    local doc = syntax.highlight(content, lang, nil, range)

    state.current_path = clean
    state.doc = doc
    state.preview_error = nil
    state.highlight_range = range

    local target_line = range and range.start_line or 1
    state.preview_selected = math.floor(math.max(1, math.min(doc.total_lines, target_line)))
    local off, _ = syntax.jump(doc.total_lines, 24, state.preview_selected)
    state.preview_offset = off

    state.active_pane = "preview"
    state.tab = "preview"
    state.status = clean .. " (" .. tostring(doc.total_lines) .. " lines" .. (lang and (", " .. lang) or "") .. ")"
    return true
end

function M.new(volume: unknown, root_path: string?, launch_args: {string}?): State
    local t = tree.new(volume, root_path)
    local state: State = {
        volume = volume,
        root_path = root_path or "",
        tree = t,
        tree_rows = {},
        tree_selected = 1,
        tree_offset = 0,
        current_path = nil,
        doc = nil,
        preview_selected = 1,
        preview_offset = 0,
        highlight_range = nil,
        preview_error = nil,
        active_pane = "tree",
        tab = "tree",
        modal = "none",
        search_query = "",
        jump_input = "",
        more_selected = 1,
        status = "Ready",
    }

    -- Expand initial tree root
    tree.expand(t, t.root)
    M.refresh_tree_rows(state)

    -- If launch arguments specify a target file / range, open it
    if launch_args and #launch_args > 0 then
        local target, target_err = protocol.decode_target(launch_args)
        if target and not target_err then
            local node = tree.find_or_load(t, target.path)
            M.refresh_tree_rows(state)

            -- Find selected row in tree
            if node then
                for idx, r in ipairs(state.tree_rows) do
                    if r.key == target.path then
                        state.tree_selected = idx
                        break
                    end
                end
            end

            local range: Range? = nil
            if target.line then
                range = {start_line = target.line, end_line = target.end_line or target.line}
            end

            M.open_file(state, target.path, range)
        elseif target_err then
            state.status = "Argument error: " .. target_err
        end
    end

    return state
end

function M.switch_pane(state: State)
    if state.active_pane == "tree" then
        state.active_pane = "preview"
        state.tab = "preview"
    else
        state.active_pane = "tree"
        state.tab = "tree"
    end
end

function M.move(state: State, delta: integer)
    if state.active_pane == "tree" then
        local count = #state.tree_rows
        if count == 0 then return end
        state.tree_selected = math.floor(math.max(1, math.min(count, state.tree_selected + delta)))
    else
        local doc = state.doc :: any
        if not doc then return end
        state.preview_selected = math.floor(math.max(1, math.min(doc.total_lines, state.preview_selected + delta)))
    end
end

function M.page(state: State, delta: integer, capacity: integer)
    local step = math.floor(delta * math.max(1, capacity - 2))
    M.move(state, step)
end

function M.activate(state: State)
    if state.active_pane == "tree" then
        local row = state.tree_rows[state.tree_selected]
        if not row then return end
        if row.expandable then
            tree.toggle(state.tree, row.node)
            M.refresh_tree_rows(state)
        else
            M.open_file(state, row.node.path, nil)
        end
    end
end

function M.jump_to_line(state: State, line_num: integer, capacity: integer?)
    if not state.doc then return end
    local doc: Document = state.doc
    local cap = capacity or 24
    local off, sel = syntax.jump(doc.total_lines, cap, line_num)
    state.preview_offset = off
    state.preview_selected = sel
    state.highlight_range = {start_line = sel, end_line = sel}
    state.doc = syntax.highlight(table.concat(doc.raw_lines, "\n") .. "\n", doc.language, nil, state.highlight_range)
    state.status = "Line " .. tostring(sel) .. " of " .. tostring(doc.total_lines)
end

function M.open_modal(state: State, modal_kind: "none" | "help" | "more" | "search" | "jump")
    state.modal = modal_kind
    if modal_kind == "search" then
        state.search_query = ""
        state.tree_selected = 1
        M.refresh_tree_rows(state)
    elseif modal_kind == "jump" then
        state.jump_input = ""
    elseif modal_kind == "more" then
        state.more_selected = 1
    end
end

function M.close_modal(state: State)
    state.modal = "none"
    state.search_query = ""
    state.jump_input = ""
    M.refresh_tree_rows(state)
end

function M.set_search_query(state: State, query: string)
    state.search_query = query
    M.refresh_tree_rows(state)
end

function M.open_search_result(state: State)
    local row = state.tree_rows[state.tree_selected]
    local path = row and not row.expandable and row.node.path or nil
    M.close_modal(state)
    if path then M.open_file(state, path, nil) end
end

function M.search_move(state: State, delta: integer)
    state.tree_selected = math.floor(math.max(1, math.min(#state.tree_rows, state.tree_selected + delta)))
end

function M.select_tree(state: State, index: integer)
    local count = #state.tree_rows
    if count > 0 then
        state.tree_selected = math.floor(math.max(1, math.min(count, index)))
    end
    state.active_pane = "tree"
end

function M.select_preview(state: State, index: integer)
    if state.doc then
        state.preview_selected = math.floor(math.max(1, math.min(state.doc.total_lines, index)))
        state.active_pane = "preview"
    end
end

function M.set_tab(state: State, tab: "tree" | "preview")
    state.tab = tab
end

function M.more_move(state: State, delta: integer)
    state.more_selected = math.floor(math.max(1, math.min(5, state.more_selected + delta)))
end

function M.jump_append(state: State, ch: string)
    if #state.jump_input < 8 then
        state.jump_input = state.jump_input .. ch
    end
end

function M.jump_backspace(state: State)
    if #state.jump_input > 0 then
        state.jump_input = state.jump_input:sub(1, -2)
    end
end

return M
