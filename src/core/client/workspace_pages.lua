-- SPDX-License-Identifier: MIT
-- One bounded asynchronous read of a page of the node's workspace catalog for
-- the display's workspace menu. The host grants the catalog operations and
-- their read permission; this reader never selects an actor or scope. A newer
-- request replaces the one pending.
local funcs = require("funcs")
local channel = require("channel")
local contract = require("contract")
type Channel = channel.Channel
type Item = {workspace_id: string, label: string}
type Page = {items: {Item}, next_after: string?}
type Query = {request_id: string, label: string?, after: string?}
type Pending = {request_id: string, future: funcs.Future, response: Channel<unknown>}
type Reader = {pending: Pending?}
local M = {}
M.PAGE = 20
M.MAX_LABEL = 240
M.MAX_CURSOR = 2200
-- A presenter's request for one page: a label prefix and a cursor.
function M.query(value: unknown): Query?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "op" and key ~= "request_id" and key ~= "label" and key ~= "after" then return nil end
    end
    local request_id = contract.text(value.request_id, 80)
    if not request_id or request_id == "" then return nil end
    local label: string? = nil
    if value.label ~= nil then
        label = contract.text(value.label, M.MAX_LABEL)
        if not label or label == "" then return nil end
    end
    local after: string? = nil
    if value.after ~= nil then
        after = contract.text(value.after, M.MAX_CURSOR)
        if not after or after == "" then return nil end
    end
    return {request_id = request_id, label = label, after = after}
end
function M.decode(value: unknown): Page?
    if type(value) ~= "table" or value.ok ~= true or type(value.value) ~= "table" then return nil end
    local page = value.value
    if type(page.items) ~= "table" then return nil end
    local items: {Item} = {}
    for index, raw in ipairs(page.items :: {unknown}) do
        if index > M.PAGE or type(raw) ~= "table" then return nil end
        local id = contract.workspace_id(raw.workspace_id)
        local label = contract.text(raw.label, M.MAX_LABEL)
        if not id or not label then return nil end
        items[#items + 1] = {workspace_id = id, label = label}
    end
    local next_after: string? = nil
    if page.next_after ~= nil then
        next_after = contract.text(page.next_after, M.MAX_CURSOR)
        if not next_after or next_after == "" then return nil end
    end
    return {items = items, next_after = next_after}
end
function M.new(): Reader
    return {pending = nil}
end
function M.start(reader: Reader, query: Query): (Pending?, string?)
    local previous = reader.pending
    if previous then previous.future:cancel(); reader.pending = nil end
    local request: {[string]: unknown} = {state = "active", limit = M.PAGE}
    if query.after then request.after = query.after end
    local target = "bee.workspace.catalog:list"
    if query.label then request.label = query.label; target = "bee.workspace.catalog:search" end
    local future, err = funcs.async(target, request)
    if err or not future then return nil, tostring(err or "the workspace catalog is unavailable") end
    -- Runtime response() returns the future's channel; the selected manifest
    -- still leaves its generic element type unspecified.
    local response = future:response() :: Channel<unknown>
    if not response then future:cancel(); return nil, "the workspace catalog is unavailable" end
    local pending: Pending = {request_id = query.request_id, future = future, response = response}
    reader.pending = pending
    return pending, nil
end
function M.complete(reader: Reader, pending: Pending): (Page?, string?)
    if reader.pending ~= pending then return nil, nil end
    reader.pending = nil
    local result, err = pending.future:result()
    if err or not result then return nil, tostring(err or "the workspace catalog did not answer") end
    local page = M.decode(result:data())
    if not page then return nil, "the workspace catalog answered a malformed page" end
    return page, nil
end
function M.close(reader: Reader)
    local pending = reader.pending
    reader.pending = nil
    if pending then pending.future:cancel() end
end
return M
