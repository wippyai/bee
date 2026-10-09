-- SPDX-License-Identifier: MIT
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local funcs = require("funcs")
local time = require("time")
local view = require("view")
local frame = require("frame")
local appearance = require("appearance")
local client = require("client")
local bounds = require("bounds")
type Object = {[string]: unknown}
local function value(raw: unknown, err: unknown): (Object?, string?)
    local reply = bounds.object(raw)
    if err or not reply or reply.ok ~= true then
        local fault = reply and bounds.object(reply.error)
        return nil, fault and bounds.text(fault.message, 4096) or "Client operation is unavailable"
    end
    return bounds.object(reply.value), nil
end
local function main(options: unknown)
    local launch = assert(client.launch(options))
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local closes = assert(process.listen("bee.app.close_request", {message = true}))
    local preferences = appearance.chosen(options)
    local ticker = assert(time.ticker("2s"))
    local ticks = ticker:channel()
    local clients: {view.Client} = {}
    local selected = 1
    local status = ""
    local records: string? = nil
    local confirm = false
    local function load()
        local listing, err = value(funcs.call("bee.gateway.binding:external_call", {operation = "list"}))
        if not listing then status = err or "Clients are unavailable"; return end
        local rows = bounds.array(listing.clients, 128)
        if not rows then status = "Client list is invalid"; return end
        local next_clients: {view.Client} = {}
        for _, raw in ipairs(rows) do
            local row = bounds.object(raw)
            local id, name, thread = row and bounds.id(row.client_id), row and bounds.line(row.name, 80), row and bounds.id(row.thread_id)
            local state, expiry = row and bounds.text(row.status, 40), row and bounds.text(row.expires_at, 64)
            if not id or not name or not thread or not state or not expiry then status = "Client list is invalid"; return end
            next_clients[#next_clients + 1] = {client_id = id, name = name, thread_id = thread, status = state, expires_at = expiry}
        end
        clients = next_clients
        selected = math.floor(math.max(1, math.min(selected, #clients)))
    end
    local function act(kind: string)
        local chosen = clients[selected]
        if kind == "revoke" and chosen and chosen.status ~= "revoked" and chosen.status ~= "expired" then
            if not confirm then confirm = true; status = "Revoke " .. chosen.name .. "? Enter confirms · Esc keeps access"; return end
            local revoked, err = value(funcs.call("bee.gateway.binding:external_call", {operation = "revoke", client_id = chosen.client_id}))
            confirm = false
            status = revoked and "Access revoked" or err or "Revocation is unavailable"
            load()
        elseif kind == "read" and chosen then
            local page, err = value(funcs.call("bee.gateway.binding:external_call", {operation = "read", client_id = chosen.client_id}))
            if not page then status = err or "Thread is unavailable"; return end
            local rows = bounds.array(page.records, 64) or {}
            local lines: {string} = {}
            for _, raw in ipairs(rows) do
                local row = bounds.object(raw)
                local body = row and bounds.object(row.body)
                local content = body and bounds.object(body.content)
                local text = content and bounds.text(content.text, 16384)
                if text then lines[#lines + 1] = text end
            end
            records = #lines > 0 and table.concat(lines, "\n") or "No tool calls yet"
        elseif kind == "refresh" then load() end
    end
    assert(tty.start())
    local output = assert(tty.surface())
    client.ready(launch)
    load()
    while true do
        local width, height = tty.screen_size()
        local drawn = view.draw(width, height, preferences, clients, selected, status, records)
        assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), closes:case_receive(), ticks:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then break end
        elseif event.channel == closes then
            local message = event.value
            local closing = client.close_request(launch, tostring(message:from()), message:payload():data())
            if closing then client.close_reply(launch, closing.request_id, {action = "accept"}); break end
        elseif event.channel == ticks then load()
        else
            local data = event.value
            if type(data) == "table" and data.type == "key" and data.action == "press" then
                if data.key_type == "esc" or data.key_type == "escape" then
                    if confirm then confirm = false; status = "" elseif records then records = nil else break end
                elseif data.key_type == "up" then selected = math.floor(math.max(1, selected - 1)); confirm = false
                elseif data.key_type == "down" then selected = math.floor(math.min(#clients, selected + 1)); confirm = false
                elseif data.key_type == "enter" then act(confirm and "revoke" or "read")
                elseif type(data.key) == "string" and data.key:lower() == "x" then act("revoke")
                elseif type(data.key) == "string" and data.key:lower() == "r" then act("refresh") end
            elseif type(data) == "table" and data.type == "mouse" and data.action == "press" and data.button == "left" then
                local hit = frame.hit(drawn.hits, math.floor(tonumber(data.x) or 0), math.floor(tonumber(data.y) or 0))
                if hit then if hit.kind == "client" then selected = hit.index; confirm = false else act(hit.kind) end end
            end
        end
    end
    ticker:stop()
end
return {main = main}
