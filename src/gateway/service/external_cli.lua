-- SPDX-License-Identifier: MIT
local io = require("io")
local protocol = require("protocol")
local node_client = require("node_client")
local bounds = require("bounds")
local configuration = require("configuration")
local function value(raw: unknown): {[string]: unknown}
    local reply = bounds.object(raw)
    if not reply or reply.ok ~= true then
        local fault = reply and bounds.object(reply.error)
        error(fault and tostring(fault.message) or "MCP pairing is unavailable")
    end
    return assert(bounds.object(reply.value))
end
local function main(node: string, name: string)
    local state, state_error = node_client.call(node, "workspaces", {})
    if not state then error(state_error) end
    local workspace = bounds.id(state.home)
    if not workspace then error("The running node has no home workspace") end
    local asked, ask_error = protocol.call(node, "mcp.connect", {name = name, workspace_id = workspace}, "10s")
    if not asked or not asked.ok then error(ask_error or asked and asked.error or "MCP pairing is unavailable") end
    local pending = value(asked.value)
    assert(io.print("Needs you: approve " .. name .. " to use the requested Bee traits. Keep this terminal open."))
    local replied, wait_error = protocol.call(node, "mcp.wait", {client_id = pending.client_id}, "10m")
    if not replied or not replied.ok then error(wait_error or replied and replied.error or "MCP pairing outcome is unavailable") end
    local connected = value(replied.value)
    if connected.status ~= "connected" then error("MCP pairing " .. tostring(connected.status)) end
    local token, endpoint, action = bounds.text(connected.token, 128), bounds.text(connected.endpoint, 256), bounds.id(connected.action_id)
    if not token or not endpoint or not action then error("The token is already shown; pair again for a new configuration") end
    local rendered, render_error = configuration.render(name, endpoint, action, token)
    if not rendered then error(render_error) end
    assert(io.print(rendered))
end
return {main = main}
