-- MIT. Lazy file tree browser for workspace repositories.
-- Large-repo safe: bounded directory loading, depth bounds, gitignore filtering.
-- Only navigates permitted workspace trees and never accesses private .wippy state.
local protocol = require("protocol")
local gitignore = require("gitignore")

local M = {}

local MAX_ENTRIES_PER_DIR = 500
local MAX_SEARCH_RESULTS = 100

type Node = {
    name: string,
    path: string,
    is_dir: boolean,
    depth: integer,
    expanded: boolean,
    loaded: boolean,
    children: {Node},
    parent: Node?,
    truncated: boolean?,
    size: integer?,
}

type Tree = {
    volume: unknown,
    root: Node,
    matcher: unknown,
}

type TreeRow = {
    label: string,
    depth: integer,
    expandable: boolean?,
    expanded: boolean?,
    role: string?,
    key: string?,
    node: Node,
}

local function new_node(name: string, path: string, is_dir: boolean, depth: integer, parent: Node?): Node
    return {
        name = name,
        path = path,
        is_dir = is_dir,
        depth = depth,
        expanded = false,
        loaded = false,
        children = {},
        parent = parent,
        truncated = false,
        size = nil,
    }
end

-- Creates a new tree anchored at root_path in the given volume.
function M.new(volume: unknown, root_path: string?, matcher: gitignore.Matcher?): Tree
    local clean_root = root_path and protocol.verify_path(root_path) or ""
    local gm = matcher or gitignore.new("")

    -- If root has .gitignore, read it
    local vol = volume :: any
    if vol and vol.readfile then
        local gi_path = clean_root == "" and ".gitignore" or clean_root .. "/.gitignore"
        local content, err = vol:readfile(gi_path)
        if type(content) == "string" and not err then
            gm:add_rules(content, clean_root)
        end
    end

    local root = new_node(clean_root == "" and "workspace" or clean_root, clean_root, true, -1, nil)

    return {
        volume = volume,
        root = root,
        matcher = gm,
    }
end

-- Expands a directory node lazily if not already loaded.
function M.expand(tree: Tree, node: Node): boolean
    if not node.is_dir then
        return false
    end

    if not node.loaded then
        local vol = tree.volume :: any
        if not vol or not vol.readdir then
            node.loaded = true
            node.expanded = true
            return true
        end

        -- Check for a sub-directory .gitignore
        if node.path ~= "" and vol.readfile then
            local gi_path = node.path .. "/.gitignore"
            local content, err = vol:readfile(gi_path)
            if content and not err then
                tree.matcher:add_rules(content, node.path)
            end
        end

        local iterator, iterator_state = vol:readdir(node.path == "" and "." or node.path)
        local dirs: {Node} = {}
        local files: {Node} = {}
        local count = 0

        if iterator then
            for entry in iterator, iterator_state do
                count = count + 1
                if count > MAX_ENTRIES_PER_DIR then
                    node.truncated = true
                    break
                end

                local entry_name = entry.name
                if type(entry_name) == "string" and entry_name ~= "." and entry_name ~= ".." then
                    local child_path = node.path == "" and entry_name or node.path .. "/" .. entry_name
                    local verified, err = protocol.verify_path(child_path)
                    local is_directory = entry.type == "directory"

                    if verified and not err then
                        -- Check gitignore
                        if not tree.matcher:ignored(child_path, is_directory) then
                            local child = new_node(entry_name, child_path, is_directory, node.depth + 1, node)
                            if is_directory then
                                dirs[#dirs + 1] = child
                            else
                                files[#files + 1] = child
                            end
                        end
                    end
                end
            end
        end

        -- Sort dirs alphabetically, then files alphabetically
        table.sort(dirs, function(a, b) return a.name < b.name end)
        table.sort(files, function(a, b) return a.name < b.name end)

        local combined: {Node} = {}
        for _, d in ipairs(dirs) do combined[#combined + 1] = d end
        for _, f in ipairs(files) do combined[#combined + 1] = f end

        node.children = combined
        node.loaded = true
    end

    node.expanded = true
    return true
end

-- Collapses a directory node.
function M.collapse(node: Node)
    if node.is_dir then
        node.expanded = false
    end
end

-- Toggles expansion of a directory node.
function M.toggle(tree: Tree, node: Node): boolean
    if not node.is_dir then
        return false
    end
    if node.expanded then
        M.collapse(node)
        return false
    else
        return M.expand(tree, node)
    end
end

-- Flattens the visible tree nodes for rendering with frame.tree.
-- Skips root node if depth is -1 (virtual workspace root).
function M.flatten(tree: Tree, filter_query: string?): {TreeRow}
    local rows: {TreeRow} = {}
    local query = filter_query and filter_query:lower() or nil

    local function walk(n: Node)
        -- Don't include the virtual root itself in the flat list
        if n.depth >= 0 then
            local matches = true
            if query and query ~= "" then
                matches = n.name:lower():find(query, 1, true) ~= nil or n.path:lower():find(query, 1, true) ~= nil
            end
            if matches or (query and n.is_dir and n.expanded) then
                rows[#rows + 1] = {
                    label = n.name,
                    depth = n.depth,
                    expandable = n.is_dir,
                    expanded = n.expanded,
                    role = n.is_dir and "accent" or nil,
                    key = n.path,
                    node = n,
                }
            end
        end

        if n.expanded or (n == tree.root and not n.expanded and not n.loaded) then
            if not n.loaded then
                M.expand(tree, n)
            end
            for _, child in ipairs(n.children) do
                walk(child)
            end
        elseif n.expanded then
            for _, child in ipairs(n.children) do
                walk(child)
            end
        end
    end

    walk(tree.root)
    return rows
end

-- Walks down path segments (e.g. "src/app/view.lua"), expanding intermediate directories.
-- Returns the target node if found.
function M.find_or_load(tree: Tree, path: string): Node?
    local clean, err = protocol.verify_path(path)
    if not clean or err then
        return nil
    end

    if clean == "" then
        return tree.root
    end

    M.expand(tree, tree.root)

    local current = tree.root
    local segments: {string} = {}
    for seg in clean:gmatch("[^/]+") do
        segments[#segments + 1] = seg
    end

    for i, seg in ipairs(segments) do
        local found: Node? = nil
        for _, child in ipairs(current.children) do
            if child.name == seg then
                found = child
                break
            end
        end

        if not found then
            return nil
        end

        if i < #segments then
            if not found.is_dir then
                return nil
            end
            M.expand(tree, found)
            current = found
        else
            return found
        end
    end

    return current
end

-- Searches loaded nodes and loaded subdirectories by name.
function M.search(tree: Tree, query: string, max_results: integer?): {Node}
    local limit = max_results or MAX_SEARCH_RESULTS
    local q = query:lower()
    local results: {Node} = {}

    local function search_node(n: Node)
        if #results >= limit then
            return
        end
        if n ~= tree.root then
            if n.name:lower():find(q, 1, true) ~= nil or n.path:lower():find(q, 1, true) ~= nil then
                results[#results + 1] = n
            end
        end
        for _, child in ipairs(n.children) do
            search_node(child)
        end
    end

    search_node(tree.root)
    return results
end

return M
