-- SPDX-License-Identifier: MIT
-- One bounded asynchronous read of this node's defaults. The host grants the
-- function and read permission; this reader never selects an actor or scope.
local funcs = require("funcs")
local channel = require("channel")
local appearance = require("appearance")
type Channel = channel.Channel
type Snapshot = {node_id: string, revision: integer, preferences: appearance.Preferences}
type Pending = {future: funcs.Future, response: Channel<unknown>, deadline: integer}
type Reader = {pending: Pending?, due: integer, closed: boolean}
local M = {}
function M.decode(value: unknown): Snapshot?
    if type(value) ~= "table" or value.ok ~= true or type(value.value) ~= "table" then return nil end
    local item = value.value
    local node_id = item.node_id
    if type(node_id) ~= "string" then return nil end
    if item.schema_revision ~= "bee.node-appearance@1" then return nil end
    if node_id == "" or #node_id > 160 or node_id:find("%c") then return nil end
    if type(item.revision) ~= "number" or item.revision < 0 or item.revision > 9007199254740990
        or item.revision ~= math.floor(item.revision) then return nil end
    local preferences = appearance.decode(item.preferences)
    if not preferences then return nil end
    return {node_id = node_id, revision = math.floor(item.revision), preferences = preferences}
end
function M.new(): Reader
    return {due = 0, closed = false}
end
function M.advance(reader: Reader, now: integer): Pending?
    if reader.closed then return nil end
    local pending = reader.pending
    if pending then
        if now < pending.deadline then return pending end
        reader.pending = nil
        pending.future:cancel()
        reader.due = now + 5000
    end
    if now < reader.due then return nil end
    reader.due = now + 5000
    local future, err = funcs.async("bee.node.binding:get_appearance", {})
    if err or not future then return nil end
    -- Runtime response() returns the future's channel; the selected manifest
    -- still leaves its generic element type unspecified.
    local response = future:response() :: Channel<unknown>
    if not response then future:cancel(); return nil end
    local next: Pending = {future = future, response = response, deadline = now + 5000}
    reader.pending = next
    return next
end
function M.complete(reader: Reader, pending: Pending): Snapshot?
    if reader.closed or reader.pending ~= pending then return nil end
    reader.pending = nil
    local result, err = pending.future:result()
    if err or not result then return nil end
    return M.decode(result:data())
end
function M.close(reader: Reader)
    reader.closed = true
    local pending = reader.pending
    reader.pending = nil
    if pending then pending.future:cancel() end
end
return M
